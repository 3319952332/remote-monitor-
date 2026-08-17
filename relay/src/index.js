/**
 * DSH remote-monitor relay server.
 *
 * Hubs WebSocket connections from DSH monitor-plugin nodes and HarmonyOS app
 * clients: it authenticates both, routes client requests to a node, and
 * broadcasts node events (including `turn.end`) to every client + webhook
 * notifiers. It never touches DSH data itself.
 */
import { createServer as createHttpServer } from "node:http";
import { createServer as createHttpsServer } from "node:https";
import { pathToFileURL } from "node:url";
import { WebSocketServer, WebSocket } from "ws";
import { loadConfig, loadTls } from "./config.js";
import {
  FRAME_TYPES,
  ROLES,
  ERROR_CODES,
  LOCAL_METHODS,
  makeError,
  makeFrame,
  newId,
  encode,
  decode,
} from "./protocol.js";
import { notifyTurnEnd } from "./notifiers.js";

function log(...args) {
  console.log(`[relay ${new Date().toISOString()}]`, ...args);
}

export function createRelay(config, logger = log) {
  const tls = loadTls(config);
  const httpServer = tls ? createHttpsServer(tls) : createHttpServer();

  const wss = new WebSocketServer({ server: httpServer, maxPayload: 64 * 1024 * 1024 });

  /** node connection records, keyed by relay-assigned id. */
  const nodes = new Map();
  /** client connection records, keyed by relay-assigned id. */
  const clients = new Map();
  /** in-flight requests awaiting a node response. */
  const pending = new Map();

  function send(conn, frame) {
    if (conn.readyState === WebSocket.OPEN) conn.send(encode(frame));
  }

  // ── handshake ──────────────────────────────────────────────────────────
  /**
   * Validate and register a hello. Returns { connId, role } on success, null
   * after closing the socket on failure.
   */
  function acceptHello(conn, frame) {
    if (frame.token !== config.token) {
      send(conn, makeError(frame.id, ERROR_CODES.AUTH_FAILED, "invalid token"));
      conn.close(4001, "auth failed");
      return null;
    }
    const role = frame.role;
    const connId = newId();
    const now = Date.now();
    if (role === ROLES.NODE) {
      nodes.set(connId, {
        conn,
        name: frame.name ?? "unnamed",
        hostname: frame.hostname ?? "",
        platform: frame.platform ?? "",
        pid: frame.pid ?? 0,
        version: frame.version ?? "",
        connectedAt: now,
        lastSeen: now,
      });
      send(conn, makeFrame(FRAME_TYPES.WELCOME, { id: connId, role }));
      broadcastToClients(makeFrame(FRAME_TYPES.EVENT, {
        id: newId(),
        event: "node.online",
        data: { id: connId, name: frame.name ?? "unnamed", hostname: frame.hostname ?? "", platform: frame.platform ?? "" },
      }));
      logger(`node online: ${frame.name ?? "unnamed"}@${frame.hostname ?? ""} (${connId})`);
      return { connId, role };
    }
    if (role === ROLES.CLIENT) {
      clients.set(connId, {
        conn,
        deviceName: frame.deviceName ?? "device",
        platform: frame.platform ?? "",
        connectedAt: now,
        lastSeen: now,
      });
      send(conn, makeFrame(FRAME_TYPES.WELCOME, { id: connId, role }));
      logger(`client online: ${frame.deviceName ?? "device"} (${connId})`);
      return { connId, role };
    }
    send(conn, makeError(frame.id, ERROR_CODES.BAD_REQUEST, `unknown role: ${role}`));
    conn.close(4002, "bad role");
    return null;
  }

  // ── request routing ─────────────────────────────────────────────────────
  function handleRequestFromClient(clientId, frame) {
    if (LOCAL_METHODS[frame.method]) {
      handleLocalMethod(clientId, frame);
      return;
    }
    const node = pickNode(frame.nodeId);
    if (!node) {
      const client = clients.get(clientId);
      if (client) send(client.conn, makeFrame(FRAME_TYPES.RESPONSE, {
        id: frame.id,
        ok: false,
        error: { code: ERROR_CODES.NO_NODE, message: "no online node" },
      }));
      return;
    }
    const timer = setTimeout(() => {
      pending.delete(frame.id);
      const client = clients.get(clientId);
      if (client) send(client.conn, makeFrame(FRAME_TYPES.RESPONSE, {
        id: frame.id,
        ok: false,
        error: { code: ERROR_CODES.NODE_TIMEOUT, message: "node did not respond in time" },
      }));
    }, config.requestTimeoutMs);
    pending.set(frame.id, { clientId, nodeId: node.id, timer });
    send(node.conn, makeFrame(FRAME_TYPES.REQUEST, {
      id: frame.id,
      method: frame.method,
      params: frame.params ?? {},
    }));
  }

  function handleLocalMethod(clientId, frame) {
    const client = clients.get(clientId);
    if (!client) return;
    let result;
    if (frame.method === "node.list") {
      result = [...nodes.entries()].map(([id, n]) => ({
        id,
        name: n.name,
        hostname: n.hostname,
        platform: n.platform,
        connectedAt: n.connectedAt,
      }));
    }
    send(client.conn, makeFrame(FRAME_TYPES.RESPONSE, { id: frame.id, ok: true, result }));
  }

  function handleResponseFromNode(nodeId, frame) {
    const record = pending.get(frame.id);
    if (!record) return;
    pending.delete(frame.id);
    clearTimeout(record.timer);
    const client = clients.get(record.clientId);
    if (client) {
      send(client.conn, makeFrame(FRAME_TYPES.RESPONSE, {
        id: frame.id,
        ok: frame.ok === true,
        result: frame.result,
        error: frame.error,
      }));
    }
  }

  function pickNode(nodeId) {
    if (nodeId) {
      const record = nodes.get(nodeId);
      return record ? { id: nodeId, conn: record.conn } : null;
    }
    const first = nodes.entries().next();
    return first.done ? null : { id: first.value[0], conn: first.value[1].conn };
  }

  // ── event fan-out ──────────────────────────────────────────────────────
  function broadcastToClients(frame) {
    const text = encode(frame);
    for (const record of clients.values()) {
      if (record.conn.readyState === WebSocket.OPEN) record.conn.send(text);
    }
  }

  function handleEventFromNode(_nodeId, frame) {
    const out = makeFrame(FRAME_TYPES.EVENT, {
      id: frame.id ?? newId(),
      event: frame.event,
      sessionId: frame.sessionId,
      data: frame.data,
    });
    broadcastToClients(out);
    if (frame.event === "turn.end") {
      notifyTurnEnd(config.notifiers, out, logger);
    }
  }

  // ── connection lifecycle ──────────────────────────────────────────────
  function handleConnection(conn) {
    let connId = null;
    let role = null;

    conn.on("message", (raw) => {
      const frame = decode(raw);
      if (!frame) return;

      if (connId === null) {
        if (frame.type !== FRAME_TYPES.HELLO) return;
        const accepted = acceptHello(conn, frame);
        if (accepted) {
          connId = accepted.connId;
          role = accepted.role;
        }
        return;
      }

      if (role === ROLES.NODE) touchNode(connId);
      else touchClient(connId);

      if (frame.type === FRAME_TYPES.PING) {
        send(conn, makeFrame(FRAME_TYPES.PONG, { t: frame.t }));
        return;
      }
      if (frame.type === FRAME_TYPES.PONG) return;

      if (role === ROLES.NODE) {
        if (frame.type === FRAME_TYPES.RESPONSE) handleResponseFromNode(connId, frame);
        else if (frame.type === FRAME_TYPES.EVENT) handleEventFromNode(connId, frame);
      } else if (role === ROLES.CLIENT) {
        if (frame.type === FRAME_TYPES.REQUEST) handleRequestFromClient(connId, frame);
      }
    });

    conn.on("close", () => {
      if (role === ROLES.NODE && connId !== null && nodes.has(connId)) {
        const record = nodes.get(connId);
        nodes.delete(connId);
        logger(`node offline: ${record.name} (${connId})`);
        broadcastToClients(makeFrame(FRAME_TYPES.EVENT, {
          id: newId(),
          event: "node.offline",
          data: { id: connId, name: record.name },
        }));
        for (const [reqId, rec] of pending) {
          if (rec.nodeId === connId) {
            pending.delete(reqId);
            clearTimeout(rec.timer);
            const client = clients.get(rec.clientId);
            if (client) send(client.conn, makeFrame(FRAME_TYPES.RESPONSE, {
              id: reqId,
              ok: false,
              error: { code: ERROR_CODES.NO_NODE, message: "node disconnected" },
            }));
          }
        }
      } else if (role === ROLES.CLIENT && connId !== null && clients.has(connId)) {
        clients.delete(connId);
        logger(`client offline (${connId})`);
      }
    });

    conn.on("error", () => {});
  }

  function touchNode(id) {
    const record = nodes.get(id);
    if (record) record.lastSeen = Date.now();
  }
  function touchClient(id) {
    const record = clients.get(id);
    if (record) record.lastSeen = Date.now();
  }

  wss.on("connection", handleConnection);

  const sweeper = setInterval(() => {
    const cutoff = Date.now() - config.heartbeatMs;
    for (const [id, record] of nodes) {
      if (record.lastSeen < cutoff) {
        logger(`node heartbeat timeout: ${record.name} (${id})`);
        record.conn.close(4003, "heartbeat timeout");
      }
    }
    for (const [id, record] of clients) {
      if (record.lastSeen < cutoff) {
        logger(`client heartbeat timeout (${id})`);
        record.conn.close(4003, "heartbeat timeout");
      }
    }
  }, config.heartbeatMs);
  sweeper.unref();

  return {
    httpServer,
    wss,
    nodes,
    clients,
    listen() {
      return new Promise((resolve, reject) => {
        httpServer.once("error", reject);
        httpServer.listen(config.port, config.host, () => {
          const addr = httpServer.address();
          logger(`listening on ${tls ? "wss" : "ws"}://${config.host}:${addr.port}`);
          resolve(addr.port);
        });
      });
    },
    close() {
      clearInterval(sweeper);
      for (const record of nodes.values()) record.conn.close();
      for (const record of clients.values()) record.conn.close();
      wss.close();
      httpServer.close();
    },
  };
}

// Run when executed directly (`node src/index.js`).
const isMain = process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href;
if (isMain) {
  const relay = createRelay(loadConfig());
  relay.listen().catch((error) => {
    console.error("[relay] failed to start:", error);
    process.exit(1);
  });
}

export default createRelay;

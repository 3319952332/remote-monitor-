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
  AGGREGATE_METHODS,
  TRY_ALL_METHODS,
  makeError,
  makeFrame,
  newId,
  encode,
  decode,
} from "./protocol.js";
import { notifyTurnEnd, summarizeTurnEnd } from "./notifiers.js";
import { loadServiceAccount, sendAlert, PUSH_ERROR_HINTS } from "./push.js";

function log(...args) {
  console.log(`[relay ${new Date().toISOString()}]`, ...args);
}

/**
 * Build the push delivery hook for `turn.end`.
 *
 * The registry is keyed by a *stable device id* the client reports (ODID), not
 * by its display name — the app's device name is a hardcoded "HarmonyOS" on
 * every install, so name-keyed entries would silently overwrite each other and
 * leave a stale token behind after a reinstall.
 *
 * Entries outlive the socket on purpose: "app closed" is exactly the case push
 * exists for, so dropping the token on disconnect would make the feature
 * useless. A device that reconnects re-registers (overwriting), and entries
 * idle past `config.pushTokenTtlMs` are pruned so the map cannot grow forever.
 *
 * `push.js` needs the project-level service account; without it this returns a
 * no-op so the relay still runs on a machine with no push credentials.
 */
function makePusher(config, logger) {
  const empty = { enabled: false, tokens: new Map(), remember() {}, forget() {}, notify: async () => {} };
  const path = config.serviceAccountPath;
  const projectId = config.pushProjectId;
  if (path === "") return empty;

  let serviceAccount;
  try {
    serviceAccount = loadServiceAccount(path);
  } catch (error) {
    logger(`[push] disabled — cannot load service account: ${error.message}`);
    return empty;
  }
  if (!projectId) {
    logger("[push] disabled — DSH_RELAY_PUSH_PROJECT_ID is not set");
    return empty;
  }

  /** deviceId → { token, seenAt } */
  const tokens = new Map();
  logger(`[push] enabled — project ${projectId}, category ${config.pushCategory}`);

  /** Drop entries nobody has refreshed in a long time. */
  function prune() {
    const cutoff = Date.now() - config.pushTokenTtlMs;
    for (const [deviceId, entry] of tokens) {
      if (entry.seenAt < cutoff) {
        tokens.delete(deviceId);
        logger(`[push] pruned stale token for ${deviceId}`);
      }
    }
  }

  return {
    enabled: true,
    tokens,
    /**
     * Register/refresh the token a client presented. Called on every hello, so
     * a token rotation or reinstall is picked up automatically.
     */
    remember(deviceId, pushToken) {
      if (!deviceId || !pushToken) return;
      tokens.set(deviceId, { token: pushToken, seenAt: Date.now() });
    },
    /** Forget one device's token (e.g. the cloud says it is dead). */
    forget(deviceId) {
      tokens.delete(deviceId);
    },
    /**
     * Push a `turn.end` to every registered device except those the caller
     * names as already-visible. `skip` is a Set of deviceIds that have a live
     * foreground socket — pushing to them would duplicate what is on screen.
     * Every other device (backgrounded, or closed with no socket at all) is
     * reached through Push Kit.
     */
    async notify(msg, skip = new Set()) {
      if (tokens.size === 0) return;
      prune();
      const body = summarizeTurnEnd(msg);
      const ttl = 86400;
      for (const [deviceId, entry] of tokens) {
        if (skip.has(deviceId)) continue;
        try {
          const result = await sendAlert(serviceAccount, projectId, {
            token: entry.token,
            title: "DSH 会话完成",
            body,
            category: config.pushCategory,
            ttl,
          });
          if (result.ok) {
            logger(`[push] sent to ${deviceId} (${result.requestId})`);
          } else {
            logger(`[push] ${deviceId} failed: code=${result.code} ${result.msg}`);
            const hint = PUSH_ERROR_HINTS[result.code];
            if (hint) logger(`[push]   hint: ${hint}`);
            // 80300007 = token invalid (uninstalled / revoked) — drop it so we
            // stop burning quota on a device that can no longer receive.
            if (result.code === "80300007") tokens.delete(deviceId);
          }
        } catch (error) {
          logger(`[push] ${deviceId} threw: ${error.message}`);
        }
      }
    },
  };
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
  /** Push Kit delivery, or a disabled no-op when unconfigured. */
  const pusher = makePusher(config, logger);

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
      const deviceName = frame.deviceName ?? "device";
      /**
       * Stable identity for the push registry. The display name is not usable
       * for this: it is the same string on every install, so two phones would
       * overwrite each other and a reinstall would leave a dead token behind.
       * Fall back to the name only when a client predates this field.
       */
      const deviceId = frame.deviceId || deviceName;
      clients.set(connId, {
        conn,
        deviceId,
        deviceName,
        platform: frame.platform ?? "",
        connectedAt: now,
        lastSeen: now,
        /**
         * A freshly-connected client is assumed to be in the foreground: it
         * just launched or was brought up by the user. Losing this socket is
         * what marks the app as "gone" — we deliberately never keep a
         * background service alive, so an absent socket means the app is
         * either closed or suspended, and push is the way to reach it.
         */
        foreground: true,
      });
      // Register the token against the stable id, so it still works after the
      // app is closed and this socket is long gone.
      pusher.remember(deviceId, frame.pushToken);
      send(conn, makeFrame(FRAME_TYPES.WELCOME, { id: connId, role }));
      logger(`client online: ${deviceName} <${deviceId}> (${connId})${frame.pushToken ? " +push" : ""}`);
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
    // List methods fan out to every node when no nodeId is pinned, so the
    // app sees "all devices" in one shot with a per-item node tag.
    if (AGGREGATE_METHODS[frame.method] && !frame.nodeId) {
      broadcastRequest(clientId, frame);
      return;
    }
    // Try-all methods: prefer the pinned node when it is still online, but
    // fall back to "ask every node, first success wins" when the pin is stale
    // (e.g. a plugin hot-reload reconnects a node under a new id) or absent.
    // This makes the app survive a stale nodeId instead of answering NO_NODE.
    if (TRY_ALL_METHODS[frame.method]) {
      if (frame.nodeId && nodes.has(frame.nodeId)) {
        forwardToNode(clientId, frame, frame.nodeId);
      } else {
        tryAllRequest(clientId, frame);
      }
      return;
    }
    // Targeted methods (non-try-all) honor the pin strictly.
    const node = pickNode(frame.nodeId);
    if (!node) {
      sendNoNode(clientId, frame.id);
      return;
    }
    forwardToNode(clientId, frame, node.id);
  }

  /** Forward one request to a specific online node and await its response. */
  function forwardToNode(clientId, frame, nodeId) {
    const record = nodes.get(nodeId);
    if (!record) {
      sendNoNode(clientId, frame.id);
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
    pending.set(frame.id, { clientId, nodeId, timer });
    send(record.conn, makeFrame(FRAME_TYPES.REQUEST, {
      id: frame.id,
      method: frame.method,
      params: frame.params ?? {},
    }));
  }

  /** Answer a request with the NO_NODE error. */
  function sendNoNode(clientId, reqId) {
    const client = clients.get(clientId);
    if (client) send(client.conn, makeFrame(FRAME_TYPES.RESPONSE, {
      id: reqId,
      ok: false,
      error: { code: ERROR_CODES.NO_NODE, message: "no online node" },
    }));
  }

  /** Fan a list method out to every online node and aggregate tagged results. */
  function broadcastRequest(clientId, frame) {
    if (nodes.size === 0) {
      const client = clients.get(clientId);
      if (client) send(client.conn, makeFrame(FRAME_TYPES.RESPONSE, { id: frame.id, ok: true, result: [] }));
      return;
    }
    const record = {
      clientId,
      aggregate: true,
      nodeIds: new Set(nodes.keys()),
      results: [],
      timer: setTimeout(() => finalizeAggregate(frame.id), config.requestTimeoutMs),
    };
    pending.set(frame.id, record);
    for (const node of nodes.values()) {
      send(node.conn, makeFrame(FRAME_TYPES.REQUEST, {
        id: frame.id,
        method: frame.method,
        params: frame.params ?? {},
      }));
    }
  }

  /** Try a targeted method on every online node; first success wins. */
  function tryAllRequest(clientId, frame) {
    if (nodes.size === 0) {
      const client = clients.get(clientId);
      if (client) send(client.conn, makeFrame(FRAME_TYPES.RESPONSE, {
        id: frame.id,
        ok: false,
        error: { code: ERROR_CODES.NO_NODE, message: "no online node" },
      }));
      return;
    }
    const record = {
      clientId,
      tryAll: true,
      nodeIds: new Set(nodes.keys()),
      lastError: null,
      timer: setTimeout(() => finalizeTryAll(frame.id), config.requestTimeoutMs),
    };
    pending.set(frame.id, record);
    for (const node of nodes.values()) {
      send(node.conn, makeFrame(FRAME_TYPES.REQUEST, {
        id: frame.id,
        method: frame.method,
        params: frame.params ?? {},
      }));
    }
  }

  function finalizeTryAll(reqId) {
    const record = pending.get(reqId);
    if (!record) return;
    pending.delete(reqId);
    clearTimeout(record.timer);
    const client = clients.get(record.clientId);
    if (client) {
      send(client.conn, makeFrame(FRAME_TYPES.RESPONSE, {
        id: reqId,
        ok: false,
        error: record.lastError ?? { code: ERROR_CODES.INTERNAL, message: "all nodes failed" },
      }));
    }
  }

  function finalizeAggregate(reqId) {
    const record = pending.get(reqId);
    if (!record) return;
    pending.delete(reqId);
    clearTimeout(record.timer);
    const client = clients.get(record.clientId);
    if (client) {
      send(client.conn, makeFrame(FRAME_TYPES.RESPONSE, { id: reqId, ok: true, result: record.results }));
    }
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
    if (record.tryAll) {
      record.nodeIds.delete(nodeId);
      if (frame.ok === true) {
        // First success wins — cancel the rest and reply immediately.
        pending.delete(frame.id);
        clearTimeout(record.timer);
        const client = clients.get(record.clientId);
        if (client) {
          send(client.conn, makeFrame(FRAME_TYPES.RESPONSE, {
            id: frame.id,
            ok: true,
            result: frame.result,
          }));
        }
        return;
      }
      // Remember the last error in case every node fails.
      record.lastError = frame.error ?? { code: ERROR_CODES.INTERNAL, message: "node error" };
      if (record.nodeIds.size === 0) {
        finalizeTryAll(frame.id);
      }
      return;
    }
    if (record.aggregate) {
      if (frame.ok === true && Array.isArray(frame.result)) {
        const node = nodes.get(nodeId);
        const tag = { nodeId, nodeName: node?.name ?? "", hostname: node?.hostname ?? "" };
        for (const item of frame.result) {
          record.results.push({ ...item, ...tag });
        }
      }
      record.nodeIds.delete(nodeId);
      if (record.nodeIds.size === 0) {
        finalizeAggregate(frame.id);
      }
      return;
    }
    pending.delete(frame.id);
    clearTimeout(record.timer);
    const client = clients.get(record.clientId);
    if (client) {
      // Tag array results (and object results carrying a `rows` array, e.g. the
      // paginated session.list) with the answering node, so the app can pin
      // follow-up requests (history/usage/selectModel) even when it requested a
      // single node directly instead of through the aggregate fan-out.
      let result = frame.result;
      if (frame.ok === true) {
        const node = nodes.get(nodeId);
        const tag = { nodeId, nodeName: node?.name ?? "", hostname: node?.hostname ?? "" };
        if (Array.isArray(result)) {
          result = result.map((item) => ({ ...item, ...tag }));
        } else if (result && Array.isArray(result.rows)) {
          result = { ...result, rows: result.rows.map((item) => ({ ...item, ...tag })) };
        }
      }
      send(client.conn, makeFrame(FRAME_TYPES.RESPONSE, {
        id: frame.id,
        ok: frame.ok === true,
        result,
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

  function handleEventFromNode(nodeId, frame) {
    const node = nodes.get(nodeId);
    const out = makeFrame(FRAME_TYPES.EVENT, {
      id: frame.id ?? newId(),
      event: frame.event,
      sessionId: frame.sessionId,
      nodeId,
      data: {
        ...(frame.data ?? {}),
        nodeId,
        nodeName: node?.name ?? "",
        hostname: node?.hostname ?? "",
      },
    });
    broadcastToClients(out);
    if (frame.event === "turn.end") {
      notifyTurnEnd(config.notifiers, out, logger);
      // Reach the devices that could NOT have seen this live. A foreground app
      // already renders the completion itself, so it is skipped per-device —
      // with several phones online, one of them being in the foreground must
      // not silence the others.
      if (pusher.enabled) pusher.notify(out, visibleDeviceIds());
    }
  }

  /**
   * Decide which devices should be treated as "already saw it".
   *
   * A device with a live foreground socket always counts as seen. A device
   * that is merely *connected* is only exempt when the operator disabled
   * `pushWhenAppBackground`, and the "no sockets at all" case is governed by
   * `pushWhenAppClosed` — but that one is checked against the registry size,
   * since a closed app has no socket to inspect at all.
   */
  function visibleDeviceIds() {
    const skip = new Set();
    let anyConnected = false;
    for (const record of clients.values()) {
      if (record.conn.readyState !== WebSocket.OPEN) continue;
      anyConnected = true;
      if (record.foreground) {
        skip.add(record.deviceId);
      } else if (!config.pushWhenAppBackground) {
        skip.add(record.deviceId);
      }
    }
    if (!anyConnected && !config.pushWhenAppClosed) {
      // Nothing connected and closed apps are exempt → nobody gets a push.
      for (const deviceId of pusher.tokens.keys()) skip.add(deviceId);
    }
    return skip;
  }

  /** Mark a client as foreground/background based on an `app.state` frame. */
  function handleAppState(clientId, frame) {
    const record = clients.get(clientId);
    if (!record) return;
    record.foreground = frame.foreground === true;
    // Token may have rotated since the hello; refresh it in place.
    if (frame.pushToken) pusher.remember(record.deviceId, frame.pushToken);
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
        else if (frame.type === FRAME_TYPES.APP_STATE) handleAppState(connId, frame);
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
    /** Push registry + sender, exposed for tests and ops introspection. */
    push: pusher,
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

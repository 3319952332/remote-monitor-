/**
 * DSH remote-monitor plugin (Cordis).
 *
 * Runs inside the DSH process. It dials a relay server over an outbound
 * WebSocket, answers method requests (workspace/session/fs/agent) and pushes
 * session lifecycle + `turn.end` events back. It never blocks the agent loop:
 * request handling is async and event forwarding is fire-and-forget.
 *
 * Install: copy this package into ~/.dsh/profiles/node_modules/, then add an
 * `insert` row to ~/.dsh/profiles/web/cordis.patch.yml (see README).
 *
 * @module dsh-remote-monitor
 */
import { randomUUID } from "node:crypto";
import os from "node:os";
import z from "@deepseek-ai/schemastery";
import { createUserMessage } from "@deepseek-ai/dsh-llm";
import { SessionId } from "@deepseek-ai/dsh-session";
import { installModelSelection } from "@deepseek-ai/dsh-agent";

/** Stable Cordis plugin id. */
const name = "remote-monitor";

/** Services this plugin requires before it mounts. */
const inject = ["agents", "sessions", "sessionPersistence", "sessionQuery", "fs", "workspaceRegistry"];

/** Validated plugin config, supplied from the cordis.patch.yml insert row. */
const Config = z.object({
  relayUrl: z.string().required(),
  token: z.string().role("secret").default(""),
  name: z.string().default(""),
  maxTextBytes: z.number().default(262144),
  heartbeatMs: z.number().default(30000),
});

const PROTOCOL_VERSION = 1;
const OPEN = 1; // WebSocket.OPEN

/** Raw event types forwarded verbatim to the app (assistant/chunk is too chatty). */
const FORWARD_EVENT_TYPES = new Set([
  "turn/start",
  "user/message",
  "assistant/message",
  "tool/call",
  "tool/result",
  "todo/write",
]);

/** The only event types shown in a transcript: the user's prompt and the
 *  assistant's visible answer. `assistant/chunk`, tool call/result, todo and
 *  turn markers are intermediate process and are dropped; `reasoning` /
 *  `tool-call` / `tool-result` blocks inside a message are also dropped in
 *  `serializeEvent`, leaving only the plain `text` blocks. */
const HISTORY_EVENT_TYPES = new Set(["user/message", "assistant/message"]);

/** Hard caps so a pathological transcript can never OOM the phone app. Since
 *  chunk/tool events are dropped above, message counts stay small and these
 *  ceilings are effectively "full history" for real sessions. */
const MAX_HISTORY_EVENTS = 2000;
const MAX_MESSAGE_CHARS = 2_000_000;

function apply(ctx, config) {
  const relayUrl = config.relayUrl;
  const token = config.token ?? "";
  const nodeName = config.name && config.name.length > 0 ? config.name : os.hostname();
  const maxTextBytes = config.maxTextBytes ?? 262144;
  const heartbeatMs = config.heartbeatMs ?? 30000;

  let ws = null;
  let connected = false;
  let closed = false;
  let backoffMs = 1000;
  let reconnectTimer = null;
  let heartbeatTimer = null;

  function send(frame) {
    if (ws && ws.readyState === OPEN) {
      try {
        ws.send(JSON.stringify(frame));
      } catch {
        /* ignore */
      }
    }
  }

  function scheduleReconnect() {
    if (closed || reconnectTimer) return;
    reconnectTimer = setTimeout(() => {
      reconnectTimer = null;
      connect();
    }, backoffMs);
    backoffMs = Math.min(backoffMs * 2, 30000);
  }

  function connect() {
    if (closed) return;
    let socket;
    try {
      socket = new WebSocket(relayUrl);
    } catch {
      scheduleReconnect();
      return;
    }
    ws = socket;
    socket.addEventListener("open", () => {
      connected = true;
      backoffMs = 1000;
      send({
        v: PROTOCOL_VERSION,
        type: "hello",
        role: "node",
        token,
        name: nodeName,
        hostname: os.hostname(),
        platform: process.platform,
        pid: process.pid,
        version: "0.1.0",
      });
    });
    socket.addEventListener("message", (evt) => {
      let frame;
      try {
        frame = JSON.parse(evt.data);
      } catch {
        return;
      }
      if (frame.type === "request") handleRequest(frame);
      else if (frame.type === "ping") send({ v: PROTOCOL_VERSION, type: "pong", t: frame.t });
    });
    socket.addEventListener("close", () => {
      connected = false;
      ws = null;
      if (!closed) scheduleReconnect();
    });
    socket.addEventListener("error", () => {
      // Connection failed before open: close does NOT follow. Tear down and
      // schedule a reconnect so the node keeps retrying while relay is down.
      connected = false;
      if (ws === socket) ws = null;
      if (!closed) scheduleReconnect();
    });
  }

  function emitEvent(event, sessionId, data) {
    if (!connected) return;
    send({ v: PROTOCOL_VERSION, type: "event", id: randomUUID(), event, sessionId, data });
  }

  // ── session lifecycle → relay ──────────────────────────────────────────
  // Subagent child sessions are invisible to the monitor app: skip their
  // lifecycle + turn events entirely so only top-level sessions drive the
  // completion notification and the "monitoring" state.
  function isSubagent(session) {
    return session?.header?.origin === "subagent";
  }

  ctx.on("session/created", (session) => {
    if (isSubagent(session)) return;
    emitEvent("session.created", session.id, { header: session.header });
  });

  ctx.on("session/disposed", (session) => {
    if (isSubagent(session)) return;
    emitEvent("session.disposed", session.id, {});
  });

  ctx.on("session/event", (session, event) => {
    if (!connected) return;
    if (isSubagent(session)) return;
    if (event.type === "turn/end") {
      emitEvent("turn.end", session.id, { turn: event.data.turn, reason: event.data.reason });
      return;
    }
    if (FORWARD_EVENT_TYPES.has(event.type)) {
      emitEvent("session.event", session.id, {
        event: { type: event.type, seq: event.seq, time: event.time, data: event.data },
      });
    }
  });

  // ── method dispatch ────────────────────────────────────────────────────
  async function handleRequest(frame) {
    const { id, method, params } = frame;
    try {
      const result = await dispatch(method, params ?? {});
      send({ v: PROTOCOL_VERSION, type: "response", id, ok: true, result });
    } catch (error) {
      send({
        v: PROTOCOL_VERSION,
        type: "response",
        id,
        ok: false,
        error: { code: "INTERNAL", message: error?.message ?? String(error) },
      });
    }
  }

  async function dispatch(method, p) {
    switch (method) {
      case "workspace.list":
        return ctx.workspaceRegistry.list().map((w) => ({
          id: w.id,
          path: w.path,
          title: w.title,
          sessionIds: [...w.sessionIds],
          createdAt: w.createdAt,
          updatedAt: w.updatedAt,
        }));
      case "session.list":
        return listSessions(p);
      case "session.history":
        return readHistory(p);
      case "session.create":
        return createSession(p);
      case "session.prompt":
        return promptSession(p);
      case "agent.list":
        return ctx.agents.list().map((a) => ({ id: a.id, status: a.status, sessionId: a.session.id }));
      case "fs.listDir":
        return listDir(p);
      case "fs.readText":
        return readText(p);
      default:
        throw new Error(`unknown method: ${method}`);
    }
  }

  function normalizeCwd(value) {
    return String(value ?? "")
      .replace(/\\/g, "/")
      .replace(/\/+$/, "")
      .toLowerCase();
  }

  async function listSessions(p) {
    // The phone shows ONLY what this computer has in memory right now —
    // closed/historical sessions stay out of the list entirely.
    const records = await ctx.sessionQuery.listSessions();
    const wantCwd = typeof p?.cwd === "string" && p.cwd.length > 0 ? normalizeCwd(p.cwd) : null;
    const liveRecords = [];
    for (const r of records) {
      if (r.live !== true) continue;
      const h = r.header;
      // Subagent child sessions are noise for the monitor app — skip them.
      if (h.origin === "subagent") continue;
      if (wantCwd !== null && normalizeCwd(h.cwd) !== wantCwd) continue;
      liveRecords.push(r);
    }
    // Fold titles from one batched corpus observation (log-backed `session/title`).
    const titleResults = await ctx.sessionQuery.readTitleSnapshots(liveRecords.map((r) => r.header.id));
    const titleById = new Map();
    for (const t of titleResults) {
      if (t.status === "fulfilled" && t.value?.title?.title) {
        titleById.set(t.sessionId, t.value.title.title);
      }
    }
    const rows = [];
    for (const r of liveRecords) {
      const h = r.header;
      // "Last change" is the last event logged in memory; fall back to the
      // session's creation time when the in-memory log is empty/missing.
      const liveSession = ctx.sessions.get(h.id);
      const events = liveSession?.events;
      const last = Array.isArray(events) && events.length > 0 ? events[events.length - 1] : null;
      const updatedAt = typeof last?.time === "number" ? last.time : h.createdAt;
      rows.push({
        id: h.id,
        createdAt: h.createdAt,
        cwd: h.cwd,
        parentSession: h.parentSession,
        origin: h.origin,
        agentPreset: h.agentPreset,
        live: true,
        title: titleById.get(h.id) ?? null,
        updatedAt,
        running: ctx.agents.get(h.id)?.status === "running",
      });
    }
    // Running sessions first, then most recent activity first.
    rows.sort((a, b) => Number(b.running) - Number(a.running) || (b.updatedAt ?? 0) - (a.updatedAt ?? 0));
    return rows;
  }

  async function readHistory(p) {
    const sessionId = p.sessionId;
    if (!sessionId) throw new Error("sessionId required");
    const fromSeq = Number.isInteger(p.fromSeq) && p.fromSeq >= 0 ? p.fromSeq : 0;
    let meta;
    let all;
    const live = ctx.sessions.get(sessionId);
    if (live) {
      meta = live.header;
      all = live.events;
    } else {
      const read = await ctx.sessionPersistence.readFrom(sessionId, 0);
      meta = read.meta;
      all = read.events;
    }
    // Walk backwards so we keep the most recent N transcript events, then
    // restore chronological order for display. `truncated` counts only the
    // events we would actually show (chunks/headers are dropped regardless).
    const filtered = [];
    let messageCount = 0;
    for (let i = all.length - 1; i >= 0; i--) {
      const e = all[i];
      if (e.seq < fromSeq || !HISTORY_EVENT_TYPES.has(e.type)) continue;
      messageCount++;
      if (filtered.length < MAX_HISTORY_EVENTS) filtered.push(e);
    }
    filtered.reverse();
    // `running` tells the app the AI is mid-turn (generating a reply) so it can
    // hide the input box and show a progress state instead.
    const agent = ctx.agents.get(sessionId);
    const running = agent?.status === "running";
    return {
      meta,
      events: filtered.map(serializeEvent).filter((x) => x !== null),
      truncated: messageCount > MAX_HISTORY_EVENTS,
      running,
    };
  }

  /** Concatenate only the visible `text` blocks of a message content array,
   *  dropping reasoning (think) and tool-call/tool-result blocks. */
  function extractText(content) {
    let text = "";
    if (Array.isArray(content)) {
      for (const block of content) {
        if (block && block.type === "text" && typeof block.text === "string") {
          text += block.text;
        }
      }
    }
    return text.length > MAX_MESSAGE_CHARS ? text.slice(0, MAX_MESSAGE_CHARS) + "\n…[truncated]" : text;
  }

  function serializeEvent(e) {
    if (e.type === "user/message") {
      const text = extractText(e.data?.content);
      // Blank bubbles in the app come from empty/whitespace-only messages —
      // drop them entirely (readHistory filters nulls afterwards).
      if (text.trim().length === 0) return null;
      return { type: "user", seq: e.seq, time: e.time, text };
    }
    if (e.type === "assistant/message") {
      const text = extractText(e.data?.message?.content);
      if (text.trim().length === 0) return null;
      return { type: "assistant", seq: e.seq, time: e.time, text };
    }
    return null;
  }

  async function createSession(p) {
    const defaultModel = ctx.get("agentDefaultModel");
    const selection = defaultModel?.currentSelection?.();
    const provider = p.provider ?? selection?.provider;
    const model = p.model ?? selection?.model;
    const { agent } = await ctx.agents.create({
      sessionId: SessionId(`session-${randomUUID()}`),
      meta: { cwd: p.cwd || process.cwd() },
      ...(provider && model ? { agentOptions: { provider, model } } : {}),
      ...(selection
        ? {
            setup: (agentCtx) => {
              installModelSelection(agentCtx, { current: selection, assembled: void 0 });
            },
          }
        : {}),
    });
    await agent.whenIdle();
    return { sessionId: agent.id, cwd: agent.session.header.cwd };
  }

  async function promptSession(p) {
    const { sessionId, text } = p;
    if (!sessionId || typeof text !== "string") throw new Error("sessionId and text required");
    let agent = ctx.agents.get(sessionId);
    if (!agent) {
      const handle = await ctx.agents.resume({ resumeSessionId: sessionId });
      agent = handle.agent;
    }
    agent.followup(
      createUserMessage({
        content: [{ type: "text", text }],
        source: { kind: "user" },
      }),
    );
    return { ok: true, sessionId };
  }

  async function listDir(p) {
    if (!p.path) throw new Error("path required");
    const target = await ctx.fs.resolve(p.path);
    const entries = await ctx.fs.listDir(target);
    return { entries: entries.map((e) => ({ name: e.name, type: e.type, size: e.size })) };
  }

  async function readText(p) {
    if (!p.path) throw new Error("path required");
    const target = await ctx.fs.resolve(p.path);
    const content = await ctx.fs.readText(target);
    const truncated = content.length > maxTextBytes;
    return { content: truncated ? content.slice(0, maxTextBytes) + "\n…[truncated]" : content };
  }

  // ── startup + heartbeat + cleanup ──────────────────────────────────────
  connect();
  heartbeatTimer = setInterval(() => {
    if (connected) send({ v: PROTOCOL_VERSION, type: "ping", t: Date.now() });
  }, heartbeatMs);

  ctx.effect(() => () => {
    closed = true;
    if (reconnectTimer) clearTimeout(reconnectTimer);
    if (heartbeatTimer) clearInterval(heartbeatTimer);
    if (ws) {
      try {
        ws.close();
      } catch {
        /* ignore */
      }
    }
  });
}

export { Config, apply, inject, name };

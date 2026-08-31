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
import { readFileSync } from "node:fs";
import os from "node:os";
import z from "@deepseek-ai/schemastery";
import { createUserMessage } from "@deepseek-ai/dsh-llm";
import { SessionId } from "@deepseek-ai/dsh-session";
import { installModelSelection } from "@deepseek-ai/dsh-agent";

/** Stable Cordis plugin id. */
const name = "remote-monitor";

/** Services this plugin requires before it mounts. `compaction` is NOT listed
 *  here on purpose: it may be absent (no compaction backend), and a hard inject
 *  would stall the whole plugin waiting for it. We read it lazily via
 *  `ctx.compaction` with an availability check in `compactSession`.
 *  `userQuestions` is also optional: the api-proxy may own the provider. */
const inject = ["agents", "sessions", "sessionPersistence", "sessionQuery", "fs", "workspaceRegistry", "llm"];

/** Read this package's version from its own package.json so the hello frame
 *  reports the real installed version (kept in sync across market updates
 *  without editing this file). Falls back to "0.0.0" if the file is missing. */
function readPackageVersion() {
  try {
    const pkg = JSON.parse(readFileSync(new URL("../package.json", import.meta.url), "utf8"));
    if (pkg && typeof pkg.version === "string" && pkg.version.length > 0) return pkg.version;
  } catch {
    /* fall through */
  }
  return "0.0.0";
}
const PACKAGE_VERSION = readPackageVersion();

/** Validated plugin config, supplied from the cordis.patch.yml insert row. */
const Config = z.object({
  relayUrl: z.string().required(),
  token: z.string().role("secret").default(""),
  name: z.string().default(""),
  maxTextBytes: z.number().default(262144),
  heartbeatMs: z.number().default(30000),
  /** Auto-compact: after a turn finishes, compact the session when its
   *  context usage reaches the threshold. Off by default; enable via
   *  cordis.patch.yml config. */
  autoCompactEnabled: z.boolean().default(false),
  autoCompactThreshold: z.number().default(0.8),
  autoCompactCooldownMs: z.number().default(600000),
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

  // Optional services — read through ctx.inject so Cordis permits access
  // WITHOUT making them hard dependencies (a missing service must not stall
  // plugin mounting). Callbacks fire when the service appears; variables stay
  // null when it never does. `commands` is the host command registry — the
  // `/compact` handler is registered there per agent, so runCompact drives
  // compaction through `commands.execute(agent, "/compact", signal)`, the
  // exact same path the DSH UI uses. (The `compaction` service itself lives
  // in the per-agent realm and cannot be injected from the host.)
  let tokenMeter = null;
  let commandsSvc = null;
  let projectionsSvc = null;
  ctx.inject(["tokenMeter"], (c) => {
    tokenMeter = c.tokenMeter;
  });
  ctx.inject(["commands"], (c) => {
    commandsSvc = c.commands;
  });
  ctx.inject(["sessionProjections"], (c) => {
    projectionsSvc = c.sessionProjections;
  });

  // ── auto-compact state ─────────────────────────────────────────────────
  // Runs only when `autoCompactEnabled` is set in the plugin config. After
  // each completed turn we measure the session's context usage; when it
  // reaches `autoCompactThreshold`, we run compaction once (per-session
  // cooldown prevents thrash) and emit `session.autocompact` events.
  const autoCompactEnabled = config.autoCompactEnabled === true;
  const autoCompactThreshold = config.autoCompactThreshold ?? 0.8;
  const autoCompactCooldownMs = config.autoCompactCooldownMs ?? 600000;
  const autoCompactInflight = new Set();
  const autoCompactLastAt = new Map();

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
        version: PACKAGE_VERSION,
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
      // Auto-compact check: wait for the reply to settle, then measure and
      // compact if the threshold is hit. Fire-and-forget — never blocks the
      // event pipeline.
      if (autoCompactEnabled) {
        const sid = session.id;
        setTimeout(() => {
          maybeAutoCompact(sid).catch(() => {});
        }, 2500);
      }
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
      case "session.title":
        return readSessionTitle(p);
      case "session.history":
        return readHistory(p);
      case "session.usage":
        return readUsage(p);
      case "session.debug":
        return debugAgent(p);
      case "session.compact":
        return acceptCompact(p);
      case "session.create":
        return createSession(p);
      case "model.list":
        return listModels();
      case "session.prompt":
        return promptSession(p);
      case "session.selectModel":
        return selectSessionModel(p);
      case "session.permission":
        return setSessionPermission(p);
      case "question.answer":
        return answerQuestion(p);
      case "session.questions":
        return readQuestions(p);
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
    // Return sessions (live + cold) so the monitor app shows the same list as
    // the DSH desktop after a restart.  Cold sessions carry `live: false` and
    // `running: false`; the app can still read their history via
    // `session.history` (which falls back to persistence).
    //
    // App-pull sync: the caller pages through a stable ordered snapshot with
    // `limit`/`offset` (default 20, the phone's first page), and titles are
    // folded INLINE via the batch `readTitleSnapshots` — one request serves the
    // whole page, replacing the old N+1 `session.title` waterfall on the app.
    const limit = Number.isInteger(p?.limit) && p.limit > 0 ? p.limit : 20;
    const offset = Number.isInteger(p?.offset) && p.offset >= 0 ? p.offset : 0;
    const records = await ctx.sessionQuery.listSessions();
    const wantCwd = typeof p?.cwd === "string" && p.cwd.length > 0 ? normalizeCwd(p.cwd) : null;
    const candidates = [];
    for (const r of records) {
      const h = r.header;
      // Subagent child sessions are noise for the monitor app — skip them.
      if (h.origin === "subagent") continue;
      if (wantCwd !== null && normalizeCwd(h.cwd) !== wantCwd) continue;
      candidates.push(r);
    }
    const rows = [];
    for (const r of candidates) {
      const h = r.header;
      const isLive = r.live === true;
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
        live: isLive,
        title: null,
        updatedAt,
        running: isLive ? ctx.agents.get(h.id)?.status === "running" : false,
      });
    }
    // Running sessions first, then live, then most recent activity first.
    rows.sort((a, b) => Number(b.running) - Number(a.running) || Number(b.live) - Number(a.live) || (b.updatedAt ?? 0) - (a.updatedAt ?? 0));
    const page = rows.slice(offset, offset + limit);
    // Fold titles for exactly this page (batch — O(1) requests). Best-effort:
    // a failed title read leaves `title: null` and the app shows a cwd/id
    // fallback, matching the old lazy-loader behavior.
    if (page.length > 0) {
      try {
        const snapshots = await ctx.sessionQuery.readTitleSnapshots(page.map((r) => r.id));
        const titleById = new Map();
        for (const res of snapshots) {
          if (res?.status === "fulfilled" && res.value?.title) {
            titleById.set(res.sessionId, res.value.title.title);
          }
        }
        for (const row of page) {
          if (titleById.has(row.id)) row.title = titleById.get(row.id);
        }
      } catch {
        // titles best-effort — leave rows as-is
      }
    }
    return { rows: page, hasMore: offset + page.length < rows.length };
  }

  /** Read the log-backed title for one session (used by the lazy title loader).
   *  Falls back to the first user message when the log has no `session/title`
   *  event, so every session ends up with a recognizable label. */
  async function readSessionTitle(p) {
    const sessionId = p.sessionId;
    if (!sessionId) throw new Error("sessionId required");
    try {
      const title = await ctx.sessionQuery.readTitle(sessionId);
      if (title && title.trim().length > 0) {
        return { sessionId, title };
      }
    } catch {
      // fall through to message-based fallback
    }
    // Fallback: first user message, read from the same source `readHistory`
    // uses (live memory, else persistence) so it works for cold sessions too.
    try {
      let events;
      const live = ctx.sessions.get(sessionId);
      if (live) {
        events = live.events;
      } else {
        const read = await ctx.sessionPersistence.readFrom(sessionId, 0);
        events = read.events;
      }
      for (const e of events) {
        if (e.type === "user/message") {
          const text = extractText(e.data?.content).trim();
          if (text.length > 0) {
            const label = text.length > 40 ? text.slice(0, 40) + "…" : text;
            return { sessionId, title: label };
          }
        }
      }
    } catch {
      // ignore — no fallback available
    }
    return { sessionId, title: null };
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

  /** Diagnostics for why compaction is (not) reachable from the host plugin.
   *  Temporary aid — probes the agent context's service resolution paths. */
  async function debugAgent(p) {
    const sessionId = p.sessionId;
    const out = { sessionId, agent: false };
    const agent = ctx.agents.get(sessionId);
    if (!agent) return out;
    out.agent = true;
    const agentCtx = agent.ctx;
    out.hasCtx = !!agentCtx;
    if (!agentCtx) return out;
    const safe = (label, fn) => {
      try {
        const v = fn();
        return { label, ok: true, type: typeof v, value: v === null ? null : String(v).slice(0, 80) };
      } catch (e) {
        return { label, ok: false, error: e?.message ?? String(e) };
      }
    };
    out.proxyAccess = safe("agentCtx.compaction", () => agentCtx.compaction);
    out.ctxGet = safe("agentCtx.get", () => agentCtx.get("compaction"));
    out.ctxGetStrictFalse = safe("agentCtx.get(false)", () => agentCtx.get("compaction", false));
    try {
      const ISO = Symbol.for("cordis.isolate");
      const iso = agentCtx[ISO];
      out.isolateKeys = typeof iso === "object" && iso !== null ? Object.keys(iso) : [];
      out.isolateCompact = typeof iso === "object" && iso !== null ? String(iso["compaction"]) : null;
      const chain = [];
      let f = agentCtx.fiber;
      let guard = 0;
      while (f && guard++ < 12) {
        const store = f.store ?? {};
        chain.push({
          name: f.name ?? "?",
          runtime: !!f.runtime,
          hasCompaction: Object.prototype.hasOwnProperty.call(store, "compaction"),
          storeKeys: Object.keys(store).slice(0, 40),
        });
        f = f.parent?.fiber;
      }
      out.fiberChain = chain;
    } catch (e) {
      out.fiberError = e?.message ?? String(e);
    }
    out.hostCompact = safe("ctx.compaction", () => ctx.compaction);
    return out;
  }

  /** Measure one LIVE session's context usage. Prefers the same
   *  `contextPressure` projection the web GUI displays (its `projectedTokens`
   *  = last request pressure + surface growth since), so the phone's usage
   *  bar matches the desktop. Falls back to `tokenMeter.measure` + the
   *  `request/context` fold when the projection registry is absent. Returns
   *  null when nothing usable is available. */
  function measureUsage(live) {
    if (projectionsSvc !== null) {
      try {
        const p = projectionsSvc.snapshot(live)?.values?.contextPressure;
        if (p !== undefined) {
          const contextWindow = typeof p.contextWindow === "number" ? p.contextWindow : null;
          const surfaceTokens = typeof p.surfaceTokens === "number" ? p.surfaceTokens : null;
          // A just-compacted session legitimately reports projectedTokens = 0
          // (the surface shrank below the last sample point) while it still has
          // visible content. Null the projected numerator in that case so the
          // phone falls back to `surfaceTokens` instead of drawing a misleading
          // "0%" bar; only a truly empty session ends up at 0.
          let projectedTokens = typeof p.projectedTokens === "number" ? p.projectedTokens : null;
          if (projectedTokens === 0 && surfaceTokens !== null && surfaceTokens > 0) {
            projectedTokens = null;
          }
          return {
            contextWindow,
            pressureTokens: typeof p.pressureTokens === "number" ? p.pressureTokens : null,
            projectedTokens,
            surfaceTokens,
            sampledSurfaceTokens: typeof p.sampledSurfaceTokens === "number" ? p.sampledSurfaceTokens : null,
          };
        }
      } catch {
        // fall through to tokenMeter.measure
      }
    }
    let contextWindow = null;
    let surfaceTokens = null;
    let totalTokens = null;
    for (const e of live.events) {
      if (e.type === "request/context" && typeof e.data?.contextWindow === "number") {
        contextWindow = e.data.contextWindow;
      }
    }
    if (tokenMeter !== null) {
      try {
        const m = tokenMeter.measure(live);
        surfaceTokens = typeof m.surfaceTokens === "number" ? m.surfaceTokens : null;
        totalTokens = typeof m.totalTokens === "number" ? m.totalTokens : null;
      } catch {
        // fall through — measurement failed
      }
    }
    if (contextWindow === null && surfaceTokens === null && totalTokens === null) return null;
    return {
      contextWindow,
      pressureTokens: totalTokens,
      projectedTokens: totalTokens,
      surfaceTokens,
      sampledSurfaceTokens: null,
    };
  }

  /** Context fill ratio (0..1+) of a usage object, or null when incalculable.
   *  Numerator matches the web: `projectedTokens` → `pressureTokens` →
   *  `surfaceTokens`. */
  function usagePercent(usage) {
    const win = usage?.contextWindow;
    const used = usage?.projectedTokens ?? usage?.pressureTokens ?? usage?.surfaceTokens;
    if (typeof win !== "number" || win <= 0) return null;
    if (typeof used !== "number" || used <= 0) return null;
    return used / win;
  }

  /** Read the session's context/token usage. */
  async function readUsage(p) {
    const sessionId = p.sessionId;
    if (!sessionId) throw new Error("sessionId required");
    const live = ctx.sessions.get(sessionId);
    let usage = null;
    try {
      if (live) {
        usage = measureUsage(live);
      }
    } catch {
      usage = null;
    }
    return { sessionId, usage };
  }

  /** Read the preset id a session runs under. Mirrors the api-session-controller's
   *  projected observation so a session prompted through the relay mounts the
   *  same per-agent tools instead of falling back to host-plane tools only.
   *  The `agentPreset` Session projection (header.agentPreset, then the last
   *  `agent-preset/selected` event) is registered by dsh-agent-presets and is
   *  the SDK-supported replacement for the removed `resolveSessionPreset()`. */
  async function sessionPresetId(sessionId) {
    const presets = ctx.get("agentPresets");
    if (presets === undefined) return undefined;
    try {
      const observation = await ctx.sessionQuery.observeSession(sessionId);
      try {
        return observation.projections?.values?.agentPreset ?? undefined;
      } finally {
        observation[Symbol.dispose]?.();
      }
    } catch {
      return undefined;
    }
  }

  /** The provider/model a session's last request actually ran under: read from
   *  the live session's folded header, else from the last `request/header`
   *  event in persistence. Mirrors the api-proxy's `selectionFor` getter so the
   *  resumed agent keeps the conversation's own model instead of the default. */
  async function loggedModelOf(sessionId) {
    const live = ctx.sessions.get(sessionId);
    if (live) {
      try {
        const header = live.requestHeader?.();
        if (header?.config?.provider && header?.config?.model) {
          return { provider: header.config.provider, model: header.config.model };
        }
      } catch {
        // ignore
      }
      return null;
    }
    try {
      const read = await ctx.sessionPersistence.readFrom(sessionId, 0);
      const events = read.events ?? [];
      for (let i = events.length - 1; i >= 0; i--) {
        const e = events[i];
        if (e.type === "request/header" && e.data?.header?.config) {
          const c = e.data.header.config;
          if (c.provider && c.model) return { provider: c.provider, model: c.model };
        }
      }
    } catch {
      // ignore
    }
    return null;
  }

  /** Resume (or reuse) the agent for a session, waiting until it is idle.
   *  Shared by prompt/compact so cold sessions come back with the model
   *  selection and the session's agent preset installed before any follow-up
   *  work. */
  async function ensureAgent(sessionId) {
    let agent = ctx.agents.get(sessionId);
    if (!agent) {
      const defaultModel = ctx.get("agentDefaultModel");
      const selection = defaultModel?.currentSelection?.();
      const logged = await loggedModelOf(sessionId);
      const effective = logged ?? (selection ? { provider: selection.provider, model: selection.model } : null);
      const presetId = await sessionPresetId(sessionId);
      // When the api-proxy is mounted it owns the model selection: its
      // `selectionFor` is the single source of truth and registers itself on
      // first touch. Installing a listener HERE would register first and, being
      // outermost in the Cordis waterfall, override every later switch (from
      // the app OR the web GUI) — the root cause of "app model switch ignored".
      // So with the api-proxy we seed the resumed agent's AgentOptions with the
      // effective model (logged ?? default) and install NO listener; without it
      // (non-web profile) we keep the direct listener fallback.
      const handle = await ctx.agents.resume({
        resumeSessionId: sessionId,
        ...(apiProxySessions !== null && effective ? { agentOptions: { provider: effective.provider, model: effective.model } } : {}),
        setup: async (agentCtx) => {
          if (apiProxySessions === null && selection) {
            installModelSelection(agentCtx, { current: selection, assembled: void 0 });
          }
          const presets = ctx.get("agentPresets");
          if (presets !== undefined) {
            await presets.mount(agentCtx, presetId);
          }
        },
      });
      agent = handle.agent;
    }
    await agent.whenIdle();
    return agent;
  }

  /** Execute a slash-command through the host command registry. Bridges the
   *  DSH rc.7 → rc.8 signature change: rc.8 inserted an `images` parameter
   *  between `line` and `signal` — `execute(agent, line, images, signal)`.
   *  We detect the arity so one plugin build works on both DSH versions. */
  function executeCommand(agent, line, signal) {
    if (commandsSvc === null) {
      throw new Error("commands service unavailable");
    }
    if (commandsSvc.execute.length >= 4) {
      return commandsSvc.execute(agent, line, [], signal);
    }
    return commandsSvc.execute(agent, line, signal);
  }

  /** Run one compaction pass for the session (manual `session.compact` and
   *  the auto-compact trigger both go through here). Drives the `/compact`
   *  command through the host command registry — the same code path as the
   *  DSH UI button. */
  async function runCompact(sessionId) {
    const agent = await ensureAgent(sessionId);
    // CompactNow invokes an LLM to write the summary — it can hang when the
    // model quota is exhausted, and large sessions legitimately take minutes
    // to summarize their whole history. Race it against a generous timeout so
    // callers neither spin forever nor abort a slow-but-healthy summary.
    const controller = new AbortController();
    const timeoutMs = 180000;
    const outcome = await Promise.race([
      executeCommand(agent, "/compact", controller.signal),
      new Promise((_, reject) =>
        setTimeout(() => {
          controller.abort();
          reject(new Error("compaction timed out after 180s (summary LLM slow or quota exhausted)"));
        }, timeoutMs),
      ),
    ]);
    if (outcome === undefined) {
      throw new Error("compact command not found (agent preset has no compaction)");
    }
    const r = outcome.result;
    return {
      sessionId,
      compacted: r?.kind === "success",
      text: r?.text ?? null,
      summarySeq: r?.sourceEventSeq ?? null,
    };
  }

  /** Run one compaction pass and emit `session.autocompact` progress events.
   *  Shared by the auto-compact trigger (`reason: "auto"`) and the manual
   *  `session.compact` request (`reason: "manual"`). Fire-and-forget on the
   *  caller side: the summary LLM can take tens of seconds (or longer under
   *  quota pressure), so callers observe progress through the event stream
   *  instead of blocking on a request that would outlive the relay/app
   *  request timeouts. */
  async function runCompactWithEvents(sessionId, reason) {
    if (autoCompactInflight.has(sessionId)) return;
    autoCompactInflight.add(sessionId);
    emitEvent("session.autocompact", sessionId, { status: "start", reason });
    try {
      const result = await runCompact(sessionId);
      let usageAfter = null;
      try {
        const live2 = ctx.sessions.get(sessionId);
        if (live2) usageAfter = measureUsage(live2);
      } catch {
        // ignore — no post-compaction measurement
      }
      if (reason === "auto") autoCompactLastAt.set(sessionId, Date.now());
      emitEvent("session.autocompact", sessionId, {
        status: "done",
        reason,
        text: result.text,
        summarySeq: result.summarySeq,
        usageAfter,
        percentAfter: usagePercent(usageAfter),
      });
    } catch (error) {
      emitEvent("session.autocompact", sessionId, {
        status: "error",
        reason,
        message: error?.message ?? String(error),
      });
    } finally {
      autoCompactInflight.delete(sessionId);
    }
  }

  /** Auto-compact trigger: measure the session, compact when usage hits the
   *  configured threshold, emit `session.autocompact` progress events. */
  async function maybeAutoCompact(sessionId) {
    if (!autoCompactEnabled) return;
    if (autoCompactInflight.has(sessionId)) return;
    const now = Date.now();
    const last = autoCompactLastAt.get(sessionId) ?? 0;
    if (now - last < autoCompactCooldownMs) return;
    const live = ctx.sessions.get(sessionId);
    if (!live) return; // cold sessions have no live context to compact
    let usage = null;
    try {
      usage = measureUsage(live);
    } catch {
      return;
    }
    const percent = usagePercent(usage);
    if (percent === null || percent < autoCompactThreshold) return;
    await runCompactWithEvents(sessionId, "auto");
  }

  /** Manual compact request: fire-and-forget. Acknowledges immediately (the
   *  LLM summary can exceed the relay/app request timeout) and reports
   *  progress through `session.autocompact` events. */
  function acceptCompact(p) {
    const sessionId = p.sessionId;
    if (!sessionId) throw new Error("sessionId required");
    runCompactWithEvents(sessionId, "manual").catch(() => {});
    return { sessionId, accepted: true };
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
    const presets = ctx.get("agentPresets");
    const agentPreset = presets === undefined ? undefined : (await presets.resolve(undefined)).id;
    // Same model-selection discipline as ensureAgent: when the api-proxy is
    // mounted it owns the selection, so we seed AgentOptions and skip the
    // listener (a listener here would become the outermost waterfall override
    // and silently veto later switches). Without the api-proxy we keep the
    // direct install as the only wiring.
    const { agent } = await ctx.agents.create({
      sessionId: SessionId(`session-${randomUUID()}`),
      meta: {
        cwd: p.cwd || process.cwd(),
        ...(agentPreset === undefined ? {} : { agentPreset }),
      },
      ...(provider && model ? { agentOptions: { provider, model } } : {}),
      setup: async (agentCtx) => {
        if (apiProxySessions === null && selection) {
          installModelSelection(agentCtx, { current: selection, assembled: void 0 });
        }
        if (presets !== undefined) {
          await presets.mount(agentCtx, agentPreset);
        }
      },
    });
    await agent.whenIdle();
    // Attach the session to the workspace owning this cwd so it is grouped,
    // matching what the DSH UI does after creating a session. Best-effort:
    // a session is still created even if no matching workspace exists.
    try {
      const cwd = agent.session.header.cwd;
      let ws;
      if (cwd) {
        try {
          ws = await ctx.workspaceRegistry.resolveByPath(cwd);
        } catch {
          ws = undefined;
        }
        if (!ws) {
          ws = ctx.workspaceRegistry.list().find((w) => w.path === cwd);
        }
      }
      if (ws) {
        await ws.attachSession(agent.id);
      }
    } catch {
      // ignore — grouping failed, session is still usable
    }
    return { sessionId: agent.id, cwd: agent.session.header.cwd };
  }

  /** List every registered provider and its models for the session picker. */
  async function listModels() {
    const providers = [];
    let defaultSelection = null;
    try {
      const defaultModel = ctx.get("agentDefaultModel");
      defaultSelection = defaultModel?.currentSelection?.() ?? null;
    } catch {
      // agentDefaultModel may be absent — that's fine.
    }
    const infos = ctx.llm?.listProviders?.() ?? [];
    for (const info of infos) {
      let models = [];
      try {
        const found = await ctx.llm.listModels(info.id);
        models = (found ?? []).map((m) => ({
          id: m.id,
          name: m.name || m.id,
          description: m.description ?? "",
        }));
      } catch {
        models = [];
      }
      providers.push({
        id: info.id,
        name: info.name || info.id,
        models,
      });
    }
    return {
      providers,
      default: defaultSelection
        ? { provider: defaultSelection.provider, model: defaultSelection.model }
        : null,
    };
  }

  async function promptSession(p) {
    const { sessionId, text } = p;
    if (!sessionId || typeof text !== "string") throw new Error("sessionId and text required");
    const agent = await ensureAgent(sessionId);
    agent.followup(
      createUserMessage({
        content: [{ type: "text", text }],
        source: { kind: "user" },
      }),
    );
    return { ok: true, sessionId };
  }

  /** Switch the model provider/model for an existing session.
   *
   *  Preferred path (web mode): call the api-proxy's own `session.selectModel`
   *  handler — the exact path the web GUI uses. It mutates the SAME model
   *  selection object the api-proxy installed on the agent (so the switch is
   *  NOT overridden by that pre-installed listener) and records the new model
   *  as the default. Installing a parallel `installModelSelection` listener
   *  instead is subtly broken: the api-proxy's listener is registered first,
   *  i.e. outermost in the Cordis waterfall, so it applies its (default/logged)
   *  override LAST on `agent/request` and the app's choice is discarded.
   *
   *  Fallback (non-web profile, no api-proxy): the direct install path below,
   *  which is what the monitor app used before api-proxy integration. */
  async function selectSessionModel(p) {
    const { sessionId, provider, model } = p;
    if (!sessionId || !provider || !model) throw new Error("sessionId, provider, and model required");
    if (apiProxySessions !== null) {
      // On rejection (agent-busy / session-not-found / model-unavailable) the
      // error propagates to the caller as-is — we must NOT fall back to the
      // stacking install, which would look like success while the switch does
      // not take effect.
      const resp = await apiProxySessions.selectModel({
        rpcId: randomUUID(),
        payload: {
          sessionId,
          provider,
          model,
          ...(p.reasoningEffort ? { reasoningEffort: p.reasoningEffort } : {}),
        },
      });
      if (resp.result?.ok === true) {
        // api-proxy returns { selected: ModelSelection } — unwrap one level so
        // the wire result stays { selected: { provider, model } } (the shape
        // the app's SessionSelectModelResult expects).
        const value = resp.result.value;
        const selected = value?.selected ?? value;
        return { selected: { ...selected } };
      }
      throw new Error(resp.result?.error?.message ?? "model switch failed");
    }
    // Non-web fallback: install the selection into the agent's context so
    // subsequent turns use the new model. Note: when the api-proxy is absent
    // this is the only selection wiring, so it works; when it IS present we
    // never reach here.
    const agent = await ensureAgent(sessionId);
    installModelSelection(agent.ctx, {
      current: { provider, model, ...(p.reasoningEffort ? { reasoningEffort: p.reasoningEffort } : {}) },
      assembled: void 0,
    });
    return { selected: { provider, model } };
  }

  /** Switch the permission preset for an existing session. Runs the
   *  `/permission` command in the agent's context, the same path the
   *  desktop GUI uses. */
  async function setSessionPermission(p) {
    const { sessionId, preset } = p;
    if (!sessionId || !preset) throw new Error("sessionId and preset required");
    const agent = await ensureAgent(sessionId);
    const outcome = await executeCommand(agent, `/permission ${preset}`, new AbortController().signal);
    if (outcome === undefined) {
      throw new Error("permission command not found (host has no /permission command)");
    }
    const r = outcome.result;
    return {
      sessionId,
      switched: r?.kind === "success",
      preset,
    };
  }

  /** Relay plugin's own pending-question table, populated only when the relay
   *  plugin is the sole userQuestions provider (non-web mode). Keyed by rpcId. */
  const relayPendingQuestions = new Map();

  /** Server-side cache of pending questions, keyed by session id. This is the
   *  durable state the app reads via `session.questions`, so a client that was
   *  offline when `question/requested` fired still recovers the card. */
  const pendingQuestionsBySession = new Map();

  function cacheQuestion(sessionId, questions, rpcId) {
    pendingQuestionsBySession.set(sessionId, { questions, rpcId });
  }

  function clearQuestion(sessionId) {
    pendingQuestionsBySession.delete(sessionId);
  }

  /** The Web GUI's question responder, captured when the api-proxy is loaded.
   *  When non-null, question answers flow through it (`ctx.apiProxy.respond`),
   *  which is exactly the same path the Web GUI's own answer button uses. */
  let apiProxyRespond = null;
  let apiProxyMuxAbort = null;

  /** The api-proxy's sessions surface (web mode). `session.selectModel` routes
   *  through it so a model switch mutates the SAME selection object the web GUI
   *  owns (and saves the default). The alternative — installing a second
   *  `installModelSelection` listener — is overridden by the api-proxy's
   *  pre-installed listener in Cordis waterfalls (first-registered listener is
   *  outermost and applies its override last), which is exactly why app-side
   *  model switches were silently ignored. */
  let apiProxySessions = null;

  /** Capture the api-proxy's mux stream so the relay plugin learns each
   *  pending question's stable rpcId (the api-proxy mints it, and only the
   *  mux carries it). We forward question/requested WITH the rpcId, then the
   *  app echoes it back and `answerQuestion` proxies through apiProxy.respond.
   *  We also forward question/resolved so the phone clears the card when the
   *  question is answered or cancelled from either surface. */
  ctx.inject(["apiProxy"], (scope) => {
    apiProxyRespond = scope.apiProxy.respond;
    apiProxySessions = scope.apiProxy.sessions;
    const controller = new AbortController();
    apiProxyMuxAbort = controller;
    (async () => {
      try {
        for await (const envelope of scope.apiProxy.events.mux({}, controller.signal)) {
          const payload = envelope?.payload;
          if (payload?.type === "question/requested") {
            cacheQuestion(payload.sessionId, payload.questions, envelope.rpcId);
            emitEvent("question/requested", payload.sessionId, {
              questions: payload.questions,
              rpcId: envelope.rpcId,
            });
          } else if (payload?.type === "question/resolved") {
            clearQuestion(payload.sessionId);
            emitEvent("question/resolved", payload.sessionId, {
              questionRpcId: payload.questionRpcId,
              outcome: payload.outcome,
            });
          }
        }
      } catch {
        // Mux stream closed (abort on dispose, or api-proxy teardown).
      }
    })();
  });

  /** Register the relay plugin as the userQuestions provider. In web mode the
   *  api-proxy already owns the provider, so this throws DUPLICATE_PROVIDER
   *  and we ignore it (the mux path above handles web mode). In non-web mode
   *  the relay plugin becomes the sole provider and answers directly. */
  ctx.inject(["userQuestions"], (scope) => {
    try {
      scope.userQuestions.registerProvider({
        ask(request) {
          const sessionId = request.agent?.id;
          if (sessionId === undefined) {
            return Promise.reject(new Error("web user interaction requires an agent-owned session"));
          }
          return new Promise((resolve, reject) => {
            const rpcId = randomUUID();
            const pending = { rpcId, sessionId, questions: request.questions, resolve, reject };
            relayPendingQuestions.set(rpcId, pending);
            cacheQuestion(sessionId, request.questions, rpcId);
            // Forward the question batch to the app.
            emitEvent("question/requested", sessionId, {
              questions: request.questions,
              rpcId,
            });
            // Clean up on abort.
            if (request.signal) {
              const onAbort = () => {
                relayPendingQuestions.delete(rpcId);
                clearQuestion(sessionId);
                emitEvent("question/resolved", sessionId, {
                  questionRpcId: rpcId,
                  outcome: "cancelled",
                });
                reject(new Error("ask_user_question was aborted"));
              };
              request.signal.addEventListener("abort", onAbort, { once: true });
            }
          });
        },
      });
    } catch (error) {
      // DUPLICATE_PROVIDER: the api-proxy already registered. The mux path
      // above handles question forwarding in web mode.
      if (error?.code !== "DUPLICATE_PROVIDER") {
        throw error;
      }
    }
  });

  /** Answer a pending question from the agent. Preferred path: proxy through
   *  the Web GUI's api-proxy responder (web mode). Fallback: the relay
   *  plugin's own pending table (non-web mode). */
  async function answerQuestion(p) {
    const { sessionId, questionRpcId, answers } = p;
    if (!sessionId || !questionRpcId || !Array.isArray(answers)) {
      throw new Error("sessionId, questionRpcId, and answers[] required");
    }
    // Preferred: answer through the Web GUI's responder.
    if (apiProxyRespond !== null) {
      const receipt = await apiProxyRespond({
        rpcId: questionRpcId,
        result: {
          ok: true,
          value: {
            sessionId,
            answer: { answers },
          },
        },
      });
      if (!receipt.accepted) {
        throw new Error(`question response rejected: ${receipt.reason}`);
      }
      return { answered: true, sessionId, questionRpcId };
    }
    // Fallback: the relay plugin owns the provider (non-web mode).
    const entry = relayPendingQuestions.get(questionRpcId);
    if (entry !== undefined) {
      relayPendingQuestions.delete(questionRpcId);
      clearQuestion(sessionId);
      entry.resolve({ answers });
      emitEvent("question/resolved", sessionId, {
        questionRpcId,
        outcome: "answered",
      });
      return { answered: true, sessionId, questionRpcId };
    }
    throw new Error("no question provider available to answer this question");
  }

  /** Read the pending question batch for one session (server-side state). */
  function readQuestions(p) {
    const sessionId = p.sessionId;
    if (!sessionId) throw new Error("sessionId required");
    const pending = pendingQuestionsBySession.get(sessionId);
    if (pending === undefined) {
      return { sessionId, questions: [], rpcId: null };
    }
    return { sessionId, questions: pending.questions, rpcId: pending.rpcId };
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
    if (apiProxyMuxAbort !== null) {
      try {
        apiProxyMuxAbort.abort();
      } catch {
        /* ignore */
      }
      apiProxyMuxAbort = null;
    }
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

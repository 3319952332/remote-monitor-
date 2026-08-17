/**
 * Event-listener check: connect as client, print every event relayed from the
 * live DSH node for a few seconds (the agent is running, so tool/user events
 * should stream through).
 *
 * Run: node test/listen-events.mjs
 */
import WebSocket from "ws";

const TOKEN = "dsh-remote-dev-token";
const URL = "ws://127.0.0.1:8787";
const DURATION_MS = 30000;

const ws = new WebSocket(URL);
const seen = new Map();

ws.on("open", () => {
  ws.send(JSON.stringify({ v: 1, type: "hello", role: "client", token: TOKEN, deviceName: "listen" }));
  console.log(`listening for ${DURATION_MS}ms...`);
  setTimeout(() => {
    console.log("\n== event summary ==");
    for (const [type, count] of seen) console.log(`  ${type}: ${count}`);
    ws.close();
    process.exit(0);
  }, DURATION_MS);
});

ws.on("message", (m) => {
  const f = JSON.parse(m.toString());
  if (f.type === "event") {
    const key = f.event === "session.event" ? `session.event(${f.data?.event?.type})` : f.event;
    seen.set(key, (seen.get(key) ?? 0) + 1);
    console.log(`[event] ${key} session=${String(f.sessionId).slice(-8)}`);
  }
});

ws.on("error", (e) => {
  console.error("ws error:", e.message);
  process.exit(1);
});

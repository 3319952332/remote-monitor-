/**
 * Minimal session.create check: creates one empty agent/session through the
 * plugin (no prompt, so no LLM call) and prints the returned sessionId.
 *
 * Run: node test/create-session.mjs
 */
import WebSocket from "ws";

const TOKEN = "dsh-remote-dev-token";
const URL = "ws://127.0.0.1:8787";

const ws = new WebSocket(URL);

ws.on("open", () => {
  ws.send(JSON.stringify({ v: 1, type: "hello", role: "client", token: TOKEN, deviceName: "create-check" }));
  setTimeout(() => {
    ws.send(JSON.stringify({
      v: 1,
      type: "request",
      id: "r-create",
      method: "session.create",
      params: { cwd: "E:\\Code\\Huawei" },
    }));
  }, 300);
});

ws.on("message", (m) => {
  const f = JSON.parse(m.toString());
  if (f.type === "response" && f.id === "r-create") {
    console.log(JSON.stringify(f, null, 2));
    ws.close();
    process.exit(f.ok === true ? 0 : 1);
  } else if (f.type === "event") {
    console.log(`[event] ${f.event} session=${String(f.sessionId).slice(-8)}`);
  }
});

ws.on("error", (e) => {
  console.error("ws error:", e.message);
  process.exit(1);
});

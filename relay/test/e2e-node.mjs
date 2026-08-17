/**
 * E2E node-side check: connects to the running relay as a client and drives
 * real plugin methods against the live DSH node. Prints each response.
 *
 * Run: node test/e2e-node.mjs
 */
import WebSocket from "ws";

const TOKEN = process.env.DSH_RELAY_TOKEN ?? "your-secret-token";
const URL = "ws://127.0.0.1:8787";

const ws = new WebSocket(URL);
let seq = 0;
const pending = new Map();

function request(method, params) {
  return new Promise((resolve) => {
    const id = `r-${++seq}`;
    pending.set(id, resolve);
    ws.send(JSON.stringify({ v: 1, type: "request", id, method, params: params ?? {} }));
    setTimeout(() => {
      if (pending.has(id)) {
        pending.delete(id);
        resolve({ ok: false, error: { code: "TIMEOUT", message: `no reply for ${method}` } });
      }
    }, 10000);
  });
}

ws.on("open", async () => {
  ws.send(JSON.stringify({ v: 1, type: "hello", role: "client", token: TOKEN, deviceName: "e2e-node" }));
  await new Promise((r) => setTimeout(r, 300));

  for (const [label, method, params] of [
    ["workspace.list", "workspace.list", {}],
    ["agent.list", "agent.list", {}],
    ["session.list", "session.list", {}],
    ["fs.listDir(E:\\Code\\Huawei)", "fs.listDir", { path: "E:\\Code\\Huawei" }],
  ]) {
    const resp = await request(method, params);
    console.log(`\n== ${label} ==`);
    console.log(JSON.stringify(resp, null, 2)?.slice(0, 1200));
  }
  ws.close();
  process.exit(0);
});

ws.on("message", (m) => {
  const f = JSON.parse(m.toString());
  if (f.type === "response" && pending.has(f.id)) {
    pending.get(f.id)(f);
    pending.delete(f.id);
  } else if (f.type === "event") {
    console.log(`[event] ${f.event} session=${f.sessionId}`);
  }
});

ws.on("error", (e) => {
  console.error("ws error:", e.message);
  process.exit(1);
});

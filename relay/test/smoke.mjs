/**
 * Relay smoke test: drives a fake node + fake client through the whole
 * protocol (handshake, auth failure, local method, node request routing,
 * event broadcast) without a real DSH or HarmonyOS app.
 *
 * Run: node test/smoke.mjs
 */
import WebSocket from "ws";
import { createRelay } from "../src/index.js";

const TOKEN = "test-token";
const PORT = 18787;
const URL = `ws://127.0.0.1:${PORT}`;

let failures = 0;
function assert(cond, label) {
  if (cond) {
    console.log(`  ok  - ${label}`);
  } else {
    failures++;
    console.error(`  FAIL - ${label}`);
  }
}

/** Open a ws, send hello, resolve on welcome (or error). */
function connect(role, token, extra = {}) {
  return new Promise((resolve) => {
    const ws = new WebSocket(URL);
    const inbox = [];
    let done = false;
    const finish = (fn) => {
      if (!done) {
        done = true;
        fn();
      }
    };
    ws.on("open", () => {
      ws.send(JSON.stringify({ v: 1, type: "hello", role, token, ...extra }));
    });
    ws.on("message", (m) => {
      const f = JSON.parse(m.toString());
      inbox.push(f);
      if (f.type === "welcome") finish(() => resolve({ ws, id: f.id, inbox, settled: "welcome" }));
      else if (f.type === "error") finish(() => resolve({ ws, inbox, settled: "error", error: f }));
    });
    ws.on("close", () => finish(() => resolve({ ws, inbox, settled: "close" })));
    ws.on("error", () => finish(() => resolve({ ws, inbox, settled: "close" })));
  });
}

/** Wait until inbox accumulates a frame matching predicate, or timeout. */
function waitFor(conn, pred, timeoutMs = 3000) {
  return new Promise((resolve) => {
    const start = Date.now();
    const tick = () => {
      const hit = conn.inbox.find(pred);
      if (hit) return resolve(hit);
      if (Date.now() - start > timeoutMs) return resolve(null);
      setTimeout(tick, 20);
    };
    tick();
  });
}

async function main() {
  const relay = createRelay({
    host: "127.0.0.1",
    port: PORT,
    token: TOKEN,
    certPath: "",
    keyPath: "",
    heartbeatMs: 60000,
    requestTimeoutMs: 5000,
    notifiers: [],
  }, () => {});
  await relay.listen();

  console.log("1) auth failure rejects bad token");
  const bad = await connect("client", "wrong-token", { deviceName: "bad" });
  assert(bad.settled === "error" && bad.error?.code === "AUTH_FAILED", "bad token -> AUTH_FAILED");

  console.log("2) node handshake");
  const node = await connect("node", TOKEN, { name: "fake-node", hostname: "PC", platform: "win32" });
  assert(node.settled === "welcome", "node got welcome");

  console.log("3) client handshake");
  const client = await connect("client", TOKEN, { deviceName: "fake-app" });
  assert(client.settled === "welcome", "client got welcome");

  console.log("4) local method node.list");
  client.ws.send(JSON.stringify({ v: 1, type: "request", id: "r-local", method: "node.list", params: {} }));
  const localResp = await waitFor(client, (f) => f.type === "response" && f.id === "r-local");
  assert(localResp?.ok === true && localResp?.result?.length === 1 && localResp.result[0].name === "fake-node", "node.list returns the online node");

  console.log("5) request routed to node and back");
  // fake node: answer any request with an echo result.
  node.ws.on("message", (m) => {
    const f = JSON.parse(m.toString());
    if (f.type === "request") {
      node.ws.send(JSON.stringify({ v: 1, type: "response", id: f.id, ok: true, result: { echo: f.params } }));
    }
  });
  client.ws.send(JSON.stringify({ v: 1, type: "request", id: "r-echo", method: "workspace.list", params: { a: 1 } }));
  const echoResp = await waitFor(client, (f) => f.type === "response" && f.id === "r-echo");
  assert(echoResp?.ok === true && echoResp?.result?.echo?.a === 1, "node answered and relay forwarded the response");

  console.log("6) node event broadcast to client");
  node.ws.send(JSON.stringify({ v: 1, type: "event", id: "e1", event: "turn.end", sessionId: "session-x", data: { turn: 3, reason: { kind: "completed" } } }));
  const evt = await waitFor(client, (f) => f.type === "event" && f.event === "turn.end");
  assert(evt?.sessionId === "session-x" && evt?.data?.turn === 3, "client received turn.end broadcast");

  console.log("7) node.list after node disconnect");
  node.ws.close();
  await new Promise((r) => setTimeout(r, 200));
  client.ws.send(JSON.stringify({ v: 1, type: "request", id: "r-local2", method: "node.list", params: {} }));
  const localResp2 = await waitFor(client, (f) => f.type === "response" && f.id === "r-local2");
  assert(localResp2?.ok === true && localResp2?.result?.length === 0, "no nodes after disconnect");

  client.ws.close();
  relay.close();

  console.log(failures === 0 ? "\nALL PASSED" : `\n${failures} FAILURES`);
  process.exit(failures === 0 ? 0 : 1);
}

main().catch((error) => {
  console.error("smoke crashed:", error);
  process.exit(1);
});

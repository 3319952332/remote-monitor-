/**
 * Full-loop check: prompt the freshly created session, wait for the `turn.end`
 * event (completion push), then read history back.
 *
 * Run: node test/prompt-loop.mjs <sessionId>
 */
import WebSocket from "ws";

const TOKEN = process.env.DSH_RELAY_TOKEN ?? "your-secret-token";
const URL = "ws://127.0.0.1:8787";
const sessionId = process.argv[2];
if (!sessionId) {
  console.error("usage: node test/prompt-loop.mjs <sessionId>");
  process.exit(2);
}

const ws = new WebSocket(URL);
let prompted = false;

function request(method, params, id) {
  ws.send(JSON.stringify({ v: 1, type: "request", id, method, params }));
}

ws.on("open", () => {
  ws.send(JSON.stringify({ v: 1, type: "hello", role: "client", token: TOKEN, deviceName: "loop-check" }));
  setTimeout(() => {
    console.log(`prompting ${sessionId}...`);
    prompted = true;
    request("session.prompt", { sessionId, text: "Reply with exactly: OK" }, "r-prompt");
  }, 300);
  // hard stop
  setTimeout(() => {
    console.log("\nTIMEOUT waiting for turn.end");
    process.exit(1);
  }, 120000);
});

ws.on("message", (m) => {
  const f = JSON.parse(m.toString());
  if (f.type === "response" && f.id === "r-prompt") {
    console.log(`prompt ack: ok=${f.ok}`, f.ok ? `result=${JSON.stringify(f.result)}` : `error=${JSON.stringify(f.error)}`);
  }
  if (f.type === "event" && f.event === "turn.end") {
    console.log(`\nTURN.END received: session=${String(f.sessionId).slice(-8)} turn=${f.data?.turn} reason=${f.data?.reason?.kind}`);
    // read history back to confirm transcription
    request("session.history", { sessionId, fromSeq: 0 }, "r-history");
  }
  if (f.type === "response" && f.id === "r-history") {
    const events = f.ok ? (f.result?.events ?? null) : null;
    console.log(`history events: ${events ? events.length : 0}`);
    if (events) {
      for (const e of events) {
        if (e.type === "user/message" || e.type === "assistant/message") {
          const text = (e.data?.message?.content ?? []).map((b) => b.text ?? "").join("");
          console.log(`  [${e.type}] ${text}`);
        } else {
          console.log(`  [${e.type}]`);
        }
      }
    }
    ws.close();
    process.exit(0);
  }
});

ws.on("error", (e) => {
  console.error("ws error:", e.message);
  process.exit(1);
});

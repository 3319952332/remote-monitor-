/**
 * Regression test for `readPersistedSession` — the bridge between the
 * pre-0.1.3 `sessionPersistence.readFrom(id, seq)` primitive and the 0.1.3+
 * lifecycle-scoped `SessionHandle` API (`open(id, "read")` → `handle.read(0)`
 * → `handle.close()`).
 *
 * Run: `node test/persistence-bridge.test.mjs` (zero deps, plain Node ESM).
 */
import { readPersistedSession } from "../lib/persistence-bridge.js";

let passed = 0;
let failed = 0;
function check(label, cond) {
  if (cond) {
    passed++;
    console.log(`ok - ${label}`);
  } else {
    failed++;
    console.error(`FAIL - ${label}`);
  }
}

// ── 1. Pre-0.1.3 persistence: readFrom present → passthrough, untouched ──
{
  const events = [{ seq: 0, type: "user/message", data: { content: [{ type: "text", text: "hi" }] } }];
  const legacy = {
    readFrom: async (id, fromSeq) => ({ meta: { id }, events }),
  };
  let called = 0;
  const wrapped = {
    readFrom: async (id, fromSeq) => {
      called++;
      return legacy.readFrom(id, fromSeq);
    },
  };
  const read = await readPersistedSession(wrapped, "session-x");
  check("legacy path returns { meta, events }", read.meta?.id === "session-x" && read.events === events);
  check("legacy readFrom called with (id, 0)", called === 1);
}

// ── 2. 0.1.3+ persistence: SessionHandle open/read/close, normalized ──
{
  const header = { id: "session-y" };
  const events = [{ seq: 0, type: "user/message", data: { content: [{ type: "text", text: "yo" }] } }];
  let openedWith = null;
  let readArgs = null;
  let closed = 0;
  const handle = {
    header,
    async read(fromSeq, toSeq) {
      readArgs = [fromSeq, toSeq];
      return { events, eventState: {} };
    },
    async close() {
      closed++;
    },
  };
  const modern = {
    async open(id, mode) {
      openedWith = [id, mode];
      return handle;
    },
  };
  const read = await readPersistedSession(modern, "session-y");
  check("modern path returns normalized { meta, header, events }",
    read.meta?.id === "session-y" && read.header === header && read.events === events);
  check("open called with (id, 'read')", openedWith?.[0] === "session-y" && openedWith?.[1] === "read");
  check("handle.read called from seq 0", readArgs?.[0] === 0);
  check("handle closed exactly once", closed === 1);
}

// ── 3. modern path closes the handle even when read throws ──
{
  let closed = 0;
  const handle = {
    header: { id: "session-z" },
    async read() {
      throw new Error("corrupt log");
    },
    async close() {
      closed++;
    },
  };
  const modern = {
    async open() {
      return handle;
    },
  };
  let threw = false;
  try {
    await readPersistedSession(modern, "session-z");
  } catch (e) {
    threw = e.message === "corrupt log";
  }
  check("modern read error propagates", threw);
  check("handle closed even on read error", closed === 1);
}

// ── 4. persistence undefined → clear error, not a TypeError chain ──
{
  let msg = null;
  try {
    await readPersistedSession(undefined, "session-w");
  } catch (e) {
    msg = e.message;
  }
  check("undefined persistence rejected with clear message", msg === "sessionPersistence unavailable");
}

console.log(`\n${passed} passed, ${failed} failed`);
process.exit(failed === 0 ? 0 : 1);

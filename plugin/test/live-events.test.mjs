/**
 * Regression test for `liveEvents` — the bridge between the pre-0.1.5
 * `Session.events` property and the 0.1.5+ `Session.snapshotEvents()` method.
 *
 * Guards against the "打开聊天会话报错 Cannot read properties of undefined
 * (reading 'length')" crash: `readHistory` reads `live.events` which is
 * `undefined` on DSH 0.1.5+ live sessions (the property was removed).
 *
 * Run: `node test/live-events.test.mjs` (zero deps, plain Node ESM).
 */
import { liveEvents } from "../lib/persistence-bridge.js";

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

const events = [
  { seq: 0, type: "user/message", time: 1, data: { id: "m0" } },
  { seq: 1, type: "assistant/message", time: 2, data: { id: "m1" } },
];

// ── 1. DSH 0.1.5+ Session: only `snapshotEvents()`, no `.events` ──
{
  const live = {
    header: { id: "session-x" },
    events: undefined, // 0.1.5 removed the property entirely
    snapshotEvents: () => events,
  };
  const out = liveEvents(live);
  check("0.1.5 path uses snapshotEvents()", out === events);
  check("0.1.5 path returns a .length-able array", out.length === 2);
}

// ── 2. Pre-0.1.5 Session: only `.events`, no `snapshotEvents` ──
{
  const live = {
    header: { id: "session-x" },
    events,
  };
  const out = liveEvents(live);
  check("legacy path falls back to .events", out === events);
  check("legacy path returns a .length-able array", out.length === 2);
}

// ── 3. Edge cases: never return undefined (callers do `.length` on it) ──
{
  check("null session -> []", Array.isArray(liveEvents(null)) && liveEvents(null).length === 0);
  check("undefined session -> []", Array.isArray(liveEvents(undefined)) && liveEvents(undefined).length === 0);
  check("empty object -> []", Array.isArray(liveEvents({})) && liveEvents({}).length === 0);
  check("non-array .events -> []", Array.isArray(liveEvents({ events: "nope" })) && liveEvents({ events: "nope" }).length === 0);
}

// ── 4. readHistory pattern: `all.length` must never throw on a live session ──
{
  const live = {
    header: { id: "session-x" },
    events: undefined,
    snapshotEvents: () => events,
  };
  const all = liveEvents(live);
  let threw = false;
  try {
    for (let i = all.length - 1; i >= 0; i--) {
      /* walk backwards exactly like readHistory */
    }
  } catch {
    threw = true;
  }
  check("readHistory backwards walk does not throw on 0.1.5 live session", !threw);
}

console.log(`\n${passed} passed, ${failed} failed`);
if (failed > 0) process.exit(1);

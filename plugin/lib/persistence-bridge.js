/**
 * `readPersistedSession` — bridge for reading one full cold-session log across
 * the DSH 0.1.3 persistence API change:
 *
 *  - pre-0.1.3: `sessionPersistence.readFrom(id, fromSeq)` → `{ meta, events }`
 *  - 0.1.3+:    `sessionPersistence.open(id, "read")` → `SessionHandle` with
 *               `.header` and `.read(fromSeq, toSeq)` → `{ events }`, which
 *               MUST be `close()`d (the handle holds a lifecycle-scoped lock).
 *
 * Feature-detects `readFrom` so ONE build runs unchanged on both DSH versions.
 * Normalized return: `{ meta, header, events }` (`meta` aliases `header`).
 *
 * Deliberately dependency-free (no `@deepseek-ai/*` imports) so it can be unit
 * tested standalone and never affects the plugin's module graph.
 */

/**
 * Read one full session log from persistence (cold sessions only; live
 * sessions are read from `ctx.sessions`).
 * @param {object} persistence - the injected `sessionPersistence` service.
 * @param {string} sessionId - session to read from seq 0 to the end.
 * @returns {Promise<{meta: object, header: object, events: object[]}>}
 */
export async function readPersistedSession(persistence, sessionId) {
  if (persistence === undefined) {
    throw new Error("sessionPersistence unavailable");
  }
  if (typeof persistence.readFrom === "function") {
    // Pre-0.1.3 persistence: the legacy primitive is still present.
    return persistence.readFrom(sessionId, 0);
  }
  // 0.1.3+ persistence: lifecycle-scoped SessionHandle (read mode).
  const handle = await persistence.open(sessionId, "read");
  try {
    const read = await handle.read(0);
    return { meta: handle.header, header: handle.header, events: read.events };
  } finally {
    await handle.close();
  }
}

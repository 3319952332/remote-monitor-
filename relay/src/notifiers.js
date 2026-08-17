/**
 * Pluggable notification channels. The relay forwards `turn.end` events here
 * so long-running sessions can ping the user even when the app is backgrounded
 * or killed — the no-AGC fallback. Each channel is a plain JSON webhook:
 *   { "type": "webhook", "url": "https://...", "headers": { ... } }
 * Wire up ServerChan (https://sct.ftqq.com), a WeCom bot, or an email bridge.
 */
const TURN_END_EVENT = "turn.end";

/**
 * Build a short human summary for a `turn.end` event.
 * @param {object} msg - the event frame from a node.
 * @returns {string}
 */
export function summarizeTurnEnd(msg) {
  const data = msg.data ?? {};
  const reason = data.reason ?? {};
  const kind = reason.kind ?? "unknown";
  const session = String(msg.sessionId ?? "?").slice(-8);
  return `会话 ${session} 回合 #${data.turn ?? "?"} 完成（${kind}）`;
}

/**
 * Deliver a turn.end event to every configured channel. Failures are logged,
 * never thrown — a dead webhook must not break the live event path.
 * @param {Array<{type:string, url:string, headers?:object}>} channels
 * @param {object} msg - the turn.end event frame.
 * @param {(line:string)=>void} log
 */
export async function notifyTurnEnd(channels, msg, log) {
  if (!channels || channels.length === 0) return;
  const summary = summarizeTurnEnd(msg);
  for (const channel of channels) {
    if (!channel || channel.type !== "webhook" || !channel.url) continue;
    try {
      await fetch(channel.url, {
        method: "POST",
        headers: {
          "content-type": "application/json",
          ...(channel.headers ?? {}),
        },
        body: JSON.stringify({
          title: "DSH 会话完成",
          desp: summary,
          event: msg,
        }),
      });
    } catch (error) {
      log(`[notify] webhook ${channel.url} failed: ${error.message}`);
    }
  }
}

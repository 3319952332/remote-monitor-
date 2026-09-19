/**
 * Stable device identity helpers. A "device" here is one DSH node connected to
 * the relay; its stable key is `nodeName@hostname` (survives relay reconnects,
 * unlike the ephemeral relay-assigned nodeId), and its display label prefers
 * the configured plugin `name`.
 */

/** Stable grouping key for a node: `<name>@<hostname>`. */
export function deviceKey(nodeName: string, hostname: string): string {
  return `${nodeName}@${hostname}`;
}

/** Human label for a node: configured name first, then hostname. */
export function deviceLabel(nodeName: string, hostname: string): string {
  const name = nodeName.trim();
  if (name.length > 0 && name !== 'unnamed') {
    return name;
  }
  const host = hostname.trim();
  return host.length > 0 ? host : '未知设备';
}
/**
 * Relay configuration. Every value can be overridden by an environment
 * variable so the same code runs locally (ws://) and in the cloud (wss:// + TLS)
 * without edits.
 */
import { readFileSync } from "node:fs";
import { resolve } from "node:path";

const DEFAULT_PORT = 8787;

function intOf(value, fallback) {
  const n = Number.parseInt(value ?? "", 10);
  return Number.isFinite(n) ? n : fallback;
}

function loadConfig(env = process.env) {
  return {
    /** Listen host. 0.0.0.0 exposes on all interfaces; 127.0.0.1 is local only. */
    host: env.DSH_RELAY_HOST ?? "0.0.0.0",
    /** Listen port. */
    port: intOf(env.DSH_RELAY_PORT, DEFAULT_PORT),
    /** Shared auth token; nodes and clients must present it in their hello. */
    token: env.DSH_RELAY_TOKEN ?? "",
    /**
     * TLS: provide certPath/keyPath to speak wss://. Omit both for plain ws://
     * (LAN phase). For public deployment use a real CA cert (Let's Encrypt) —
     * HarmonyOS trusts the system store, not self-signed certs.
     */
    certPath: env.DSH_RELAY_CERT_PATH ?? "",
    keyPath: env.DSH_RELAY_KEY_PATH ?? "",
    /** Heartbeat timeout in ms. */
    heartbeatMs: intOf(env.DSH_RELAY_HEARTBEAT_MS, 60000),
    /** Node request timeout in ms. */
    requestTimeoutMs: intOf(env.DSH_RELAY_REQUEST_TIMEOUT_MS, 30000),
    /**
     * Pluggable notification channels for `turn.end`. Each entry is
     * { type: "webhook", url, headers? } — the relay POSTs the JSON event body.
     * Wire up ServerChan / WeCom bot / email bridge here; leave empty to disable.
     */
    notifiers: readNotifiers(env),
  };
}

function readNotifiers(env) {
  const raw = env.DSH_RELAY_NOTIFIERS ?? "";
  if (raw === "") return [];
  try {
    const parsed = JSON.parse(raw);
    return Array.isArray(parsed) ? parsed : [];
  } catch (error) {
    throw new Error(`DSH_RELAY_NOTIFIERS must be a JSON array: ${error.message}`);
  }
}

/** Load a PEM/TLS cert and key pair, or null when not configured. */
function loadTls(config) {
  if (!config.certPath || !config.keyPath) return null;
  return {
    cert: readFileSync(resolve(config.certPath)),
    key: readFileSync(resolve(config.keyPath)),
  };
}

export { loadConfig, loadTls, DEFAULT_PORT };

/**
 * Wire protocol constants and small helpers. Mirrors docs/protocol.md.
 */
import { randomUUID } from "node:crypto";

export const VERSION = 1;

export const FRAME_TYPES = Object.freeze({
  HELLO: "hello",
  WELCOME: "welcome",
  ERROR: "error",
  REQUEST: "request",
  RESPONSE: "response",
  EVENT: "event",
  PING: "ping",
  PONG: "pong",
});

export const ROLES = Object.freeze({
  NODE: "node",
  CLIENT: "client",
});

export const ERROR_CODES = Object.freeze({
  AUTH_FAILED: "AUTH_FAILED",
  NO_NODE: "NO_NODE",
  NODE_TIMEOUT: "NODE_TIMEOUT",
  BAD_REQUEST: "BAD_REQUEST",
  NOT_FOUND: "NOT_FOUND",
  INTERNAL: "INTERNAL",
});

/** Methods the relay answers itself instead of forwarding to a node. */
export const LOCAL_METHODS = Object.freeze({
  "node.list": true,
});

/** List methods the relay fans out to every online node, aggregating the
 *  results with a per-item `nodeId`/`nodeName`/`hostname` tag. */
export const AGGREGATE_METHODS = Object.freeze({
  "workspace.list": true,
  "session.list": true,
  "agent.list": true,
});

export function newId() {
  return randomUUID();
}

export function makeFrame(type, fields = {}) {
  return { v: VERSION, type, ...fields };
}

export function makeError(id, code, message, fields = {}) {
  return makeFrame(FRAME_TYPES.ERROR, { id, code, message, ...fields });
}

/** Serialize a frame for the wire; no-op on already-string values. */
export function encode(frame) {
  return typeof frame === "string" ? frame : JSON.stringify(frame);
}

/** Parse an inbound message into a frame object, or null when malformed. */
export function decode(raw) {
  try {
    const frame = JSON.parse(raw.toString());
    if (frame == null || typeof frame !== "object" || typeof frame.type !== "string") return null;
    return frame;
  } catch {
    return null;
  }
}

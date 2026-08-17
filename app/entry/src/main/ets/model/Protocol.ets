/**
 * Wire protocol data models shared by the monitor app (mirrors docs/protocol.md).
 * ArkTS note: all shapes are interfaces so JSON.parse results are asserted
 * with `as` instead of using `any`.
 */

/** Generic relay frame envelope. */
export interface RelayFrame {
  v: number;
  type: string;
  id?: string;
}

/** hello → welcome/error handshake frames. */
export interface HelloFrame extends RelayFrame {
  type: 'hello';
  role: 'node' | 'client';
  token: string;
  deviceName?: string;
  name?: string;
  hostname?: string;
  platform?: string;
  pid?: number;
  version?: string;
}

export interface WelcomeFrame extends RelayFrame {
  type: 'welcome';
  id: string;
  role: string;
}

export interface ErrorFrame extends RelayFrame {
  type: 'error';
  code: string;
  message: string;
}

/** client → relay → node request, and the node's response. */
export interface RequestFrame extends RelayFrame {
  type: 'request';
  method: string;
  params: object;
  nodeId?: string;
}

export interface ResponseFrame extends RelayFrame {
  type: 'response';
  ok: boolean;
  result?: object;
  error?: RelayError;
}

export interface RelayError {
  code: string;
  message: string;
}

/** node → relay → client event push. */
export interface EventFrame extends RelayFrame {
  type: 'event';
  event: string;
  sessionId?: string;
  data?: object;
}

/** Ping/pong heartbeat. */
export interface HeartbeatFrame extends RelayFrame {
  type: 'ping' | 'pong';
  t: number;
}

// ── domain payloads ──────────────────────────────────────────────────────

export interface WorkspaceInfo {
  id: string;
  path: string;
  title: string;
  sessionIds: string[];
  createdAt: string;
  updatedAt: string;
  nodeId?: string;
  nodeName?: string;
  hostname?: string;
}

export interface SessionInfo {
  id: string;
  createdAt: number;
  updatedAt?: number;
  running?: boolean;
  cwd: string;
  parentSession?: string;
  origin?: string;
  agentPreset?: string;
  live: boolean;
  title?: string | null;
  nodeId?: string;
  nodeName?: string;
  hostname?: string;
}

export interface AgentInfo {
  id: string;
  status: string;
  sessionId: string;
}

export interface DirEntryInfo {
  name: string;
  type: string;
  size?: number;
}

export interface SessionEventInfo {
  type: string; // 'user' | 'assistant'
  seq: number;
  time: number;
  text: string;
}

/** `turn.end` data — the completion trigger. */
export interface TurnEndData {
  turn: number;
  reason: TurnEndReason;
  nodeName?: string;
  hostname?: string;
}

export interface TurnEndReason {
  kind: string;
  reason?: object;
  error?: object;
}

// ── method params (ArkTS requires typed object literals) ──────────────────

export interface EmptyParams {
}

export interface SessionListParams {
  workspaceId?: string;
  cwd?: string;
}

export interface SessionHistoryParams {
  sessionId: string;
  fromSeq?: number;
}

export interface SessionCreateParams {
  cwd?: string;
  provider?: string;
  model?: string;
}

export interface SessionPromptParams {
  sessionId: string;
  text: string;
}

export interface FsListDirParams {
  path: string;
}

export interface FsReadTextParams {
  path: string;
}

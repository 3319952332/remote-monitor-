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
  /** true when the session is in-memory; false for cold/persisted sessions. */
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

/** `node.list` response entry — one online DSH node. */
export interface NodeInfo {
  id: string;
  name: string;
  hostname: string;
  platform?: string;
  connectedAt?: number;
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

/** One model a provider offers (from `model.list`). */
export interface ModelInfo {
  id: string;
  name: string;
  description?: string;
}

/** One provider route with its models (from `model.list`). */
export interface ProviderInfo {
  id: string;
  name: string;
  models: ModelInfo[];
}

/** The DSH default model selection (from `model.list`). */
export interface DefaultSelection {
  provider: string;
  model: string;
}

/** `model.list` response — providers + the DSH default selection. */
export interface ModelListResult {
  providers: ProviderInfo[];
  default?: DefaultSelection | null;
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
  /** Page size for the app-pull paginated session list. */
  limit?: number;
  /** Offset into the server's stable ordered snapshot. */
  offset?: number;
}

/** `session.list` response — one page of the ordered snapshot + hasMore. */
export interface SessionListResult {
  rows: SessionInfo[];
  hasMore: boolean;
}

export interface SessionHistoryParams {
  sessionId: string;
  fromSeq?: number;
}

export interface SessionTitleParams {
  sessionId: string;
}

/** Context/token usage of one session (from `session.usage`). */
export interface SessionUsage {
  contextWindow: number | null;
  pressureTokens: number | null;
  projectedTokens: number | null;
  surfaceTokens: number | null;
  sampledSurfaceTokens: number | null;
}

export interface SessionUsageResult {
  sessionId: string;
  usage: SessionUsage | null;
}

export interface SessionCompactParams {
  sessionId: string;
}

export interface SessionCompactResult {
  sessionId: string;
  compacted: boolean;
  compactionId: string | null;
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

// ── question / approval types ────────────────────────────────────────────

/** One option inside a question. */
export interface QuestionOption {
  label: string;
  description?: string;
}

/** One question in a `question/requested` batch. */
export interface AskUserQuestionItem {
  id: string;
  question: string;
  header?: string;
  detail?: string;
  options?: QuestionOption[];
  multiSelect?: boolean;
}

/** `question/requested` event data payload. */
export interface QuestionRequestedData {
  questions: AskUserQuestionItem[];
  rpcId?: string;
  callId?: string;
  seq?: number;
}

/** `question/resolved` event data payload. */
export interface QuestionResolvedData {
  questionRpcId: string;
  outcome: string; // 'answered' | 'cancelled'
}

/** `approval/requested` event data payload. */
export interface ApprovalRequestedData {
  approvalId: string;
  toolName: string;
  callId?: string;
  reason?: string;
}

/** `approval/resolved` event data payload. */
export interface ApprovalResolvedData {
  approvalId: string;
  outcome: string; // 'allowed-once' | 'rejected' | 'cancelled' | 'unavailable'
}

/** One answer for a single question. */
export interface QuestionAnswer {
  id: string;
  selected: string[];
  custom?: string;
}

/** `question.answer` method params. */
export interface QuestionAnswerParams {
  sessionId: string;
  questionRpcId: string;
  answers: QuestionAnswer[];
}

/** `question.answer` method result. */
export interface QuestionAnswerResult {
  answered: boolean;
  sessionId: string;
  questionRpcId: string;
}

/** `session.questions` method params. */
export interface SessionQuestionsParams {
  sessionId: string;
}

/** `session.questions` method result (server-side pending question state). */
export interface SessionQuestionsResult {
  sessionId: string;
  questions: AskUserQuestionItem[];
  rpcId: string | null;
}

// ── model selection on existing session ───────────────────────────────────

/** `session.selectModel` method params. */
export interface SessionSelectModelParams {
  sessionId: string;
  provider: string;
  model: string;
  reasoningEffort?: string;
}

/** `session.selectModel` method result. */
export interface SessionSelectModelResult {
  selected: DefaultSelection;
}

// ── permission switching on existing session ──────────────────────────────

/** `session.permission` method params. */
export interface SessionPermissionParams {
  sessionId: string;
  preset: string;
}

/** `session.permission` method result. */
export interface SessionPermissionResult {
  sessionId: string;
  switched: boolean;
  preset: string;
}

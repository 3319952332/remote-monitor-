/**
 * Session detail page: transcript + send a follow-up message + question
 * answering + model switching + permission switching.
 * Receives `sessionId` via router params.
 */
import { router, promptAction } from '@kit.ArkUI';
import { pasteboard } from '@kit.BasicServicesKit';
import { relay } from '../services/RelayInstance';
import {
  SessionEventInfo,
  SessionHistoryParams,
  SessionPromptParams,
  SessionUsage,
  SessionUsageResult,
  SessionCompactParams,
  AskUserQuestionItem,
  QuestionOption,
  QuestionRequestedData,
  QuestionResolvedData,
  QuestionAnswer,
  QuestionAnswerParams,
  QuestionAnswerResult,
  SessionQuestionsParams,
  SessionQuestionsResult,
  ProviderInfo,
  ModelInfo,
  ModelListResult,
  DefaultSelection,
  SessionSelectModelParams,
  SessionSelectModelResult,
  SessionPermissionParams,
  SessionPermissionResult,
  EmptyParams,
} from '../model/Protocol';
import { MarkdownView } from '../components/MarkdownView';

interface PickOption {
  value: string;
}

/** One question's draft answer state. */
interface QuestionDraft {
  selected: string[];
  custom: string;
}

@Entry
@Component
struct SessionDetail {
  @State sessionId: string = '';
  @State events: SessionEventInfo[] = [];
  @State inputText: string = '';
  @State sending: boolean = false;
  @State loading: boolean = false;
  @State loadError: string = '';
  @State truncated: boolean = false;
  @State running: boolean = false;
  @State nodeId: string = '';
  @State retryCount: number = 0;
  @State usage: SessionUsage | null = null;
  @State compacting: boolean = false;
  @State compactReason: string = ''; // 'auto' | 'manual'

  // ── question state ─────────────────────────────────────────────────────
  @State questions: AskUserQuestionItem[] = [];
  @State questionRpcId: string = '';
  @State showQuestionCard: boolean = false;
  @State questionIndex: number = 0;
  @State questionDrafts: QuestionDraft[] = [];
  @State questionSubmitting: boolean = false;
  @State questionError: string = '';

  // ── model selection state ───────────────────────────────────────────────
  @State providers: ProviderInfo[] = [];
  @State providerIdx: number = -1;
  @State modelIdx: number = -1;
  @State currentProvider: string = '';
  @State currentModel: string = '';
  @State showModelPicker: boolean = false;
  @State loadingModels: boolean = false;
  @State switchingModel: boolean = false;

  // ── permission state ────────────────────────────────────────────────────
  @State showPermissionPicker: boolean = false;
  @State currentPreset: string = '';
  @State switchingPermission: boolean = false;
  private readonly PERMISSION_PRESETS: string[] = [
    'workspace-write',
    'danger-full-access',
  ];

  private pollTimer: number = -1;
  private scroller: Scroller = new Scroller();
  private eventCb: (event: string, sessionId: string, data: object) => void = () => {};

  aboutToAppear(): void {
    const params = router.getParams() as Record<string, Object>;
    this.sessionId = (params['sessionId'] ?? '') as string;
    this.nodeId = (params['nodeId'] ?? '') as string;
    this.eventCb = (event: string, sessionId: string, data: object) => {
      this.handleEvent(event, sessionId, data);
    };
    relay.addEventListener(this.eventCb);
    this.loadHistory();
    this.loadUsage();
    this.loadModels();
    // Read current model from the session (best-effort — the session may
    // not have a durable selection yet, in which case the picker shows
    // the default).
    this.loadCurrentModel();
    // Recover any pending question from server-side state (covers the case
    // where the question fired while the app was closed or on another page).
    this.loadPendingQuestion();
  }

  aboutToDisappear(): void {
    this.stopPolling();
    relay.removeEventListener(this.eventCb);
  }

  /** Handle all events: auto-compact, question/requested, question/resolved,
   *  turn/end, and session/event (for live transcript updates). */
  handleEvent(event: string, sessionId: string, data: object): void {
    if (sessionId !== this.sessionId) {
      return;
    }
    if (event === 'session.autocompact') {
      this.handleCompact(data);
      return;
    }
    if (event === 'question/requested') {
      this.handleQuestionRequested(data);
      // A question node means the AI is mid-turn — refresh context usage too.
      this.loadUsage();
      return;
    }
    if (event === 'question/resolved') {
      this.handleQuestionResolved(data);
      return;
    }
    if (event === 'turn.end') {
      this.loadHistory();
      this.loadUsage();
      return;
    }
    if (event === 'session.event') {
      // Refresh history when new events arrive while running.
      if (this.running) {
        this.fetchHistory();
        this.loadUsage();
      }
    }
  }

  /** Compaction progress pushed by the plugin (session.autocompact). Drives
   *  both the auto-compact trigger and the manual 压缩 button — the plugin
   *  fires the compaction in the background and reports through this event
   *  stream, so the UI never blocks on a slow summary LLM. */
  handleCompact(data: object): void {
    const d = data as Record<string, Object>;
    const status: string = (d['status'] ?? '') as string;
    const reason: string = (d['reason'] ?? 'auto') as string;
    if (status === 'start') {
      this.compacting = true;
      this.compactReason = reason;
      promptAction.showToast({ message: reason === 'manual' ? '开始压缩…' : '上下文达到阈值，开始自动压缩…' });
    } else if (status === 'done') {
      this.compacting = false;
      this.compactReason = '';
      this.loadUsage();
      this.loadHistory();
      const percentAfter = d['percentAfter'];
      const msg = typeof percentAfter === 'number'
        ? `压缩完成，占用 ${Math.round(percentAfter * 100)}%`
        : '压缩完成';
      promptAction.showToast({ message: msg });
    } else if (status === 'error') {
      this.compacting = false;
      this.compactReason = '';
      promptAction.showToast({ message: `压缩失败：${(d['message'] ?? '未知错误') as string}` });
    }
  }

  /** When a question batch arrives, show the question card. */
  handleQuestionRequested(data: object): void {
    const d = data as QuestionRequestedData;
    if (!d.questions || d.questions.length === 0) {
      return;
    }
    this.questions = d.questions;
    // Use the rpcId from the relay plugin's provider (when available) so the
    // app can answer directly. When the api-proxy owns the provider, the rpcId
    // is absent and the user must answer through the Web GUI.
    this.questionRpcId = d.rpcId ?? '';
    this.questionIndex = 0;
    this.questionDrafts = d.questions.map((): QuestionDraft => ({ selected: [], custom: '' }));
    this.questionError = '';
    this.questionSubmitting = false;
    this.showQuestionCard = true;
  }

  /** When a question is resolved (answered or cancelled), hide the card. */
  handleQuestionResolved(data: object): void {
    const d = data as QuestionResolvedData;
    this.showQuestionCard = false;
    this.questions = [];
    this.questionRpcId = '';
    if (d.outcome === 'answered') {
      promptAction.showToast({ message: '已答复' });
    }
  }

  /** Query the node's server-side pending-question state and, if one exists,
   *  show the question card. Called on page open so a question that fired
   *  while the app was offline is still surfaced. */
  async loadPendingQuestion(): Promise<void> {
    if (this.sessionId.length === 0) {
      return;
    }
    const resp = await relay.request('session.questions', { sessionId: this.sessionId } as SessionQuestionsParams, this.nodeId.length > 0 ? this.nodeId : undefined);
    if (!resp.ok || !resp.result) {
      return;
    }
    const r = resp.result as SessionQuestionsResult;
    if (!r.questions || r.questions.length === 0) {
      return;
    }
    this.questions = r.questions;
    this.questionRpcId = r.rpcId ?? '';
    this.questionIndex = 0;
    this.questionDrafts = r.questions.map((): QuestionDraft => ({ selected: [], custom: '' }));
    this.questionError = '';
    this.questionSubmitting = false;
    this.showQuestionCard = true;
  }

  // ── question UI helpers ─────────────────────────────────────────────────

  currentQuestion(): AskUserQuestionItem | null {
    if (this.questions.length === 0) {
      return null;
    }
    return this.questions[this.questionIndex];
  }

  currentDraft(): QuestionDraft {
    if (this.questionIndex < 0 || this.questionIndex >= this.questionDrafts.length) {
      const empty: QuestionDraft = { selected: [], custom: '' };
      return empty;
    }
    return this.questionDrafts[this.questionIndex];
  }

  isAnswered(draft: QuestionDraft): boolean {
    return draft.selected.length > 0 || draft.custom.trim().length > 0;
  }

  /** Current question's header text ('' when absent). */
  questionHeader(): string {
    const q = this.currentQuestion();
    return q && q.header ? q.header : '';
  }

  /** Current question's title text. */
  questionTitle(): string {
    const q = this.currentQuestion();
    return q ? q.question : '';
  }

  /** Current question's detail text ('' when absent). */
  questionDetail(): string {
    const q = this.currentQuestion();
    return q && q.detail ? q.detail : '';
  }

  /** Current question's options ([] when absent). */
  questionOptions(): QuestionOption[] {
    const q = this.currentQuestion();
    return q && q.options ? q.options : [];
  }

  /** Whether the current question has any options. */
  hasQuestionOptions(): boolean {
    return this.questionOptions().length > 0;
  }

  /** Whether one option label is currently selected. */
  isOptionSelected(label: string): boolean {
    const draft = this.currentDraft();
    return draft.selected.indexOf(label) >= 0;
  }

  @Builder
  questionOption(opt: QuestionOption, idx: number) {
    Row() {
      Text(`${idx + 1}. ${opt.label}`)
        .fontSize(14)
        .fontColor(this.isOptionSelected(opt.label) ? '#007dff' : '#333')
        .fontWeight(this.isOptionSelected(opt.label) ? FontWeight.Medium : FontWeight.Normal)
        .layoutWeight(1)
      if (opt.description) {
        Text(opt.description)
          .fontSize(11)
          .fontColor('#999')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
    }
    .width('100%')
    .padding({ top: 10, bottom: 10 })
    .border({ width: this.isOptionSelected(opt.label) ? 1 : 0, color: '#007dff' })
    .borderRadius(8)
    .backgroundColor(this.isOptionSelected(opt.label) ? '#e6f2ff' : '#f7f8fa')
    .margin({ bottom: 6 })
    .onClick(() => { this.chooseOption(opt.label); })
  }

  chooseOption(label: string): void {
    const q = this.currentQuestion();
    if (!q) {
      return;
    }
    const drafts = this.questionDrafts.slice();
    const draft = drafts[this.questionIndex];
    if (q.multiSelect === true) {
      const idx = draft.selected.indexOf(label);
      if (idx >= 0) {
        draft.selected = draft.selected.filter((x: string) => x !== label);
      } else {
        draft.selected = [...draft.selected, label];
      }
    } else {
      draft.selected = [label];
      draft.custom = '';
    }
    this.questionDrafts = drafts;
    this.questionError = '';
    // Auto-advance single-select when there are more questions.
    if (q.multiSelect !== true && this.questionIndex < this.questions.length - 1) {
      this.questionIndex++;
    }
  }

  questionPrev(): void {
    if (this.questionIndex > 0) {
      this.questionIndex--;
      this.questionError = '';
    }
  }

  questionNext(): void {
    const draft = this.currentDraft();
    if (!this.isAnswered(draft)) {
      this.questionError = '请选择一个选项或填写自定义答案';
      return;
    }
    if (this.questionIndex < this.questions.length - 1) {
      this.questionIndex++;
      this.questionError = '';
    }
  }

  async submitAnswers(): Promise<void> {
    // When the relay plugin is not the question provider (api-proxy owns it),
    // the app cannot answer directly — the user must use the Web GUI.
    if (this.questionRpcId.length === 0) {
      promptAction.showToast({ message: '请在电脑端的 DSH Web GUI 中答复此问题' });
      return;
    }
    const missing = this.questionDrafts.findIndex((d) => !this.isAnswered(d));
    if (missing >= 0) {
      this.questionIndex = missing;
      this.questionError = '请先完成这道问题';
      return;
    }
    const answers: QuestionAnswer[] = this.questions.map((q, idx) => {
      const d = this.questionDrafts[idx];
      const custom = d.custom.trim();
      const ans: QuestionAnswer = {
        id: q.id,
        selected: custom.length > 0 && q.multiSelect !== true ? [] : d.selected,
      };
      if (custom.length > 0) {
        ans.custom = custom;
      }
      return ans;
    });
    this.questionSubmitting = true;
    this.questionError = '';
    const params: QuestionAnswerParams = {
      sessionId: this.sessionId,
      questionRpcId: this.questionRpcId,
      answers: answers,
    };
    const resp = await relay.request('question.answer', params, this.nodeId.length > 0 ? this.nodeId : undefined);
    this.questionSubmitting = false;
    if (resp.ok) {
      this.showQuestionCard = false;
      this.questions = [];
      this.questionRpcId = '';
      promptAction.showToast({ message: '已答复' });
    } else {
      this.questionError = resp.error?.message ?? '答复失败';
    }
  }

  skipQuestion(): void {
    const drafts = this.questionDrafts.slice();
    const emptyDraft: QuestionDraft = { selected: [], custom: '' };
    drafts[this.questionIndex] = emptyDraft;
    this.questionDrafts = drafts;
    this.questionError = '';
    if (this.questionIndex < this.questions.length - 1) {
      this.questionIndex++;
    } else {
      this.submitAnswers();
    }
  }

  // ── model selection ────────────────────────────────────────────────────

  async loadModels(): Promise<void> {
    this.loadingModels = true;
    const resp = await relay.request('model.list', {} as EmptyParams, this.nodeId.length > 0 ? this.nodeId : undefined);
    this.loadingModels = false;
    if (!resp.ok || !resp.result) {
      return;
    }
    const r = resp.result as ModelListResult;
    this.providers = r.providers ?? [];
    // Preselect the default.
    const d = r.default;
    if (d && d.provider && d.model) {
      for (let i = 0; i < this.providers.length; i++) {
        if (this.providers[i].id === d.provider) {
          this.providerIdx = i;
          const models = this.providers[i].models;
          for (let j = 0; j < models.length; j++) {
            if (models[j].id === d.model) {
              this.modelIdx = j;
              break;
            }
          }
          break;
        }
      }
    }
  }

  /** Read the session's current model selection from the live session info
   *  (best-effort — the session header may not carry it). */
  async loadCurrentModel(): Promise<void> {
    // The current model is read from the model list default; the session's
    // own selection is not exposed through the relay protocol yet.  When the
    // user switches, we track it locally.
  }

  providerOptions(): PickOption[] {
    return this.providers.map((p: ProviderInfo) => ({ value: p.name || p.id } as PickOption));
  }

  modelOptions(): PickOption[] {
    if (this.providerIdx < 0 || this.providerIdx >= this.providers.length) {
      return [];
    }
    return this.providers[this.providerIdx].models.map((m: ModelInfo) => ({ value: m.name || m.id } as PickOption));
  }

  selectedProviderId(): string {
    if (this.providerIdx >= 0 && this.providerIdx < this.providers.length) {
      return this.providers[this.providerIdx].id;
    }
    return '';
  }

  selectedModelId(): string {
    if (this.providerIdx >= 0 && this.providerIdx < this.providers.length) {
      const models = this.providers[this.providerIdx].models;
      if (this.modelIdx >= 0 && this.modelIdx < models.length) {
        return models[this.modelIdx].id;
      }
    }
    return '';
  }

  modelDisplayLabel(): string {
    const cp = this.currentProvider ?? '';
    const cm = this.currentModel ?? '';
    if (cp.length > 0 && cm.length > 0) {
      return `${cp}/${cm}`;
    }
    if (this.providerIdx >= 0 && this.providerIdx < this.providers.length) {
      const p = this.providers[this.providerIdx];
      if (this.modelIdx >= 0 && this.modelIdx < p.models.length) {
        return `${p.name || p.id} / ${p.models[this.modelIdx].name || p.models[this.modelIdx].id}`;
      }
    }
    return '选择模型';
  }

  /** Short label for the header model button (last segment, truncated). */
  modelButtonLabel(): string {
    const full = this.modelDisplayLabel();
    if (full === '选择模型') {
      return '模型';
    }
    const idx = full.lastIndexOf('/');
    const name = idx >= 0 ? full.slice(idx + 1).trim() : full;
    return name.length > 10 ? name.slice(0, 10) + '…' : name;
  }

  /** Short label for the header permission button. */
  presetButtonLabel(): string {
    if (this.currentPreset === 'danger-full-access') {
      return '完全访问';
    }
    if (this.currentPreset === 'workspace-write') {
      return '工作区写';
    }
    if (this.currentPreset.length > 0) {
      return this.currentPreset;
    }
    return '权限';
  }

  async switchModel(): Promise<void> {
    const provider = this.selectedProviderId();
    const model = this.selectedModelId();
    if (provider.length === 0 || model.length === 0) {
      promptAction.showToast({ message: '请选择 Provider 和 Model' });
      return;
    }
    this.switchingModel = true;
    const params: SessionSelectModelParams = {
      sessionId: this.sessionId,
      provider: provider,
      model: model,
    };
    const resp = await relay.request('session.selectModel', params, this.nodeId.length > 0 ? this.nodeId : undefined);
    this.switchingModel = false;
    if (resp.ok) {
      const r = resp.result as SessionSelectModelResult;
      const sel = r?.selected;
      // Defensive: only accept a well-formed selected model. A malformed
      // response must never crash the page (undefined provider/model would
      // blow up .length in the label helpers).
      if (sel && typeof sel.provider === 'string' && sel.provider.length > 0 &&
        typeof sel.model === 'string' && sel.model.length > 0) {
        this.currentProvider = sel.provider;
        this.currentModel = sel.model;
        this.showModelPicker = false;
        promptAction.showToast({ message: `已切换至 ${provider}/${model}` });
        // Context window/usage can shift with the model — refresh the bar.
        this.loadUsage();
      } else {
        promptAction.showToast({ message: '切换结果异常，请重试' });
      }
    } else {
      promptAction.showToast({ message: resp.error?.message ?? '切换失败' });
    }
  }

  // ── permission switching ───────────────────────────────────────────────

  async switchPermission(preset: string): Promise<void> {
    this.switchingPermission = true;
    const params: SessionPermissionParams = {
      sessionId: this.sessionId,
      preset: preset,
    };
    const resp = await relay.request('session.permission', params, this.nodeId.length > 0 ? this.nodeId : undefined);
    this.switchingPermission = false;
    if (resp.ok) {
      const r = resp.result as SessionPermissionResult;
      this.currentPreset = preset;
      this.showPermissionPicker = false;
      promptAction.showToast({ message: `已切换至 ${preset}` });
    } else {
      promptAction.showToast({ message: resp.error?.message ?? '切换失败' });
    }
  }

  // ── legacy methods ──────────────────────────────────────────────────────

  /** Fetch the session's context/token usage and refresh it while polling. */
  async loadUsage(): Promise<void> {
    const resp = await relay.request('session.usage', { sessionId: this.sessionId } as SessionCompactParams, this.nodeId.length > 0 ? this.nodeId : undefined);
    if (!resp.ok || !resp.result) {
      return;
    }
    const r = resp.result as SessionUsageResult;
    this.usage = r.usage;
  }

  /** Trigger a manual compaction (like DSH `/compact`). Fire-and-forget: the
   *  plugin acknowledges immediately and reports progress through
   *  `session.autocompact` events (see handleCompact), so the button never
   *  blocks on a summary LLM that could outlive the request timeout. */
  async compact(): Promise<void> {
    if (this.compacting || this.running) {
      promptAction.showToast({ message: this.compacting ? '压缩中，请稍候' : 'AI 回复中，暂不可压缩' });
      return;
    }
    this.compacting = true;
    this.compactReason = 'manual';
    const resp = await relay.request('session.compact', { sessionId: this.sessionId } as SessionCompactParams, this.nodeId.length > 0 ? this.nodeId : undefined);
    if (!resp.ok) {
      // Request never reached a node — no progress event will arrive, so
      // clear the busy state here.
      this.compacting = false;
      this.compactReason = '';
      promptAction.showToast({ message: resp.error?.message ?? '压缩请求失败' });
    }
  }

  /** Numerator tokens for the usage bar — prefers the web's `projectedTokens`
   *  but guards against the post-compaction artifact where the projection
   *  reports projectedTokens = 0 while the session still has content: fall back
   *  to the surface estimate so the bar never misleadingly reads "0%". A truly
   *  empty/unknown session returns null and the bar is hidden. */
  usedTokens(): number | null {
    const u = this.usage;
    if (!u) {
      return null;
    }
    if (typeof u.projectedTokens === 'number' && u.projectedTokens > 0) {
      return u.projectedTokens;
    }
    if (typeof u.surfaceTokens === 'number' && u.surfaceTokens > 0) {
      return u.surfaceTokens;
    }
    if (typeof u.pressureTokens === 'number' && u.pressureTokens > 0) {
      return u.pressureTokens;
    }
    return null;
  }

  /** Percent of the context window used, or -1 when unknown. */
  usagePercent(): number {
    const u = this.usage;
    if (!u || u.contextWindow === null) {
      return -1;
    }
    const win = u.contextWindow;
    if (win <= 0) {
      return -1;
    }
    const used = this.usedTokens();
    if (used === null) {
      return -1;
    }
    return Math.min(100, Math.round((used / win) * 100));
  }

  /** Human string for the usage bar, e.g. "12.3k / 128k (10%)". */
  usageText(): string {
    const u = this.usage;
    if (!u) {
      return '';
    }
    const win = u.contextWindow;
    const used = this.usedTokens();
    if (win === null || used === null) {
      return '';
    }
    const fmt = (n: number): string => (n >= 1000 ? `${(n / 1000).toFixed(1)}k` : `${n}`);
    return `${fmt(used)} / ${fmt(win)} (${this.usagePercent()}%)`;
  }

  async loadHistory(): Promise<void> {
    this.loading = true;
    this.loadError = '';
    this.retryCount = 0;
    await this.fetchHistory();
    this.loading = false;
    // 主动加载（进入页面 / 刷新 / 发送后）滚到底
    this.scrollToBottom();
  }

  /** Pull history + running state; drives the polling loop while the AI replies. */
  async fetchHistory(): Promise<void> {
    const resp = await relay.request('session.history', { sessionId: this.sessionId, fromSeq: 0 } as SessionHistoryParams, this.nodeId.length > 0 ? this.nodeId : undefined);
    if (!resp.ok) {
      const errCode: string = (resp.error?.code ?? '') as string;
      const errMsg: string = resp.error?.message ?? '加载失败';
      // Retry once when the error looks transient (node disconnected / timeout).
      if (this.retryCount < 1 && (errCode === 'NO_NODE' || errCode === 'NODE_TIMEOUT' || errCode === 'DISCONNECTED')) {
        this.retryCount++;
        // Brief pause to let the node reconnect, then retry without nodeId
        // so the relay picks whichever node is online.
        await new Promise<void>((resolve) => setTimeout(resolve, 1500));
        const retryResp = await relay.request('session.history', { sessionId: this.sessionId, fromSeq: 0 } as SessionHistoryParams);
        if (retryResp.ok) {
          const r = retryResp.result as Record<string, Object>;
          this.events = (r['events'] ?? []) as SessionEventInfo[];
          this.truncated = (r['truncated'] ?? false) as boolean;
          this.running = (r['running'] ?? false) as boolean;
          if (this.running) {
            this.startPolling();
          }
          return;
        }
        this.loadError = retryResp.error?.message ?? '重试后仍加载失败';
      } else {
        this.loadError = errMsg;
      }
      this.stopPolling();
      return;
    }
    const r = resp.result as Record<string, Object>;
    const prevRunning = this.running;
    this.events = (r['events'] ?? []) as SessionEventInfo[];
    this.truncated = (r['truncated'] ?? false) as boolean;
    this.running = (r['running'] ?? false) as boolean;
    if (this.running) {
      this.startPolling();
    } else {
      this.stopPolling();
      // 仅当回复刚完成（running 由 true 变 false）时滚到底，显示最终结果
      if (prevRunning) {
        this.scrollToBottom();
      }
    }
  }

  startPolling(): void {
    if (this.pollTimer !== -1) {
      return;
    }
    this.pollTimer = setInterval(() => {
      this.fetchHistory();
      this.loadUsage();
    }, 2500);
  }

  stopPolling(): void {
    if (this.pollTimer !== -1) {
      clearInterval(this.pollTimer);
      this.pollTimer = -1;
    }
  }

  scrollToBottom(): void {
    setTimeout(() => {
      this.scroller.scrollEdge(Edge.Bottom);
    }, 60);
  }

  copyText(text: string): void {
    try {
      const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
      pasteboard.getSystemPasteboard().setData(data);
      promptAction.showToast({ message: '已复制' });
    } catch (e) {
      promptAction.showToast({ message: '复制失败' });
    }
  }

  async send(): Promise<void> {
    const text = this.inputText.trim();
    if (text.length === 0) {
      promptAction.showToast({ message: '请输入内容' });
      return;
    }
    if (this.compacting) {
      promptAction.showToast({ message: '正在压缩，请稍候' });
      return;
    }
    this.sending = true;
    let resp = await relay.request('session.prompt', { sessionId: this.sessionId, text: text } as SessionPromptParams, this.nodeId.length > 0 ? this.nodeId : undefined);
    // Retry without nodeId when the pinned node is gone (e.g. after plugin hot-reload).
    if (!resp.ok) {
      const errCode: string = (resp.error?.code ?? '') as string;
      if (errCode === 'NO_NODE' || errCode === 'NODE_TIMEOUT' || errCode === 'DISCONNECTED') {
        await new Promise<void>((resolve) => setTimeout(resolve, 1500));
        resp = await relay.request('session.prompt', { sessionId: this.sessionId, text: text } as SessionPromptParams);
      }
    }
    this.sending = false;
    if (resp.ok) {
      this.inputText = '';
      promptAction.showToast({ message: '已发送' });
      this.loadHistory();
    } else {
      promptAction.showToast({ message: resp.error?.message ?? '发送失败' });
    }
  }

  build(): void {
    Column() {
      // ── header ──────────────────────────────────────────────────────────
      Row() {
        Button('返回')
          .fontSize(13)
          .height(32)
          .backgroundColor('#f0f0f0')
          .fontColor('#333')
          .onClick(() => router.back())
        Text(`会话 ${this.sessionId.slice(-8)}`)
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .margin({ left: 12 })
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 10 })

      // action row: model / permission / compact / refresh
      Row({ space: 8 }) {
        Button(this.modelButtonLabel())
          .fontSize(11)
          .height(30)
          .layoutWeight(1)
          .backgroundColor('#f0f0f0')
          .fontColor('#333')
          .onClick(() => { this.showModelPicker = !this.showModelPicker; })
        Button(this.presetButtonLabel())
          .fontSize(11)
          .height(30)
          .layoutWeight(1)
          .backgroundColor('#f0f0f0')
          .fontColor('#333')
          .onClick(() => { this.showPermissionPicker = !this.showPermissionPicker; })
        Button(this.compacting ? '压缩中' : '压缩')
          .fontSize(11)
          .height(30)
          .layoutWeight(1)
          .backgroundColor('#ff9500')
          .fontColor(Color.White)
          .enabled(!this.compacting)
          .onClick(() => this.compact())
        Button('刷新')
          .fontSize(11)
          .height(30)
          .layoutWeight(1)
          .backgroundColor('#007dff')
          .fontColor(Color.White)
          .onClick(() => {
            this.loadHistory();
            this.loadUsage();
          })
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 2, bottom: 10 })

      // ── model picker dropdown ───────────────────────────────────────────
      if (this.showModelPicker) {
        Column() {
          Text('选择模型')
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .width('100%')
            .padding({ left: 16, bottom: 6 })
          if (this.loadingModels) {
            Row() {
              LoadingProgress().width(16).height(16)
              Text(' 加载中...').fontSize(12).fontColor('#999')
            }
            .padding({ left: 16 })
          } else if (this.providers.length === 0) {
            Text('无可用模型').fontSize(12).fontColor('#999').padding({ left: 16 })
          } else {
            Row() {
              Column() {
                Text('Provider').fontSize(11).fontColor('#999')
                Select(this.providerOptions())
                  .selected(this.providerIdx >= 0 ? this.providerIdx : 0)
                  .value(this.providerIdx >= 0 ? (this.providers[this.providerIdx].name || this.providers[this.providerIdx].id) : '请选择')
                  .onSelect((index: number) => {
                    this.providerIdx = index;
                    this.modelIdx = -1;
                  })
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)
              Column() {
                Text('Model').fontSize(11).fontColor('#999')
                Select(this.modelOptions())
                  .selected(this.modelIdx >= 0 ? this.modelIdx : 0)
                  .value(this.modelIdx >= 0 ? this.modelDisplayValue() : '请选择')
                  .enabled(this.modelOptions().length > 0)
                  .onSelect((index: number) => { this.modelIdx = index; })
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)
              .margin({ left: 8 })
            }
            .width('100%')
            .padding({ left: 16, right: 16 })
            Button(this.switchingModel ? '切换中...' : '确认切换')
              .fontSize(12)
              .height(32)
              .backgroundColor('#007dff')
              .fontColor(Color.White)
              .margin({ top: 8, bottom: 8 })
              .enabled(!this.switchingModel)
              .onClick(() => this.switchModel())
          }
        }
        .width('100%')
        .padding({ top: 8, bottom: 8 })
        .backgroundColor('#fafafa')
        .border({ width: { bottom: 1 }, color: '#e8e8e8' })
      }

      // ── permission picker dropdown ──────────────────────────────────────
      if (this.showPermissionPicker) {
        Column() {
          Text('切换权限模式')
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .width('100%')
            .padding({ left: 16, bottom: 6 })
          ForEach(this.PERMISSION_PRESETS, (preset: string) => {
            Row() {
              Text(preset)
                .fontSize(13)
                .fontColor(this.currentPreset === preset ? '#007dff' : '#333')
                .fontWeight(this.currentPreset === preset ? FontWeight.Medium : FontWeight.Normal)
              Blank()
              if (this.currentPreset === preset) {
                Text('✓').fontSize(13).fontColor('#007dff')
              }
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 10, bottom: 10 })
            .onClick(() => this.switchPermission(preset))
          }, (preset: string) => preset)
        }
        .width('100%')
        .padding({ top: 8, bottom: 8 })
        .backgroundColor('#fafafa')
        .border({ width: { bottom: 1 }, color: '#e8e8e8' })
      }

      // ── question card ───────────────────────────────────────────────────
      if (this.showQuestionCard && this.questions.length > 0) {
        Column() {
          Row() {
            Text('⚠ AI 需要你的确认')
              .fontSize(13)
              .fontWeight(FontWeight.Medium)
              .fontColor('#ff9500')
            Blank()
            Button('✕')
              .fontSize(12)
              .height(24)
              .width(24)
              .backgroundColor('#f0f0f0')
              .fontColor('#999')
              .onClick(() => { this.showQuestionCard = false; })
          }
          .width('100%')
          .padding({ left: 12, right: 12, top: 8, bottom: 4 })

          // Question body
          Column() {
            if (this.questionHeader().length > 0) {
              Text(this.questionHeader())
                .fontSize(11)
                .fontColor('#999')
                .margin({ bottom: 4 })
            }
            Text(this.questionTitle())
              .fontSize(15)
              .fontWeight(FontWeight.Medium)
              .margin({ bottom: 6 })
            if (this.questionDetail().length > 0) {
              Text(this.questionDetail())
                .fontSize(13)
                .fontColor('#666')
                .maxLines(6)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .margin({ bottom: 8 })
            }
            // Options
            if (this.hasQuestionOptions()) {
              Column() {
                ForEach(this.questionOptions(), (opt: QuestionOption, idx: number) => {
                  this.questionOption(opt, idx)
                }, (opt: QuestionOption, idx: number) => `${opt.label}-${idx}`)
              }
              .width('100%')
            }
            // Custom input
            TextInput({ placeholder: '输入自定义答案...' })
              .width('100%')
              .height(40)
              .margin({ top: 6, bottom: 6 })
              .onChange((v: string) => {
                const drafts = this.questionDrafts.slice();
                const emptyDraft: QuestionDraft = { selected: [], custom: v };
                drafts[this.questionIndex] = emptyDraft;
                this.questionDrafts = drafts;
                this.questionError = '';
              })
          }
          .width('100%')
          .padding({ left: 12, right: 12 })

          // Error
          if (this.questionError.length > 0) {
            Text(this.questionError)
              .fontSize(12)
              .fontColor('#ff3b30')
              .width('100%')
              .padding({ left: 12, top: 4 })
          }

          // Footer
          Row() {
            Text(`${this.questionIndex + 1} / ${this.questions.length}`)
              .fontSize(12)
              .fontColor('#999')
            Blank()
            Button('跳过')
              .fontSize(12)
              .height(30)
              .backgroundColor('#f0f0f0')
              .fontColor('#666')
              .enabled(!this.questionSubmitting)
              .onClick(() => this.skipQuestion())
            if (this.questionIndex < this.questions.length - 1) {
              Button('下一题')
                .fontSize(12)
                .height(30)
                .backgroundColor('#007dff')
                .fontColor(Color.White)
                .margin({ left: 8 })
                .enabled(!this.questionSubmitting)
                .onClick(() => this.questionNext())
            } else {
              Button(this.questionSubmitting ? '提交中...' : '提交')
                .fontSize(12)
                .height(30)
                .backgroundColor('#007dff')
                .fontColor(Color.White)
                .margin({ left: 8 })
                .enabled(!this.questionSubmitting)
                .onClick(() => this.submitAnswers())
            }
          }
          .width('100%')
          .padding({ left: 12, right: 12, top: 8, bottom: 8 })
        }
        .width('100%')
        .backgroundColor('#fff8e6')
        .border({ width: { bottom: 1 }, color: '#ffd666' })
      }

      // ── context usage bar ───────────────────────────────────────────────
      if (this.usage !== null && this.usagePercent() >= 0) {
        Row() {
          Text(this.usageText())
            .fontSize(11)
            .fontColor('#666')
          Blank()
          Text(`${this.usagePercent()}%`)
            .fontSize(11)
            .fontColor(this.usagePercent() > 85 ? '#ff3b30' : '#666')
        }
        .width('100%')
        .padding({ left: 16, right: 16, bottom: 4 })

        Progress({ value: this.usagePercent(), total: 100 })
          .width('92%')
          .height(4)
          .color(this.usagePercent() > 85 ? '#ff3b30' : '#007dff')
          .backgroundColor('#e8e8e8')
          .margin({ left: 16, right: 16, bottom: 4 })
      }

      // ── transcript ──────────────────────────────────────────────────────
      if (this.loading) {
        Column() {
          LoadingProgress()
            .width(36)
            .height(36)
          Text('加载中...')
            .fontSize(13)
            .fontColor('#999')
            .margin({ top: 8 })
        }
        .layoutWeight(1)
        .width('100%')
        .justifyContent(FlexAlign.Center)
      } else if (this.loadError.length > 0) {
        Column() {
          Text(this.loadError)
            .fontSize(14)
            .fontColor('#ff3b30')
            .margin({ bottom: 12 })
          Button('重试')
            .fontSize(13)
            .height(36)
            .backgroundColor('#007dff')
            .fontColor(Color.White)
            .onClick(() => this.loadHistory())
        }
        .layoutWeight(1)
        .width('100%')
        .justifyContent(FlexAlign.Center)
      } else {
        Column() {
          if (this.truncated) {
            Text('内容过长，仅显示最近的消息')
              .fontSize(11)
              .fontColor('#999')
              .width('100%')
              .padding({ left: 8, bottom: 4 })
          }
          List({ scroller: this.scroller }) {
            ForEach(this.events, (e: SessionEventInfo) => {
              ListItem() {
                if (e.type === 'user') {
                  Row() {
                    Blank()
                    Column() {
                      Text(e.text)
                        .fontSize(14)
                        .fontColor(Color.White)
                        .wordBreak(WordBreak.BREAK_ALL)
                        .textAlign(TextAlign.Start)
                        .copyOption(CopyOptions.LocalDevice)
                        .padding({ left: 12, right: 12, top: 8, bottom: 8 })
                        .borderRadius(10)
                        .backgroundColor('#007dff')
                      Text('📋')
                        .fontSize(12)
                        .padding({ top: 4, right: 8 })
                        .onClick(() => { this.copyText(e.text); })
                    }
                    .constraintSize({ maxWidth: '82%' })
                    .alignItems(HorizontalAlign.End)
                  }
                  .width('100%')
                  .justifyContent(FlexAlign.End)
                  .margin({ bottom: 10 })
                } else {
                  Row() {
                    Column() {
                      MarkdownView({ content: e.text })
                        .padding({ left: 12, right: 12, top: 8, bottom: 8 })
                        .borderRadius(10)
                        .backgroundColor('#f4f6f8')
                      Text('📋')
                        .fontSize(12)
                        .padding({ top: 4, left: 8 })
                        .onClick(() => { this.copyText(e.text); })
                    }
                    .constraintSize({ maxWidth: '90%' })
                    .alignItems(HorizontalAlign.Start)
                    Blank()
                  }
                  .width('100%')
                  .alignItems(VerticalAlign.Top)
                  .margin({ bottom: 10 })
                }
              }
            }, (e: SessionEventInfo, idx: number) => `${e.seq}-${idx}`)
          }
          .layoutWeight(1)
          .width('100%')
          .padding({ right: 4 })
          .onAppear(() => {
            // List 首帧就定位到底部，避免先显示顶部再跳到底的闪烁
            this.scroller.scrollEdge(Edge.Bottom);
          })
        }
        .layoutWeight(1)
        .width('100%')
        .padding({ left: 12, right: 12 })
      }

      // ── input ───────────────────────────────────────────────────────────
      if (this.running || this.compacting) {
        Row() {
          LoadingProgress()
            .width(20)
            .height(20)
            .color(this.compacting ? '#ff9500' : '#007dff')
          Text(this.compacting ? '正在压缩上下文…' : 'AI 正在回复中…')
            .fontSize(14)
            .fontColor(this.compacting ? '#ff9500' : '#007dff')
            .margin({ left: 10 })
          Blank()
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 14, bottom: 14 })
        .backgroundColor(this.compacting ? '#fff4e5' : '#eef4ff')
      } else {
        Row() {
          TextInput({ text: this.inputText, placeholder: '输入消息...' })
            .layoutWeight(1)
            .height(44)
            .onChange((v: string) => { this.inputText = v; })
          Button(this.sending ? '发送中' : '发送')
            .height(44)
            .margin({ left: 8 })
            .backgroundColor('#007dff')
            .fontColor(Color.White)
            .enabled(!this.sending)
            .onClick(() => this.send())
        }
        .width('100%')
        .padding(12)
      }
    }
    .width('100%')
    .height('100%')
  }

  /** Display label of the currently selected model (for the picker). */
  modelDisplayValue(): string {
    if (this.providerIdx >= 0 && this.providerIdx < this.providers.length) {
      const models = this.providers[this.providerIdx].models;
      if (this.modelIdx >= 0 && this.modelIdx < models.length) {
        return models[this.modelIdx].name || models[this.modelIdx].id;
      }
    }
    return '';
  }
}
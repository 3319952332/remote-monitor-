/**
 * New session page: choose a workspace directory (cwd), an optional provider /
 * model pair, and an optional first message, then create a session through the
 * plugin. When a device tab is active on the home page, only that device's
 * workspaces are shown.
 *
 * Provider / model come from `model.list` (each DSH node's real catalog), so
 * the user picks from what that device actually supports instead of typing.
 */
import { router, promptAction } from '@kit.ArkUI';
import { relay } from '../services/RelayInstance';
import { WorkspaceInfo, EmptyParams, SessionCreateParams, SessionPromptParams, ProviderInfo, ModelInfo, ModelListResult } from '../model/Protocol';
import { deviceLabel } from '../model/Device';

interface PickOption {
  value: string;
}

@Entry
@Component
struct NewSession {
  @State workspaces: WorkspaceInfo[] = [];
  @State cwd: string = '';
  @State nodeId: string = '';
  @State providers: ProviderInfo[] = [];
  @State providerIdx: number = -1;
  @State modelIdx: number = -1;
  @State text: string = '';
  @State creating: boolean = false;
  @State loadingModels: boolean = false;

  aboutToAppear(): void {
    const params: Record<string, Object> = router.getParams() as Record<string, Object>;
    this.nodeId = (params['nodeId'] ?? '') as string;
    this.loadWorkspaces();
    this.loadModels();
  }

  async loadWorkspaces(): Promise<void> {
    const resp = await relay.request('workspace.list', {} as EmptyParams);
    if (resp.ok && resp.result) {
      let ws: WorkspaceInfo[] = resp.result as WorkspaceInfo[];
      // When a specific device tab is active, only show its workspaces.
      if (this.nodeId.length > 0) {
        ws = ws.filter((w: WorkspaceInfo) => (w.nodeId ?? '') === this.nodeId);
      }
      this.workspaces = ws;
      if (this.workspaces.length > 0 && this.cwd.length === 0) {
        this.cwd = this.workspaces[0].path;
        this.nodeId = this.workspaces[0].nodeId ?? '';
      }
    }
  }

  async loadModels(): Promise<void> {
    this.loadingModels = true;
    const resp = await relay.request('model.list', {} as EmptyParams, this.nodeId.length > 0 ? this.nodeId : undefined);
    this.loadingModels = false;
    if (!resp.ok || !resp.result) {
      return;
    }
    const r = resp.result as ModelListResult;
    this.providers = r.providers ?? [];
    // Pre-select the DSH default selection when it is available.
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

  /** Options for the provider dropdown. */
  providerOptions(): PickOption[] {
    return this.providers.map((p: ProviderInfo) => ({ value: p.name || p.id } as PickOption));
  }

  /** Options for the model dropdown of the current provider. */
  modelOptions(): PickOption[] {
    if (this.providerIdx < 0 || this.providerIdx >= this.providers.length) {
      return [];
    }
    return this.providers[this.providerIdx].models.map((m: ModelInfo) => ({ value: m.name || m.id } as PickOption));
  }

  /** Current provider id, or '' when none picked. */
  selectedProviderId(): string {
    if (this.providerIdx >= 0 && this.providerIdx < this.providers.length) {
      return this.providers[this.providerIdx].id;
    }
    return '';
  }

  /** Current model id, or '' when none picked. */
  selectedModelId(): string {
    if (this.providerIdx >= 0 && this.providerIdx < this.providers.length) {
      const models = this.providers[this.providerIdx].models;
      if (this.modelIdx >= 0 && this.modelIdx < models.length) {
        return models[this.modelIdx].id;
      }
    }
    return '';
  }

  async create(): Promise<void> {
    if (this.cwd.length === 0) {
      promptAction.showToast({ message: '请选择工作区目录' });
      return;
    }
    const firstText: string = this.text.trim();
    if (firstText.length === 0) {
      promptAction.showToast({ message: '请输入首条消息（空会话不会在 DSH 中显示）' });
      return;
    }
    this.creating = true;
    const createParams: SessionCreateParams = { cwd: this.cwd };
    const provider: string = this.selectedProviderId();
    const model: string = this.selectedModelId();
    if (provider.length > 0 && model.length > 0) {
      createParams.provider = provider;
      createParams.model = model;
    }
    const resp = await relay.request('session.create', createParams, this.nodeId.length > 0 ? this.nodeId : undefined);
    this.creating = false;
    if (!resp.ok) {
      promptAction.showToast({ message: resp.error?.message ?? '创建失败' });
      return;
    }
    const r: Record<string, Object> = resp.result as Record<string, Object>;
    const sessionId: string = (r['sessionId'] ?? '') as string;

    await relay.request('session.prompt', { sessionId: sessionId, text: firstText } as SessionPromptParams, this.nodeId.length > 0 ? this.nodeId : undefined);
    promptAction.showToast({ message: `已创建 ${sessionId.slice(-8)}` });
    router.back();
  }

  build(): void {
    Column() {
      Row() {
        Button('返回')
          .fontSize(13)
          .height(32)
          .backgroundColor('#f0f0f0')
          .fontColor('#333')
          .onClick(() => router.back())
        Text('新建会话')
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .margin({ left: 12 })
      }
      .width('100%')
      .padding(12)

      Text('工作区目录')
        .fontSize(13)
        .width('100%')
        .padding({ left: 16, top: 8 })

      List() {
        ForEach(this.workspaces, (w: WorkspaceInfo) => {
          ListItem() {
            Row() {
              Text(w.title)
                .fontSize(15)
              Blank()
              Text(`${deviceLabel(w.nodeName ?? '', w.hostname ?? '')} · ${w.path}`)
                .fontSize(11)
                .fontColor('#999')
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
            .width('100%')
            .padding(12)
            .borderRadius(8)
            .backgroundColor(this.cwd === w.path ? '#e6f2ff' : '#f7f8fa')
            .border({ width: this.cwd === w.path ? 1 : 0, color: '#007dff' })
            .margin({ bottom: 8 })
            .onClick(() => { this.cwd = w.path; this.nodeId = w.nodeId ?? ''; })
          }
        }, (w: WorkspaceInfo) => w.id)
      }
      .height(150)
      .width('100%')
      .padding({ left: 16, right: 16 })

      Text('模型（不选则使用 DSH 默认）')
        .fontSize(13)
        .fontColor('#666')
        .width('100%')
        .padding({ left: 16, top: 10 })

      if (this.loadingModels) {
        Row() {
          LoadingProgress()
            .width(16)
            .height(16)
          Text(' 加载模型列表...')
            .fontSize(12)
            .fontColor('#999')
        }
        .width('100%')
        .padding({ left: 16, top: 8 })
      } else if (this.providers.length === 0) {
        Text('该设备无可用模型，将使用 DSH 默认')
          .fontSize(12)
          .fontColor('#999')
          .width('100%')
          .padding({ left: 16, top: 8 })
      } else {
        Row() {
          Column() {
            Text('Provider')
              .fontSize(11)
              .fontColor('#999')
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
            Text('Model')
              .fontSize(11)
              .fontColor('#999')
            Select(this.modelOptions())
              .selected(this.modelIdx >= 0 ? this.modelIdx : 0)
              .value(this.modelIdx >= 0 ? this.selectedModelDisplay() : '请选择')
              .enabled(this.modelOptions().length > 0)
              .onSelect((index: number) => {
                this.modelIdx = index;
              })
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
          .margin({ left: 12 })
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 6 })
      }

      Text('首条消息')
        .fontSize(13)
        .width('100%')
        .padding({ left: 16, top: 12 })

      TextArea({ text: this.text, placeholder: '输入任务描述...' })
        .width('90%')
        .height(120)
        .margin({ top: 8 })
        .onChange((v: string) => { this.text = v; })

      Button(this.creating ? '创建中...' : '创建会话')
        .width('80%')
        .height(46)
        .margin({ top: 20 })
        .backgroundColor('#007dff')
        .fontColor(Color.White)
        .enabled(!this.creating)
        .onClick(() => this.create())
    }
    .width('100%')
    .height('100%')
  }

  /** Display label of the currently selected model. */
  selectedModelDisplay(): string {
    if (this.providerIdx >= 0 && this.providerIdx < this.providers.length) {
      const models = this.providers[this.providerIdx].models;
      if (this.modelIdx >= 0 && this.modelIdx < models.length) {
        return models[this.modelIdx].name || models[this.modelIdx].id;
      }
    }
    return '';
  }
}
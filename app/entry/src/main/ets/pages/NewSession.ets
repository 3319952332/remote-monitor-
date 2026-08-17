/**
 * New session page: choose a workspace directory (cwd) and an optional first
 * message, then create a session through the plugin.
 */
import { router, promptAction } from '@kit.ArkUI';
import { relay } from '../services/RelayInstance';
import { WorkspaceInfo, EmptyParams, SessionCreateParams, SessionPromptParams } from '../model/Protocol';

@Entry
@Component
struct NewSession {
  @State workspaces: WorkspaceInfo[] = [];
  @State cwd: string = '';
  @State nodeId: string = '';
  @State text: string = '';
  @State creating: boolean = false;

  aboutToAppear(): void {
    this.loadWorkspaces();
  }

  async loadWorkspaces(): Promise<void> {
    const resp = await relay.request('workspace.list', {} as EmptyParams);
    if (resp.ok && resp.result) {
      this.workspaces = resp.result as WorkspaceInfo[];
      if (this.workspaces.length > 0 && this.cwd.length === 0) {
        this.cwd = this.workspaces[0].path;
        this.nodeId = this.workspaces[0].nodeId ?? '';
      }
    }
  }

  async create(): Promise<void> {
    if (this.cwd.length === 0) {
      promptAction.showToast({ message: '请选择工作区目录' });
      return;
    }
    this.creating = true;
    const resp = await relay.request('session.create', { cwd: this.cwd } as SessionCreateParams, this.nodeId.length > 0 ? this.nodeId : undefined);
    this.creating = false;
    if (!resp.ok) {
      promptAction.showToast({ message: resp.error?.message ?? '创建失败' });
      return;
    }
    const r = resp.result as Record<string, Object>;
    const sessionId = (r['sessionId'] ?? '') as string;

    const firstText = this.text.trim();
    if (firstText.length > 0) {
      await relay.request('session.prompt', { sessionId: sessionId, text: firstText } as SessionPromptParams, this.nodeId.length > 0 ? this.nodeId : undefined);
    }
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
              Text(`${w.hostname ?? w.nodeName ?? '未知设备'} · ${w.path}`)
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
      .height(200)
      .width('100%')
      .padding({ left: 16, right: 16 })

      Text('首条消息（可选）')
        .fontSize(13)
        .width('100%')
        .padding({ left: 16, top: 4 })

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
}

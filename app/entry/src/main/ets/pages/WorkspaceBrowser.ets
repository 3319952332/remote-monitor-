/**
 * Workspace sessions page: list the sessions belonging to one workspace
 * (matched by cwd), so tapping a workspace shows its conversations rather than
 * a raw file listing. Receives `path` and `title` via router params.
 */
import { router } from '@kit.ArkUI';
import { relay } from '../services/RelayInstance';
import { SessionInfo, SessionListParams } from '../model/Protocol';

@Entry
@Component
struct WorkspaceBrowser {
  @State path: string = '';
  @State wsTitle: string = '';
  @State nodeId: string = '';
  @State sessions: SessionInfo[] = [];
  @State loading: boolean = false;

  aboutToAppear(): void {
    const params = router.getParams() as Record<string, Object>;
    this.path = (params['path'] ?? '') as string;
    this.wsTitle = (params['title'] ?? '') as string;
    this.nodeId = (params['nodeId'] ?? '') as string;
    this.loadSessions();
  }

  async loadSessions(): Promise<void> {
    this.loading = true;
    const resp = await relay.request('session.list', { cwd: this.path } as SessionListParams, this.nodeId.length > 0 ? this.nodeId : undefined);
    this.loading = false;
    if (resp.ok && resp.result) {
      this.sessions = resp.result as SessionInfo[];
    }
  }

  sessionTitle(s: SessionInfo): string {
    if (s.title && s.title.length > 0) {
      return s.title;
    }
    return s.id.slice(-8);
  }

  sessionTime(s: SessionInfo): string {
    const t = s.updatedAt ?? s.createdAt;
    if (!t) {
      return '';
    }
    const d = new Date(t);
    const pad = (n: number): string => (n < 10 ? `0${n}` : `${n}`);
    return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())} ${pad(d.getHours())}:${pad(d.getMinutes())}`;
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
        Column() {
          Text(this.wsTitle.length > 0 ? this.wsTitle : '工作区')
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.path)
            .fontSize(11)
            .fontColor('#999')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        .margin({ left: 12 })
        Button(this.loading ? '加载中' : '刷新')
          .fontSize(12)
          .height(30)
          .backgroundColor('#007dff')
          .fontColor(Color.White)
          .onClick(() => this.loadSessions())
      }
      .width('100%')
      .padding(12)

      Text(`会话 (${this.sessions.length})`)
        .fontSize(13)
        .fontColor('#666')
        .width('100%')
        .padding({ left: 16, top: 4 })

      List() {
        ForEach(this.sessions, (s: SessionInfo) => {
          ListItem() {
            Row() {
              Column() {
                Text(this.sessionTitle(s))
                  .fontSize(15)
                  .fontWeight(FontWeight.Medium)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                Text(this.sessionTime(s))
                  .fontSize(11)
                  .fontColor('#999')
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)
              Text(s.running ? '运行中' : '空闲')
                .fontSize(11)
                .fontColor(s.running ? '#007dff' : '#999')
                .padding({ left: 8, right: 8, top: 3, bottom: 3 })
                .borderRadius(4)
                .backgroundColor(s.running ? '#e6f2ff' : '#f0f0f0')
            }
            .width('100%')
            .padding(12)
            .borderRadius(8)
            .backgroundColor(s.running ? '#f4f9ff' : '#f7f8fa')
            .margin({ bottom: 8 })
            .onClick(() => {
              router.pushUrl({ url: 'pages/SessionDetail', params: { sessionId: s.id } });
            })
          }
        }, (s: SessionInfo) => s.id)
      }
      .layoutWeight(1)
      .width('100%')
      .padding({ left: 16, right: 16 })
    }
    .width('100%')
    .height('100%')
  }
}

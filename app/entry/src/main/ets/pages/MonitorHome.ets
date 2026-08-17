/**
 * Monitor home page: connection status, workspace list, session list,
 * and the turn.end completion popup + local notification.
 */
import { router } from '@kit.ArkUI';
import { relay } from '../services/RelayInstance';
import { NotificationService } from '../services/NotificationService';
import { WorkspaceInfo, SessionInfo, TurnEndData, EmptyParams } from '../model/Protocol';

@Entry
@Component
struct MonitorHome {
  @State connected: boolean = false;
  @State statusText: string = '连接中...';
  @State workspaces: WorkspaceInfo[] = [];
  @State sessions: SessionInfo[] = [];
  @State loading: boolean = false;

  aboutToAppear(): void {
    relay.onStatus = (online: boolean, detail: string) => {
      this.connected = online;
      this.statusText = detail;
      if (online) {
        this.refreshAll();
      }
    };
    relay.onEvent = (event: string, sessionId: string, data: object) => {
      this.handleEvent(event, sessionId, data);
    };
    relay.connect();
  }

  aboutToDisappear(): void {
    // keep the shared connection alive across pages; do not close here
  }

  async refreshAll(): Promise<void> {
    this.loading = true;
    await this.loadWorkspaces();
    await this.loadSessions();
    this.loading = false;
  }

  async loadWorkspaces(): Promise<void> {
    const resp = await relay.request('workspace.list', {} as EmptyParams);
    if (resp.ok && resp.result) {
      this.workspaces = resp.result as WorkspaceInfo[];
    }
  }

  async loadSessions(): Promise<void> {
    const resp = await relay.request('session.list', {} as EmptyParams);
    if (resp.ok && resp.result) {
      this.sessions = resp.result as SessionInfo[];
    }
  }

  /** Display title for a session: folded title, else cwd basename, else id. */
  sessionTitle(s: SessionInfo): string {
    if (s.title && s.title.length > 0) {
      return s.title;
    }
    if (s.cwd && s.cwd.length > 0) {
      const parts = s.cwd.split(/[\\/]/).filter((x: string) => x.length > 0);
      if (parts.length > 0) {
        return parts[parts.length - 1];
      }
    }
    return s.id.slice(-8);
  }

  /** Short human date for a session row (last-change time, else creation). */
  sessionTime(s: SessionInfo): string {
    const t = s.updatedAt ?? s.createdAt;
    if (!t) {
      return '';
    }
    const d = new Date(t);
    const pad = (n: number): string => (n < 10 ? `0${n}` : `${n}`);
    return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())} ${pad(d.getHours())}:${pad(d.getMinutes())}`;
  }

  handleEvent(event: string, sessionId: string, data: object): void {
    if (event === 'turn.end') {
      const d = data as TurnEndData;
      const kind = d.reason?.kind ?? 'done';
      const device = d.hostname ?? d.nodeName ?? '';
      // tray notification (no AGC), tagged with the source device
      NotificationService.notifyCompletion(sessionId, d.turn, kind, device);
      // refresh the session list to reflect the finished turn
      this.loadSessions();
    }
  }

  build(): void {
    Column() {
      // header: connection status
      Row() {
        Circle({ width: 10, height: 10 })
          .fill(this.connected ? '#34c759' : '#ff3b30')
        Text(this.statusText)
          .fontSize(13)
          .fontColor('#666')
          .margin({ left: 8 })
        Blank()
        Button(this.loading ? '刷新中' : '刷新')
          .fontSize(12)
          .height(30)
          .backgroundColor('#007dff')
          .fontColor(Color.White)
          .onClick(() => this.refreshAll())
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 12, bottom: 8 })

      // workspaces
      Text('工作区')
        .fontSize(14)
        .fontWeight(FontWeight.Bold)
        .width('100%')
        .padding({ left: 16, top: 8 })
      List() {
        ForEach(this.workspaces, (w: WorkspaceInfo) => {
          ListItem() {
            Row() {
              Column() {
                Text(w.title)
                  .fontSize(16)
                  .fontWeight(FontWeight.Medium)
                Text(`${w.hostname ?? w.nodeName ?? '未知设备'} · ${w.path}`)
                  .fontSize(11)
                  .fontColor('#999')
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)
              Text(`${w.sessionIds.length} 会话`)
                .fontSize(11)
                .fontColor('#999')
            }
            .width('100%')
            .padding(12)
            .borderRadius(8)
            .backgroundColor('#f7f8fa')
            .margin({ bottom: 8 })
            .onClick(() => {
              router.pushUrl({ url: 'pages/WorkspaceBrowser', params: { path: w.path, title: w.title, nodeId: w.nodeId ?? '' } });
            })
          }
        }, (w: WorkspaceInfo) => w.id)
      }
      .height(160)
      .width('100%')
      .padding({ left: 16, right: 16 })

      // sessions
      Row() {
        Text('会话')
          .fontSize(14)
          .fontWeight(FontWeight.Bold)
        Blank()
        Text('点击查看详情')
          .fontSize(11)
          .fontColor('#999')
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 4 })

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
                Text(`${s.hostname ?? s.nodeName ?? '未知设备'} · ${this.sessionTime(s)}`)
                  .fontSize(11)
                  .fontColor('#999')
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
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
              router.pushUrl({ url: 'pages/SessionDetail', params: { sessionId: s.id, nodeId: s.nodeId ?? '' } });
            })
          }
        }, (s: SessionInfo) => s.id)
      }
      .layoutWeight(1)
      .width('100%')
      .padding({ left: 16, right: 16 })

      // new session
      Button('新建会话')
        .width('80%')
        .height(46)
        .margin({ bottom: 20 })
        .backgroundColor('#007dff')
        .fontColor(Color.White)
        .onClick(() => {
          router.pushUrl({ url: 'pages/NewSession' });
        })
    }
    .width('100%')
    .height('100%')
  }
}

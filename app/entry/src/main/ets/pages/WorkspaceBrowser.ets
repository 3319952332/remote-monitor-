/**
 * Workspace sessions page: list the sessions belonging to one workspace
 * (matched by cwd), so tapping a workspace shows its conversations rather than
 * a raw file listing. Receives `path`, `title`, `nodeId`, `nodeName` and
 * `hostname` via router params.
 *
 * nodeId is the relay-assigned id captured when the workspace list was fetched.
 * It goes stale when a plugin hot-reload / DSH restart reconnects the node under
 * a NEW id — a pinned session.list then answers NO_NODE and the page would look
 * empty. To survive that, we re-resolve the CURRENT nodeId from node.list using
 * the stable device key (name@hostname) and retry before giving up.
 */
import { router } from '@kit.ArkUI';
import { relay } from '../services/RelayInstance';
import { SessionInfo, SessionListParams, SessionListResult, EmptyParams, NodeInfo } from '../model/Protocol';
import { deviceKey } from '../model/Device';

@Entry
@Component
struct WorkspaceBrowser {
  @State path: string = '';
  @State wsTitle: string = '';
  @State nodeId: string = '';
  @State nodeName: string = '';
  @State hostname: string = '';
  @State sessions: SessionInfo[] = [];
  @State loading: boolean = false;
  @State loadError: string = '';

  aboutToAppear(): void {
    const params = router.getParams() as Record<string, Object>;
    this.path = (params['path'] ?? '') as string;
    this.wsTitle = (params['title'] ?? '') as string;
    this.nodeId = (params['nodeId'] ?? '') as string;
    this.nodeName = (params['nodeName'] ?? '') as string;
    this.hostname = (params['hostname'] ?? '') as string;
    this.loadSessions();
  }

  /** Resolve the CURRENT relay nodeId for this workspace's device, using the
   *  stable device key (name@hostname). Returns:
   *   - the fresh node id when the device is online,
   *   - '' when a device identity was passed, node.list was read, and the
   *     device is NOT among the online nodes,
   *   - the passed nodeId unchanged when no identity was supplied (legacy nav)
   *     OR node.list could not be read (transient — let the retry below decide).
   */
  async resolveCurrentNodeId(): Promise<string> {
    if (this.nodeName.length === 0 && this.hostname.length === 0) {
      return this.nodeId;
    }
    const resp = await relay.request('node.list', {} as EmptyParams);
    if (!resp.ok || !resp.result) {
      // node.list itself failed (e.g. not connected yet) — don't claim offline.
      return this.nodeId;
    }
    const nodes = resp.result as NodeInfo[];
    const want = deviceKey(this.nodeName, this.hostname);
    for (const n of nodes) {
      if (deviceKey(n.name, n.hostname) === want) {
        return n.id;
      }
    }
    return '';
  }

  async loadSessions(): Promise<void> {
    this.loading = true;
    this.loadError = '';
    // One page covers a workspace's (bounded) session set; the plugin folds
    // titles inline so no separate session.title fetch is needed.
    const params: SessionListParams = { cwd: this.path, limit: 100, offset: 0 };

    // First try with the re-resolved (current) nodeId — survives hot-reload
    // reconnects where the workspace-list nodeId went stale.
    const current: string = await this.resolveCurrentNodeId();
    if (current.length === 0 && (this.nodeName.length > 0 || this.hostname.length > 0)) {
      // A device identity was provided but it is not online — pinned requests
      // cannot succeed and an unpinned retry might hit a DIFFERENT device.
      this.loading = false;
      this.loadError = '该设备当前离线，无法加载会话';
      return;
    }
    let resp = await relay.request('session.list', params, current.length > 0 ? current : undefined);

    // Fallback 1: the pinned node is gone (NO_NODE / NODE_TIMEOUT) or the link
    // dropped (DISCONNECTED). Retry once WITHOUT a pin — session.list then
    // routes to the first online node, which for a single-device deployment is
    // the same device.
    if (!resp.ok) {
      const errCode: string = (resp.error?.code ?? '') as string;
      if (errCode === 'NO_NODE' || errCode === 'NODE_TIMEOUT' || errCode === 'DISCONNECTED') {
        resp = await relay.request('session.list', params);
      }
    }

    this.loading = false;
    if (!resp.ok || !resp.result) {
      this.loadError = resp.error?.message ?? '加载失败';
      return;
    }
    const r = resp.result as SessionListResult;
    this.sessions = r.rows ?? [];
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

      if (this.loadError.length > 0) {
        Text(this.loadError)
          .fontSize(13)
          .fontColor('#ff3b30')
          .width('100%')
          .textAlign(TextAlign.Center)
          .padding(24)
      } else if (!this.loading && this.sessions.length === 0) {
        Text('该工作区暂无会话')
          .fontSize(13)
          .fontColor('#999')
          .width('100%')
          .textAlign(TextAlign.Center)
          .padding(24)
      }

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
              Text(s.running ? '运行中' : (s.live ? '空闲' : '冷'))
                .fontSize(11)
                .fontColor(s.running ? '#007dff' : (s.live ? '#999' : '#ff9500'))
                .padding({ left: 8, right: 8, top: 3, bottom: 3 })
                .borderRadius(4)
                .backgroundColor(s.running ? '#e6f2ff' : (s.live ? '#f0f0f0' : '#fff3e0'))
            }
            .width('100%')
            .padding(12)
            .borderRadius(8)
            .backgroundColor(s.running ? '#f4f9ff' : (s.live ? '#f7f8fa' : '#fafaf5'))
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
    }
    .width('100%')
    .height('100%')
  }
}

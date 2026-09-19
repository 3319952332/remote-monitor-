/**
 * Monitor home page: connection status, device-tab switcher, workspace list,
 * session list, and the turn.end completion notification.
 *
 * App-pull sync (per-device): there is no "全部" tab anymore — the session list
 * is always pinned to one device (defaulting to the first online node). The
 * first page (PAGE_SIZE rows, titles folded inline by the plugin) loads on
 * entry; pull-down refreshes it and scrolling to the bottom (or the 加载更多
 * button) fetches the next page. Workspaces follow the active device tab too
 * (client-side filter on the stable device key, so switching needs no reload
 * and a stale relay nodeId can't blank the list).
 */
import { router } from '@kit.ArkUI';
import { relay } from '../services/RelayInstance';
import { NotificationService } from '../services/NotificationService';
import { WorkspaceInfo, SessionInfo, TurnEndData, EmptyParams, NodeInfo, SessionListParams, SessionListResult } from '../model/Protocol';
import { deviceKey, deviceLabel } from '../model/Device';

const PAGE_SIZE = 20;

interface DeviceTab {
  key: string;
  label: string;
}

@Entry
@Component
struct MonitorHome {
  @State connected: boolean = false;
  @State statusText: string = '连接中...';
  @State workspaces: WorkspaceInfo[] = [];
  @State sessions: SessionInfo[] = [];
  @State nodes: NodeInfo[] = [];
  @State activeDevice: string = ''; // always a concrete device key (no "全部")
  @State loading: boolean = false;
  // pagination
  @State sessionsOffset: number = 0;
  @State sessionsHasMore: boolean = false;
  @State loadingMore: boolean = false;
  @State refreshing: boolean = false;
  private titleCatchUpTimer: number = -1;

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

  onPageShow(): void {
    const pending: string = NotificationService.consumePendingDeviceKey();
    if (pending.length > 0) {
      this.activeDevice = pending;
    }
    // Question-notification deep link: jump straight into the session so the
    // question card is visible without the user hunting for the session.
    const route = NotificationService.consumePendingSessionRoute();
    if (route.sessionId.length > 0) {
      router.pushUrl({ url: 'pages/SessionDetail', params: { sessionId: route.sessionId, nodeId: route.nodeId } });
    }
  }

  async refreshAll(): Promise<void> {
    this.loading = true;
    await this.loadNodes();
    await this.loadWorkspaces();
    await this.loadSessions(true);
    this.loading = false;
  }

  async loadNodes(): Promise<void> {
    const resp = await relay.request('node.list', {} as EmptyParams);
    if (resp.ok && resp.result) {
      this.nodes = resp.result as NodeInfo[];
      // Keep the active device valid: default to the first online node, and
      // fall back to it when the previously selected device went offline.
      if (this.nodes.length > 0) {
        const keys: string[] = this.nodes.map((n: NodeInfo) => deviceKey(n.name, n.hostname));
        if (this.activeDevice.length === 0 || keys.indexOf(this.activeDevice) < 0) {
          this.activeDevice = keys[0];
        }
      } else {
        this.activeDevice = '';
      }
    }
  }

  async loadWorkspaces(): Promise<void> {
    // Fetch the aggregate workspace list once (all devices, tagged with
    // nodeId/nodeName/hostname by the relay), then displayWorkspaces filters
    // it to the active device. Fetching everything in one shot keeps tab
    // switches instant — no per-device refetch needed.
    const resp = await relay.request('workspace.list', {} as EmptyParams);
    if (resp.ok && resp.result) {
      this.workspaces = resp.result as WorkspaceInfo[];
    }
  }

  /** Load one page of the active device's session list. `reset=true` restarts
   *  from page 0 (entry / refresh / tab switch); `reset=false` appends the next
   *  page (pull-down footer / onReachEnd). Titles arrive inline from the plugin
   *  (no separate session.title waterfall). */
  async loadSessions(reset: boolean): Promise<void> {
    const nodeId: string = this.activeNodeId();
    const offset: number = reset ? 0 : this.sessionsOffset;
    if (reset) {
      this.sessions = [];
      this.sessionsOffset = 0;
      this.sessionsHasMore = false;
    }
    this.loading = true;
    const params: SessionListParams = { limit: PAGE_SIZE, offset: offset };
    let resp = await relay.request('session.list', params, nodeId.length > 0 ? nodeId : undefined);
    // Retry without nodeId once when the pinned node is gone (e.g. after a
    // plugin hot-reload reconnects under a new id).
    if (!resp.ok) {
      const errCode: string = (resp.error?.code ?? '') as string;
      if (errCode === 'NO_NODE' || errCode === 'NODE_TIMEOUT' || errCode === 'DISCONNECTED') {
        await new Promise<void>((resolve) => setTimeout(resolve, 1500));
        resp = await relay.request('session.list', params);
      }
    }
    this.loading = false;
    if (!resp.ok || !resp.result) {
      return;
    }
    const r = resp.result as SessionListResult;
    const incoming: SessionInfo[] = r.rows ?? [];
    if (reset) {
      this.sessions = incoming;
    } else {
      // Dedupe on append: offset pagination can drift on a live list.
      const seen: Set<string> = new Set<string>();
      for (const s of this.sessions) {
        seen.add(s.id);
      }
      const fresh: SessionInfo[] = incoming.filter((s: SessionInfo) => !seen.has(s.id));
      this.sessions = this.sessions.concat(fresh);
    }
    // The next offset follows the server's page boundary, not the deduped count.
    this.sessionsOffset = offset + incoming.length;
    this.sessionsHasMore = r.hasMore === true;
  }

  async loadMoreSessions(): Promise<void> {
    if (this.loadingMore || !this.sessionsHasMore || this.loading) {
      return;
    }
    this.loadingMore = true;
    await this.loadSessions(false);
    this.loadingMore = false;
  }

  /** Pull-down refresh: reload the first page. */
  async refreshSessions(): Promise<void> {
    await this.loadSessions(true);
    this.refreshing = false;
  }

  /** Completion notifications refresh the first page only when the user hasn't
   *  paged deep — otherwise every turn.end would yank their scroll position. */
  maybeRefreshSessions(): void {
    if (this.sessionsOffset > PAGE_SIZE) {
      return;
    }
    this.loadSessions(true);
    // DSH writes session titles asynchronously (LLM) shortly AFTER a turn
    // completes — the first refresh can still be title-less. Schedule one
    // catch-up refresh so the folded title appears without waiting for the next
    // turn.end or a manual pull-down (app-pull model, no push dependency).
    this.scheduleTitleCatchUp();
  }

  private scheduleTitleCatchUp(): void {
    if (this.titleCatchUpTimer !== -1) {
      clearTimeout(this.titleCatchUpTimer);
    }
    this.titleCatchUpTimer = setTimeout(() => {
      this.titleCatchUpTimer = -1;
      if (this.sessionsOffset <= PAGE_SIZE) {
        this.loadSessions(true);
      }
    }, 4500);
  }

  aboutToDisappear(): void {
    this.stopTitleCatchUp();
  }

  private stopTitleCatchUp(): void {
    if (this.titleCatchUpTimer !== -1) {
      clearTimeout(this.titleCatchUpTimer);
      this.titleCatchUpTimer = -1;
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

  /** Tabs: one per online node (no "全部"). */
  tabs(): DeviceTab[] {
    const out: DeviceTab[] = [];
    for (const n of this.nodes) {
      out.push({ key: deviceKey(n.name, n.hostname), label: deviceLabel(n.name, n.hostname) });
    }
    return out;
  }

  /** Workspaces follow the active device tab: filter the aggregate list by the
   *  stable device key (name@hostname). Items carry that tag from the relay, so
   *  we filter client-side without a per-device refetch. */
  displayWorkspaces(): WorkspaceInfo[] {
    if (this.activeDevice.length === 0) {
      return [];
    }
    return this.workspaces.filter((w: WorkspaceInfo) => deviceKey(w.nodeName ?? '', w.hostname ?? '') === this.activeDevice);
  }

  /** Sessions are always pinned to the active device. */
  displaySessions(): SessionInfo[] {
    return this.sessions;
  }

  /** The relay-assigned nodeId of the currently selected device ('' = none). */
  activeNodeId(): string {
    if (this.activeDevice === '') {
      return '';
    }
    for (const n of this.nodes) {
      if (deviceKey(n.name, n.hostname) === this.activeDevice) {
        return n.id;
      }
    }
    return '';
  }

  handleEvent(event: string, sessionId: string, data: object): void {
    if (event === 'turn.end') {
      const d = data as TurnEndData;
      const kind: string = d.reason?.kind ?? 'done';
      const label: string = deviceLabel(d.nodeName ?? '', d.hostname ?? '');
      const key: string = deviceKey(d.nodeName ?? '', d.hostname ?? '');
      // tray notification — tap opens the app onto this device's tab
      NotificationService.notifyCompletion(sessionId, d.turn, kind, label, key);
      // refresh the first page of the session list
      this.maybeRefreshSessions();
    } else if (event === 'node.online' || event === 'node.offline') {
      // keep device tabs + lists in sync when nodes come and go
      this.loadNodes();
      this.loadWorkspaces();
      this.loadSessions(true);
    } else if (event === 'question/requested') {
      // A question batch arrived — post a question notification that deep-links
      // into the session detail page, where the question card is rendered.
      const d = data as Record<string, Object>;
      const questions = d['questions'] as Array<Object> | undefined;
      if (questions && questions.length > 0) {
        const first = questions[0] as Record<string, Object>;
        const q = (first['question'] ?? '') as string;
        const nodeId = (d['nodeId'] ?? '') as string;
        const nodeName = (d['nodeName'] ?? '') as string;
        const hostname = (d['hostname'] ?? '') as string;
        NotificationService.notifyQuestion(sessionId, nodeId, nodeName, hostname, q);
      }
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

      // device tabs (no "全部")
      Scroll() {
        Row({ space: 8 }) {
          ForEach(this.tabs(), (t: DeviceTab) => {
            Text(t.label)
              .fontSize(13)
              .fontWeight(this.activeDevice === t.key ? FontWeight.Medium : FontWeight.Normal)
              .fontColor(this.activeDevice === t.key ? Color.White : '#333')
              .backgroundColor(this.activeDevice === t.key ? '#007dff' : '#f0f0f0')
              .padding({ left: 14, right: 14, top: 6, bottom: 6 })
              .borderRadius(16)
              .onClick(() => {
                this.activeDevice = t.key;
                this.loadSessions(true);
              })
          }, (t: DeviceTab) => t.key)
        }
        .padding({ left: 16, right: 16, top: 2, bottom: 6 })
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .width('100%')

      // workspaces (pinned to the active device tab)
      Text('工作区')
        .fontSize(14)
        .fontWeight(FontWeight.Bold)
        .width('100%')
        .padding({ left: 16, top: 8 })
      List() {
        if (!this.loading && this.displayWorkspaces().length === 0) {
          ListItem() {
            Text('该设备暂无工作区')
              .fontSize(13)
              .fontColor('#999')
              .width('100%')
              .textAlign(TextAlign.Center)
              .padding(24)
          }
        }
        ForEach(this.displayWorkspaces(), (w: WorkspaceInfo) => {
          ListItem() {
            Row() {
              Column() {
                Text(w.title)
                  .fontSize(16)
                  .fontWeight(FontWeight.Medium)
                Text(`${deviceLabel(w.nodeName ?? '', w.hostname ?? '')} · ${w.path}`)
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
              // Pass the stable device identity (nodeName/hostname) alongside
              // the nodeId so WorkspaceBrowser can re-resolve a stale nodeId
              // after a plugin hot-reload / DSH restart.
              router.pushUrl({ url: 'pages/WorkspaceBrowser', params: { path: w.path, title: w.title, nodeId: w.nodeId ?? '', nodeName: w.nodeName ?? '', hostname: w.hostname ?? '' } });
            })
          }
        }, (w: WorkspaceInfo) => w.id)
      }
      .height(160)
      .width('100%')
      .padding({ left: 16, right: 16 })

      // sessions (pinned to the active device, paginated)
      Row() {
        Text('会话')
          .fontSize(14)
          .fontWeight(FontWeight.Bold)
        Blank()
        Text('下拉刷新 · 上拉加载更多')
          .fontSize(11)
          .fontColor('#999')
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 4 })

      Refresh({ refreshing: $$this.refreshing }) {
        List() {
          if (!this.loading && this.sessions.length === 0) {
            ListItem() {
              Text('暂无会话')
                .fontSize(13)
                .fontColor('#999')
                .width('100%')
                .textAlign(TextAlign.Center)
                .padding(24)
            }
          }
          ForEach(this.displaySessions(), (s: SessionInfo) => {
            ListItem() {
              Row() {
                Column() {
                  Text(this.sessionTitle(s))
                    .fontSize(15)
                    .fontWeight(FontWeight.Medium)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                  Text(`${deviceLabel(s.nodeName ?? '', s.hostname ?? '')} · ${this.sessionTime(s)}`)
                    .fontSize(11)
                    .fontColor('#999')
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
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

          // footer: loading / load-more / end
          if (this.loadingMore) {
            ListItem() {
              Row() {
                LoadingProgress().width(18).height(18)
                Text(' 加载更多...')
                  .fontSize(12)
                  .fontColor('#999')
              }
              .justifyContent(FlexAlign.Center)
              .width('100%')
              .padding(8)
            }
          } else if (this.sessionsHasMore && this.sessions.length > 0) {
            ListItem() {
              Row() {
                Button('加载更多')
                  .fontSize(12)
                  .height(34)
                  .width('60%')
                  .backgroundColor('#f0f0f0')
                  .fontColor('#333')
                  .onClick(() => this.loadMoreSessions())
              }
              .justifyContent(FlexAlign.Center)
              .width('100%')
              .padding(4)
            }
          } else if (!this.sessionsHasMore && this.sessions.length > 0) {
            ListItem() {
              Text('没有更多了')
                .fontSize(12)
                .fontColor('#999')
                .width('100%')
                .textAlign(TextAlign.Center)
                .padding(8)
            }
          }
        }
        .layoutWeight(1)
        .width('100%')
        .padding({ left: 16, right: 16 })
        .onReachEnd(() => this.loadMoreSessions())
      }
      .layoutWeight(1)
      .width('100%')
      .onRefreshing(() => this.refreshSessions())

      // new session — targets the selected device
      Button('新建会话')
        .width('80%')
        .height(46)
        .margin({ bottom: 20 })
        .backgroundColor('#007dff')
        .fontColor(Color.White)
        .onClick(() => {
          const nodeId: string = this.activeNodeId();
          router.pushUrl({ url: 'pages/NewSession', params: { nodeId: nodeId } });
        })
    }
    .width('100%')
    .height('100%')
  }
}

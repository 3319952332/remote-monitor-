/**
 * Session detail page: transcript + send a follow-up message.
 * Receives `sessionId` via router params.
 */
import { router, promptAction } from '@kit.ArkUI';
import { relay } from '../services/RelayInstance';
import { SessionEventInfo, SessionHistoryParams, SessionPromptParams } from '../model/Protocol';
import { MarkdownView } from '../components/MarkdownView';

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
  private pollTimer: number = -1;
  private scroller: Scroller = new Scroller();

  aboutToAppear(): void {
    const params = router.getParams() as Record<string, Object>;
    this.sessionId = (params['sessionId'] ?? '') as string;
    this.nodeId = (params['nodeId'] ?? '') as string;
    this.loadHistory();
  }

  aboutToDisappear(): void {
    this.stopPolling();
  }

  async loadHistory(): Promise<void> {
    this.loading = true;
    this.loadError = '';
    await this.fetchHistory();
    this.loading = false;
    // 主动加载（进入页面 / 刷新 / 发送后）滚到底
    this.scrollToBottom();
  }

  /** Pull history + running state; drives the polling loop while the AI replies. */
  async fetchHistory(): Promise<void> {
    const resp = await relay.request('session.history', { sessionId: this.sessionId, fromSeq: 0 } as SessionHistoryParams, this.nodeId.length > 0 ? this.nodeId : undefined);
    if (!resp.ok) {
      this.loadError = resp.error?.message ?? '加载失败';
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

  async send(): Promise<void> {
    const text = this.inputText.trim();
    if (text.length === 0) {
      promptAction.showToast({ message: '请输入内容' });
      return;
    }
    this.sending = true;
    const resp = await relay.request('session.prompt', { sessionId: this.sessionId, text: text } as SessionPromptParams, this.nodeId.length > 0 ? this.nodeId : undefined);
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
        Blank()
        Button('刷新')
          .fontSize(12)
          .height(30)
          .backgroundColor('#007dff')
          .fontColor(Color.White)
          .onClick(() => this.loadHistory())
      }
      .width('100%')
      .padding(12)

      // transcript
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
                    }
                    .constraintSize({ maxWidth: '82%' })
                    .padding({ left: 12, right: 12, top: 8, bottom: 8 })
                    .borderRadius(10)
                    .backgroundColor('#007dff')
                  }
                  .width('100%')
                  .justifyContent(FlexAlign.End)
                  .margin({ bottom: 8 })
                } else {
                  Row() {
                    Column() {
                      MarkdownView({ content: e.text })
                    }
                    .constraintSize({ maxWidth: '90%' })
                    .padding({ left: 12, right: 12, top: 8, bottom: 8 })
                    .borderRadius(10)
                    .backgroundColor('#f4f6f8')
                    Blank()
                  }
                  .width('100%')
                  .alignItems(VerticalAlign.Top)
                  .margin({ bottom: 8 })
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

      // input — hidden while the AI is mid-reply, replaced by a running state
      if (this.running) {
        Row() {
          LoadingProgress()
            .width(20)
            .height(20)
            .color('#007dff')
          Text('AI 正在回复中…')
            .fontSize(14)
            .fontColor('#007dff')
            .margin({ left: 10 })
          Blank()
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 14, bottom: 14 })
        .backgroundColor('#eef4ff')
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
}

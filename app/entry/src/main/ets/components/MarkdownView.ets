/**
 * MarkdownView: renders a Markdown string using plain ArkUI Text/Span — no
 * third-party library. Used to show assistant answers in the transcript.
 */
import { InlineToken, MarkdownBlock, parseMarkdown } from '../model/Markdown';
import { common, Want } from '@kit.AbilityKit';

@Component
export struct MarkdownView {
  @Prop content: string = '';

  headingSize(level: number): number {
    if (level <= 1) {
      return 18;
    }
    if (level === 2) {
      return 17;
    }
    if (level === 3) {
      return 16;
    }
    return 15;
  }

  openLink(url: string): void {
    try {
      const ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
      const want: Want = {
        action: 'ohos.want.action.viewData',
        uri: url,
      };
      ctx.startAbility(want);
    } catch (e) {
      // ignore — can't open browser from this context
    }
  }

  @Builder
  spanRun(t: InlineToken) {
    if (t.kind === 'bold') {
      Span(t.text)
        .fontWeight(FontWeight.Bold)
    } else if (t.kind === 'italic') {
      Span(t.text)
        .fontStyle(FontStyle.Italic)
    } else if (t.kind === 'code') {
      Span(t.text)
        .fontColor('#c7254e')
    } else if (t.kind === 'link') {
      Span(t.text)
        .fontColor('#007dff')
        .decoration({ type: TextDecorationType.Underline, color: '#007dff' })
        .onClick(() => { this.openLink(t.url); })
    } else {
      Span(t.text)
    }
  }

  @Builder
  bodyText(inlines: InlineToken[], fontSize: number, weight: FontWeight, color: string) {
    Text() {
      ForEach(inlines, (t: InlineToken) => {
        this.spanRun(t)
      }, (t: InlineToken, idx: number) => `${t.kind}-${idx}`)
    }
    .fontSize(fontSize)
    .fontWeight(weight)
    .fontColor(color)
    .lineHeight(22)
    .margin({ top: 2, bottom: 2 })
    .wordBreak(WordBreak.BREAK_ALL)
    .copyOption(CopyOptions.LocalDevice)
  }

  /** Minimum total table width so columns stay readable; beyond that it scrolls. */
  tableMinWidth(cols: number): number {
    const n: number = cols > 0 ? cols : 1;
    return n * 120;
  }

  @Builder
  tableHeaderCell(cell: InlineToken[]) {
    Text() {
      ForEach(cell, (t: InlineToken) => {
        this.spanRun(t)
      }, (t: InlineToken, idx: number) => `th-${t.kind}-${idx}`)
    }
    .fontSize(13)
    .fontWeight(FontWeight.Bold)
    .fontColor('#222222')
    .textAlign(TextAlign.Start)
    .padding({ left: 8, right: 8, top: 6, bottom: 6 })
    .layoutWeight(1)
    .wordBreak(WordBreak.BREAK_ALL)
    .copyOption(CopyOptions.LocalDevice)
  }

  @Builder
  tableDataCell(cell: InlineToken[]) {
    Text() {
      ForEach(cell, (t: InlineToken) => {
        this.spanRun(t)
      }, (t: InlineToken, idx: number) => `td-${t.kind}-${idx}`)
    }
    .fontSize(13)
    .fontColor('#333333')
    .textAlign(TextAlign.Start)
    .padding({ left: 8, right: 8, top: 6, bottom: 6 })
    .layoutWeight(1)
    .wordBreak(WordBreak.BREAK_ALL)
    .copyOption(CopyOptions.LocalDevice)
  }

  build() {
    Column() {
      ForEach(parseMarkdown(this.content), (b: MarkdownBlock) => {
        if (b.kind === 'heading') {
          this.bodyText(b.inlines, this.headingSize(b.level), FontWeight.Bold, '#222222')
        } else if (b.kind === 'code') {
          Text(b.code)
            .fontSize(12)
            .fontColor('#333333')
            .wordBreak(WordBreak.BREAK_ALL)
            .backgroundColor('#f5f5f5')
            .padding(10)
            .borderRadius(6)
            .margin({ top: 4, bottom: 4 })
            .copyOption(CopyOptions.LocalDevice)
        } else if (b.kind === 'quote') {
          Row() {
            this.bodyText(b.inlines, 14, FontWeight.Normal, '#666666')
          }
          .border({ width: { left: 3 }, color: '#d0d0d0' })
          .padding({ left: 10 })
          .margin({ top: 2, bottom: 2 })
        } else if (b.kind === 'table') {
          Scroll() {
            Column() {
              // Header row
              Row() {
                ForEach(b.headers ?? [], (cell: InlineToken[]) => {
                  this.tableHeaderCell(cell)
                }, (cell: InlineToken[], idx: number) => `th-${idx}`)
              }
              .width('100%')
              .backgroundColor('#f0f0f0')
              // Data rows
              ForEach(b.rows ?? [], (row: InlineToken[][], ri: number) => {
                Row() {
                  ForEach(row, (cell: InlineToken[]) => {
                    this.tableDataCell(cell)
                  }, (cell: InlineToken[], ci: number) => `td-${ri}-${ci}`)
                }
                .width('100%')
                .border({ width: { bottom: ri === ((b.rows?.length ?? 1) - 1) ? 0 : 1 }, color: '#e8e8e8' })
              }, (row: InlineToken[][], ri: number) => `tr-${ri}`)
            }
            .width('100%')
            .constraintSize({ minWidth: this.tableMinWidth((b.headers ?? []).length) })
            .border({ width: 1, color: '#d0d0d0' })
            .borderRadius(6)
            .clip(true)
          }
          .scrollable(ScrollDirection.Horizontal)
          .scrollBar(BarState.Auto)
          .width('100%')
          .margin({ top: 4, bottom: 4 })
        } else {
          // paragraph and list (list already carries a "• " prefix)
          this.bodyText(b.inlines, 14, FontWeight.Normal, '#333333')
        }
      }, (b: MarkdownBlock, idx: number) => `${b.kind}-${idx}`)
    }
    .alignItems(HorizontalAlign.Start)
  }
}

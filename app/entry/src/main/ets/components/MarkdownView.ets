/**
 * MarkdownView: renders a Markdown string using plain ArkUI Text/Span — no
 * third-party library. Used to show assistant answers in the transcript.
 */
import { InlineToken, MarkdownBlock, parseMarkdown } from '../model/Markdown';

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
        } else if (b.kind === 'quote') {
          Row() {
            this.bodyText(b.inlines, 14, FontWeight.Normal, '#666666')
          }
          .border({ width: { left: 3 }, color: '#d0d0d0' })
          .padding({ left: 10 })
          .margin({ top: 2, bottom: 2 })
        } else {
          // paragraph and list (list already carries a "• " prefix)
          this.bodyText(b.inlines, 14, FontWeight.Normal, '#333333')
        }
      }, (b: MarkdownBlock, idx: number) => `${b.kind}-${idx}`)
    }
    .alignItems(HorizontalAlign.Start)
  }
}

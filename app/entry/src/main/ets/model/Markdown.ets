/**
 * Minimal Markdown parser for the transcript view. It handles the subset DSH
 * answers actually use — headings, fenced code blocks, unordered/ordered lists,
 * block quotes, and inline bold / italic / `code` / [link](url) — without any
 * third-party dependency. Everything else degrades to plain paragraph text.
 */

/** One inline run inside a paragraph/heading/list/quote. */
export interface InlineToken {
  kind: string; // 'text' | 'bold' | 'italic' | 'code' | 'link'
  text: string;
  url: string;
}

/** One block-level element of a rendered document. */
export interface MarkdownBlock {
  kind: string; // 'heading' | 'paragraph' | 'code' | 'list' | 'quote'
  level: number; // heading level (1-6), 0 otherwise
  inlines: InlineToken[];
  code: string; // fenced code block content
}

function pushToken(tokens: InlineToken[], kind: string, text: string, url: string): void {
  tokens.push({ kind: kind, text: text, url: url });
}

/** Parse [text](url) links in a plain run of text. */
function parseLinks(text: string): InlineToken[] {
  const tokens: InlineToken[] = [];
  const re = /\[([^\]]+)\]\(([^)]+)\)/g;
  let last = 0;
  let m = re.exec(text);
  while (m !== null) {
    if (m.index > last) {
      pushToken(tokens, 'text', text.substring(last, m.index), '');
    }
    pushToken(tokens, 'link', m[1], m[2]);
    last = m.index + m[0].length;
    m = re.exec(text);
  }
  if (last < text.length) {
    pushToken(tokens, 'text', text.substring(last), '');
  }
  return tokens;
}

/** Parse *italic* runs (after bold/code have been consumed). */
function parseItalic(text: string): InlineToken[] {
  const parts = text.split('*');
  const tokens: InlineToken[] = [];
  for (let i = 0; i < parts.length; i++) {
    if (i % 2 === 1) {
      pushToken(tokens, 'italic', parts[i], '');
    } else {
      const sub = parseLinks(parts[i]);
      for (const t of sub) {
        tokens.push(t);
      }
    }
  }
  return tokens;
}

/** Parse **bold** runs (after code spans have been consumed). */
function parseBold(text: string): InlineToken[] {
  const parts = text.split('**');
  const tokens: InlineToken[] = [];
  for (let i = 0; i < parts.length; i++) {
    if (i % 2 === 1) {
      pushToken(tokens, 'bold', parts[i], '');
    } else {
      const sub = parseItalic(parts[i]);
      for (const t of sub) {
        tokens.push(t);
      }
    }
  }
  return tokens;
}

/** Split off `code` spans, then parse bold/italic/links in the rest. */
function parseInline(text: string): InlineToken[] {
  const parts = text.split('`');
  const tokens: InlineToken[] = [];
  for (let i = 0; i < parts.length; i++) {
    if (i % 2 === 1) {
      pushToken(tokens, 'code', parts[i], '');
    } else {
      const sub = parseBold(parts[i]);
      for (const t of sub) {
        tokens.push(t);
      }
    }
  }
  return tokens;
}

function block(kind: string): MarkdownBlock {
  return { kind: kind, level: 0, inlines: [], code: '' };
}

/** Parse a Markdown string into block-level elements for the view. */
export function parseMarkdown(src: string): MarkdownBlock[] {
  const blocks: MarkdownBlock[] = [];
  const lines = src.split('\n');
  let i = 0;
  while (i < lines.length) {
    const line = lines[i];
    const trimmed = line.trim();

    // Fenced code block
    if (trimmed.startsWith('```')) {
      let code = '';
      i++;
      while (i < lines.length && !lines[i].trim().startsWith('```')) {
        code += (code.length > 0 ? '\n' : '') + lines[i];
        i++;
      }
      i++; // closing fence
      const b = block('code');
      b.code = code;
      blocks.push(b);
      continue;
    }

    // ATX heading
    const heading = /^(#{1,6})\s+(.*)$/.exec(trimmed);
    if (heading !== null) {
      const b = block('heading');
      b.level = heading[1].length;
      b.inlines = parseInline(heading[2]);
      blocks.push(b);
      i++;
      continue;
    }

    // Block quote
    if (trimmed.startsWith('>')) {
      const b = block('quote');
      b.inlines = parseInline(trimmed.replace(/^>\s?/, ''));
      blocks.push(b);
      i++;
      continue;
    }

    // List item (unordered or ordered)
    if (/^[-*+]\s+/.test(trimmed) || /^\d+\.\s+/.test(trimmed)) {
      const b = block('list');
      b.inlines = [];
      b.inlines.push({ kind: 'text', text: '•  ', url: '' });
      const sub = parseInline(trimmed.replace(/^([-*+]|\d+\.)\s+/, ''));
      for (const t of sub) {
        b.inlines.push(t);
      }
      blocks.push(b);
      i++;
      continue;
    }

    // Blank line -> nothing (spacing comes from the view)
    if (trimmed.length === 0) {
      i++;
      continue;
    }

    // Plain paragraph
    const b = block('paragraph');
    b.inlines = parseInline(trimmed);
    blocks.push(b);
    i++;
  }
  return blocks;
}

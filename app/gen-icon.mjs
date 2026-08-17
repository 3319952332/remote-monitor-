// One-off generator: writes a branded "DSH" app icon (RGBA PNG) for the
// HarmonyOS app, replacing the file-manager sample icon that shipped with the
// AITest skeleton. Run with: node gen-icon.mjs
import { deflateSync } from 'node:zlib';
import { writeFileSync } from 'node:fs';

const SIZE = 512;

// 5x7 bitmap font for D / S / H
const GLYPHS = {
  D: ['11110', '10001', '10001', '10001', '10001', '10001', '11110'],
  S: ['01111', '10000', '10000', '01110', '00001', '00001', '11110'],
  H: ['10001', '10001', '10001', '11111', '10001', '10001', '10001'],
};

function crc32(buf) {
  let table = crc32.table;
  if (!table) {
    table = crc32.table = new Int32Array(256);
    for (let n = 0; n < 256; n++) {
      let c = n;
      for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
      table[n] = c;
    }
  }
  let crc = -1;
  for (let i = 0; i < buf.length; i++) crc = (crc >>> 8) ^ table[(crc ^ buf[i]) & 0xff];
  return (crc ^ -1) >>> 0;
}

function chunk(type, data) {
  const len = Buffer.alloc(4);
  len.writeUInt32BE(data.length, 0);
  const typeBuf = Buffer.from(type, 'ascii');
  const crcBuf = Buffer.alloc(4);
  crcBuf.writeUInt32BE(crc32(Buffer.concat([typeBuf, data])), 0);
  return Buffer.concat([len, typeBuf, data, crcBuf]);
}

function encodePng(rgba, width, height) {
  const sig = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(width, 0);
  ihdr.writeUInt32BE(height, 4);
  ihdr[8] = 8; // bit depth
  ihdr[9] = 6; // color type RGBA
  // scanlines with filter byte 0
  const raw = Buffer.alloc((width * 4 + 1) * height);
  for (let y = 0; y < height; y++) {
    raw[y * (width * 4 + 1)] = 0;
    rgba.copy(raw, y * (width * 4 + 1) + 1, y * width * 4, (y + 1) * width * 4);
  }
  return Buffer.concat([
    sig,
    chunk('IHDR', ihdr),
    chunk('IDAT', deflateSync(raw, { level: 9 })),
    chunk('IEND', Buffer.alloc(0)),
  ]);
}

// Build RGBA buffer with a blue diagonal-ish gradient + white "DSH" text.
const px = Buffer.alloc(SIZE * SIZE * 4);
const c1 = [11, 68, 173]; // deep blue
const c2 = [33, 126, 255]; // lighter blue
for (let y = 0; y < SIZE; y++) {
  for (let x = 0; x < SIZE; x++) {
    const t = (x + y) / (2 * (SIZE - 1));
    const r = Math.round(c1[0] + (c2[0] - c1[0]) * t);
    const g = Math.round(c1[1] + (c2[1] - c1[1]) * t);
    const b = Math.round(c1[2] + (c2[2] - c1[2]) * t);
    const i = (y * SIZE + x) * 4;
    px[i] = r;
    px[i + 1] = g;
    px[i + 2] = b;
    px[i + 3] = 255;
  }
}

// Draw "DSH" centered, 5x7 font scaled up.
const text = 'DSH';
const cols = text.length * 5 + (text.length - 1) * 1; // 5 + gap between letters
const scale = Math.floor((SIZE * 0.62) / cols);
const glyphW = cols * scale;
const glyphH = 7 * scale;
const ox = Math.floor((SIZE - glyphW) / 2);
const oy = Math.floor((SIZE - glyphH) / 2);

for (let gi = 0; gi < text.length; gi++) {
  const glyph = GLYPHS[text[gi]];
  for (let row = 0; row < 7; row++) {
    for (let col = 0; col < 5; col++) {
      if (glyph[row][col] === '1') {
        const baseX = ox + (gi * 6) * scale + col * scale;
        const baseY = oy + row * scale;
        for (let dy = 0; dy < scale; dy++) {
          for (let dx = 0; dx < scale; dx++) {
            const x = baseX + dx;
            const y = baseY + dy;
            if (x < 0 || x >= SIZE || y < 0 || y >= SIZE) continue;
            const i = (y * SIZE + x) * 4;
            px[i] = 255;
            px[i + 1] = 255;
            px[i + 2] = 255;
            px[i + 3] = 255;
          }
        }
      }
    }
  }
}

const png = encodePng(px, SIZE, SIZE);
writeFileSync(new URL('./AppScope/resources/base/media/app_icon.png', import.meta.url), png);
writeFileSync(new URL('./entry/src/main/resources/base/media/icon.png', import.meta.url), png);
console.log(`wrote ${png.length} bytes to app_icon.png and icon.png (${SIZE}x${SIZE})`);

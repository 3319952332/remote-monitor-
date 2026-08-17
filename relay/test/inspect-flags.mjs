// Check local file header flags + version fields for zip4j-incompatible features.
import { readFileSync } from "node:fs";

const buf = readFileSync(process.argv[2]);

function findEOCD(b) {
  for (let i = b.length - 22; i >= 0; i--) {
    if (b[i]===0x50 && b[i+1]===0x4b && b[i+2]===0x05 && b[i+3]===0x06) return i;
  }
  return -1;
}
const eocd = findEOCD(buf);
const cdCount = buf.readUInt16LE(eocd + 10);
const cdOffset = buf.readUInt32LE(eocd + 16);

let p = cdOffset;
for (let i = 0; i < cdCount; i++) {
  const sig = buf.readUInt32LE(p);
  const verNeeded = buf.readUInt16LE(p + 6);
  const flags = buf.readUInt16LE(p + 8);
  const nameLen = buf.readUInt16LE(p + 28);
  const extraLen = buf.readUInt16LE(p + 30);
  const commentLen = buf.readUInt16LE(p + 32);
  const localOffset = buf.readUInt32LE(p + 42);
  const name = buf.toString("utf8", p + 46, p + 46 + nameLen);

  // local header at localOffset: sig(4) + ver(2) + flags(2)
  const lsig = buf.readUInt32LE(localOffset);
  const lflags = buf.readUInt16LE(localOffset + 6);

  console.log(
    `[${i}] ${name}` +
    ` verNeeded=${verNeeded} cdFlags=0x${flags.toString(16)}` +
    ` localFlags=0x${lflags.toString(16)}` +
    ` (bit3-datadesc=${(lflags & 0x08) !== 0} bit11-utf8=${(lflags & 0x800) !== 0} bit0-encrypted=${(lflags & 0x01) !== 0})`
  );
  p += 46 + nameLen + extraLen + commentLen;
}

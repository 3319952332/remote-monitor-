// Dump central directory raw fields (size/offset) to catch 0xFFFFFFFF zip64 magic.
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
  const nameLen = buf.readUInt16LE(p + 28);
  const extraLen = buf.readUInt16LE(p + 30);
  const commentLen = buf.readUInt16LE(p + 32);
  const compSize = buf.readUInt32LE(p + 20);
  const uncompSize = buf.readUInt32LE(p + 24);
  const localOff = buf.readUInt32LE(p + 42);
  const name = buf.toString("utf8", p + 46, p + 46 + nameLen);
  console.log(
    `[${i}] ${name} comp=${compSize} uncomp=${uncompSize} localOff=${localOff}` +
    ` ${compSize===0xFFFFFFFF?'<--ZIP64_COMP!':''} ${uncompSize===0xFFFFFFFF?'<--ZIP64_UNCOMP!':''} ${localOff===0xFFFFFFFF?'<--ZIP64_OFF!':''}`
  );
  p += 46 + nameLen + extraLen + commentLen;
}

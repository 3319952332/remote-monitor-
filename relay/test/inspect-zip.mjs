// Inspect a zip's central directory entries for zip64 extra fields.
import { readFileSync } from "node:fs";

const file = process.argv[2];
const buf = readFileSync(file);

// Find End of Central Directory (EOCD): signature 0x06054b50, scan from end.
function findEOCD(b) {
  for (let i = b.length - 22; i >= 0; i--) {
    if (b[i] === 0x50 && b[i+1] === 0x4b && b[i+2] === 0x05 && b[i+3] === 0x06) {
      return i;
    }
  }
  return -1;
}

const eocd = findEOCD(buf);
if (eocd < 0) { console.log("no EOCD found"); process.exit(1); }

const cdCount = buf.readUInt16LE(eocd + 10);
const cdOffset = buf.readUInt32LE(eocd + 16);
console.log(`EOCD at ${eocd}, central dir entries=${cdCount}, cd offset=${cdOffset}`);

// Walk central directory entries.
let p = cdOffset;
for (let i = 0; i < cdCount; i++) {
  if (buf.readUInt32LE(p) !== 0x02014b50) { console.log(`  [entry ${i}] BAD signature at ${p}`); break; }
  const nameLen = buf.readUInt16LE(p + 28);
  const extraLen = buf.readUInt16LE(p + 30);
  const commentLen = buf.readUInt16LE(p + 32);
  const name = buf.toString("utf8", p + 46, p + 46 + nameLen);
  const extra = buf.subarray(p + 46 + nameLen, p + 46 + nameLen + extraLen);
  // parse extra fields: [id u16][size u16][data]
  let hasZip64 = false;
  for (let e = 0; e + 4 <= extra.length; ) {
    const id = extra.readUInt16LE(e);
    const sz = extra.readUInt16LE(e + 2);
    if (id === 0x0001) hasZip64 = true;
    e += 4 + sz;
  }
  console.log(`  [${i}] ${name} extraLen=${extraLen} zip64=${hasZip64}`);
  p += 46 + nameLen + extraLen + commentLen;
}

// One-off: generate Beacon PWA icons (blue field + white beacon core & ring).
// Dependency-free PNG encoder using Node's built-in zlib.
const fs = require("fs");
const zlib = require("zlib");
const path = require("path");

function crc32(buf) {
  let c = ~0;
  for (let i = 0; i < buf.length; i++) {
    c ^= buf[i];
    for (let k = 0; k < 8; k++) c = (c >>> 1) ^ (0xedb88320 & -(c & 1));
  }
  return (~c) >>> 0;
}
function chunk(type, data) {
  const len = Buffer.alloc(4); len.writeUInt32BE(data.length, 0);
  const body = Buffer.concat([Buffer.from(type, "ascii"), data]);
  const crc = Buffer.alloc(4); crc.writeUInt32BE(crc32(body), 0);
  return Buffer.concat([len, body, crc]);
}
function makePNG(size) {
  const cx = size / 2, cy = size / 2;
  const bg = [0x25, 0x63, 0xeb];                 // brand blue
  const core = size * 0.135;                      // white center dot
  const ringI = size * 0.225, ringO = size * 0.30; // white ring (within maskable safe zone)
  const raw = Buffer.alloc(size * (size * 4 + 1));
  let p = 0;
  for (let y = 0; y < size; y++) {
    raw[p++] = 0; // filter: none
    for (let x = 0; x < size; x++) {
      const dx = x - cx + 0.5, dy = y - cy + 0.5;
      const d = Math.sqrt(dx * dx + dy * dy);
      let r, g, b;
      if (d <= core) { r = g = b = 255; }
      else if (d >= ringI && d <= ringO) { r = g = b = 255; }
      else { [r, g, b] = bg; }
      raw[p++] = r; raw[p++] = g; raw[p++] = b; raw[p++] = 255;
    }
  }
  const sig = Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]);
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(size, 0); ihdr.writeUInt32BE(size, 4);
  ihdr[8] = 8; ihdr[9] = 6; // 8-bit, RGBA
  const idat = zlib.deflateSync(raw, { level: 9 });
  return Buffer.concat([sig, chunk("IHDR", ihdr), chunk("IDAT", idat), chunk("IEND", Buffer.alloc(0))]);
}
const root = path.join(__dirname, "..");
for (const s of [192, 512, 180]) {
  const f = path.join(root, `icon-${s}.png`);
  fs.writeFileSync(f, makePNG(s));
  console.log("wrote", `icon-${s}.png`, fs.statSync(f).size, "bytes");
}

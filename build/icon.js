import { readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const source = join(root, 'src', 'renderer', 'assets', 'appIcon512.png');
const output = join(root, 'src', 'renderer', 'assets', 'appIcon.icns');

function buildIcns(png) {
  const entries = [['ic09', png]];
  let total = 8;
  for (const [, data] of entries) total += 8 + data.length;
  const buffer = Buffer.alloc(total);
  buffer.write('icns', 0, 'ascii');
  buffer.writeUInt32BE(total, 4);
  let offset = 8;
  for (const [type, data] of entries) {
    buffer.write(type, offset, 'ascii');
    buffer.writeUInt32BE(8 + data.length, offset + 4);
    data.copy(buffer, offset + 8);
    offset += 8 + data.length;
  }
  return buffer;
}

function main() {
  const png = readFileSync(source);
  if (png.length < 24 || png.readUInt32BE(16) !== 512 || png.readUInt32BE(20) !== 512) {
    throw new Error('appIcon512.png 不是 512×512 PNG，无法生成 icns');
  }
  const icns = buildIcns(png);
  writeFileSync(output, icns);
  console.log(`appIcon.icns 已生成 ${icns.length} 字节`);
}

main();

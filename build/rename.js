import { existsSync, renameSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const source = join(root, 'dist', 'preload', 'bridge.js');
const target = join(root, 'dist', 'preload', 'bridge.mjs');

if (existsSync(source)) renameSync(source, target);
if (!existsSync(target)) {
  console.error('预加载产物缺失：dist/preload/bridge.mjs');
  process.exitCode = 1;
}

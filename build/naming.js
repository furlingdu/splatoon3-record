import { readdirSync } from 'node:fs';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(fileURLToPath(new URL('.', import.meta.url)), '..');
const skip = new Set(['node_modules', 'dist', 'release', 'bin', 'assets']);
const folders = ['src', 'tests', 'build'];
const invalid = [];

function isCamelName(name) {
  return name.split('.').every((part) => /^[a-z][A-Za-z0-9]*$/.test(part));
}

function scan(folder) {
  for (const entry of readdirSync(join(root, folder), { withFileTypes: true })) {
    const path = join(folder, entry.name);
    if (entry.isDirectory()) {
      if (!skip.has(entry.name)) scan(path);
    } else if (entry.name === 'installer.nsh') {
      continue;
    } else if (!isCamelName(entry.name)) {
      invalid.push(path);
    }
  }
}

for (const folder of folders) scan(folder);
if (invalid.length) {
  console.error(`发现不符合命名规则的文件名：\n${invalid.join('\n')}`);
  process.exitCode = 1;
}

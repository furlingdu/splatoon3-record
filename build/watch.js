import { spawn } from 'node:child_process';
import { existsSync, readdirSync, renameSync, statSync } from 'node:fs';
import { createRequire } from 'node:module';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const electronPath = createRequire(import.meta.url)('electron');

spawn('npx', ['tsc', '-p', 'tsconfig.electron.json', '--watch'], { shell: true, stdio: 'inherit' });
setInterval(() => {
  try { renameSync(join(root, 'dist/preload/bridge.js'), join(root, 'dist/preload/bridge.mjs')); } catch { void 0; }
}, 1000);

let child;
let restarting = false;
let lastStamp = 0;

function dirStamp(dir) {
  let max = 0;
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const full = join(dir, entry.name);
    const stamp = entry.isDirectory() ? dirStamp(full) : statSync(full).mtimeMs;
    if (stamp > max) max = stamp;
  }
  return max;
}

async function waitReady() {
  for (;;) {
    let viteReady = false;
    try { viteReady = (await fetch('http://localhost:5173/')).ok; } catch { void 0; }
    if (existsSync(join(root, 'dist/main/app.js')) && existsSync(join(root, 'dist/preload/bridge.mjs')) && viteReady) return;
    await new Promise((resolve) => setTimeout(resolve, 800));
  }
}

function startElectron() {
  child = spawn(electronPath, ['.'], { cwd: root, stdio: 'inherit', env: { ...process.env, VITE_DEV_SERVER_URL: 'http://localhost:5173' } });
  child.on('exit', (code) => {
    if (restarting) { restarting = false; setTimeout(startElectron, 500); return; }
    process.exit(code ?? 0);
  });
}

function restartElectron() {
  if (restarting || !child || child.exitCode !== null) return;
  restarting = true;
  child.kill();
}

await waitReady();
startElectron();
lastStamp = dirStamp(join(root, 'dist', 'main'));
setInterval(() => {
  try {
    const stamp = dirStamp(join(root, 'dist', 'main'));
    if (stamp > lastStamp) { lastStamp = stamp; restartElectron(); }
  } catch { void 0; }
}, 1000);

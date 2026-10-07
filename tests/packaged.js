import { spawn } from 'node:child_process';
import { mkdir, mkdtemp, rm, writeFile } from 'node:fs/promises';
import { existsSync, statSync } from 'node:fs';
import { createServer } from 'node:net';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import puppeteer from 'puppeteer';

const rootDir = join(fileURLToPath(new URL('.', import.meta.url)), '..');

function findPackage() {
  const release = process.env.S3R_PACKAGE_DIR || join(rootDir, 'release');
  const layouts = {
    win32: [['win-unpacked', 'Splatoon3 Record.exe']],
    darwin: [
      ['mac-arm64', 'Splatoon3 Record.app', 'Contents', 'MacOS', 'Splatoon3 Record'],
      ['mac', 'Splatoon3 Record.app', 'Contents', 'MacOS', 'Splatoon3 Record'],
    ],
    linux: [['linux-unpacked', 'splatoon3record']],
  };
  const candidates = layouts[process.platform];
  if (!candidates) throw new Error(`不支持的平台 ${process.platform}`);
  const exe = candidates.map((parts) => join(release, ...parts)).find(existsSync);
  if (!exe) throw new Error(`缺少打包产物 ${candidates.map((parts) => join(release, ...parts)).join(' 或 ')}`);
  const resources = process.platform === 'darwin'
    ? join(exe, '..', '..', 'Resources')
    : join(exe, '..', 'resources');
  return { exe, resources };
}

function freePort() {
  return new Promise((resolve, reject) => {
    const server = createServer();
    server.on('error', reject);
    server.listen(0, '127.0.0.1', () => {
      const { port } = server.address();
      server.close(() => resolve(port));
    });
  });
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

async function waitFor(task, timeoutMs, stepMs = 400) {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    const value = await task().catch(() => undefined);
    if (value) return value;
    if (Date.now() > deadline) return undefined;
    await sleep(stepMs);
  }
}

async function main() {
  const { exe, resources } = findPackage();
  const home = await mkdtemp(join(tmpdir(), 's3recordPackaged'));
  const dataDir = join(home, '.splatoon3record');
  await mkdir(join(dataDir, 'videos'), { recursive: true });
  await mkdir(join(home, 'userData'), { recursive: true });
  await writeFile(join(dataDir, 'config.json'), JSON.stringify({
    settings: {
      videoDevice: '', audioDevice: '', width: 1280, height: 720, fps: 30, flipVertical: false,
      encoder: 'software', quality: 22, saveDir: join(dataDir, 'videos'),
      autoPush: false, autoRecord: false, autoLaunch: false, pollSeconds: 10, blurNickname: false, monitorAudio: false,
    },
    pushEnabled: false,
    setupDone: true,
    handledIds: [],
  }, null, 2), 'utf8');

  const port = await freePort();
  const child = spawn(exe, [
    `--remote-debugging-port=${port}`,
    `--user-data-dir=${join(home, 'userData')}`,
    '--mute-audio',
  ], {
    cwd: rootDir,
    env: { ...process.env, USERPROFILE: home, HOME: home, APPDATA: join(home, 'userData'), LOCALAPPDATA: join(home, 'userData') },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  const log = [];
  child.stdout.on('data', (data) => log.push(data.toString()));
  child.stderr.on('data', (data) => log.push(data.toString()));

  let browser;
  const failures = [];
  const check = (name, ok) => {
    console.log(`${ok ? 'PASS' : 'FAIL'} ${name}`);
    if (!ok) failures.push(name);
  };
  const modelFile = join(resources, 'runtime', 'models', 'spld_v2_nickname.onnx');
  const ffmpegFile = join(resources, 'bin', process.platform === 'win32' ? 'ffmpeg.exe' : 'ffmpeg');
  const nativeDir = join(resources, 'app.asar.unpacked', 'node_modules', 'onnxruntime-node', 'bin', 'napi-v6', process.platform, process.arch);
  const nativeFile = join(nativeDir, 'onnxruntime_binding.node');
  const nativeLibrary = process.platform === 'win32' ? join(nativeDir, 'onnxruntime.dll') : undefined;
  check('打包版内含 ffmpeg', existsSync(ffmpegFile));
  check('打包版内含打码模型', existsSync(modelFile) && statSync(modelFile).size > 1000000);
  check('打包版内含原生推理运行时', existsSync(nativeFile) && (!nativeLibrary || existsSync(nativeLibrary)));
  try {
    const ready = await waitFor(async () => {
      const response = await fetch(`http://127.0.0.1:${port}/json/version`).catch(() => undefined);
      return response?.ok ? true : undefined;
    }, 60000);
    check('打包应用启动并开放调试端口', Boolean(ready));
    if (!ready) throw new Error('调试端口未就绪');
    browser = await puppeteer.connect({ browserURL: `http://127.0.0.1:${port}`, defaultViewport: null });
    const page = await waitFor(async () => {
      const pages = await browser.pages();
      return pages.find((item) => item.url().includes('index.html')) ?? undefined;
    }, 30000);
    if (!page) throw new Error('未找到主窗口页面');
    await page.waitForSelector('mdui-top-app-bar', { timeout: 30000 });
    await page.evaluate(() => {
      document.querySelectorAll('mdui-navigation-drawer mdui-list-item')[6]?.dispatchEvent(new MouseEvent('click', { bubbles: true, composed: true }));
    });
    const aboutReady = await waitFor(() => page.evaluate(() => Boolean(document.querySelector('.about-avatar[alt="澪度"]'))), 10000);
    check('打包版关于页渲染作者头像', Boolean(aboutReady));

    const native = await page.evaluate(async () => {
      const width = 960;
      const height = 540;
      const canvas = document.createElement('canvas');
      canvas.width = width;
      canvas.height = height;
      const ctx = canvas.getContext('2d');
      ctx.fillStyle = '#203040';
      ctx.fillRect(0, 0, width, height);
      const image = ctx.getImageData(0, 0, width, height);
      const data = image.data;
      const buffer = data.buffer.slice(data.byteOffset, data.byteOffset + data.byteLength);
      const device = await window.recordApi.startDetect();
      const reply = await window.recordApi.detectFrame(buffer, width, height, 0.5);
      await window.recordApi.stopDetect();
      return { device, ms: Number(reply?.ms) || 0, boxes: Array.isArray(reply?.boxes) ? reply.boxes.length : -1 };
    });
    check('打包版原生推理后端可用', ['CUDA', 'HIP', 'ROCm', 'WebGPU', 'DirectML', 'CoreML', 'CPU'].includes(native.device));
    check('打包版原生推理能跑通一帧', native.ms > 0 && native.boxes >= 0);
    const ffmpeg = await page.evaluate(async () => {
      const status = await window.recordApi.getStatus();
      return { accel: status.hwAccel, encoder: status.encoder };
    });
    check('打包版探测到 ffmpeg 硬件能力', Boolean(ffmpeg.accel));
    console.log('  打包诊断', JSON.stringify({ native, ffmpeg }));
  } finally {
    if (browser) await browser.disconnect().catch(() => undefined);
    child.kill();
    await sleep(800);
    await rm(home, { recursive: true, force: true }).catch(() => undefined);
  }
  if (failures.length) {
    console.error(`打包测试失败：${failures.join('、')}`);
    console.error(log.join('').slice(-2000));
    process.exit(1);
  }
  console.log('打包测试全部通过');
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});

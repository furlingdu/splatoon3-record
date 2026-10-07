import { spawn } from 'node:child_process';
import { mkdir, mkdtemp, readFile, readdir, rm, stat, writeFile } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import { createServer } from 'node:net';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import puppeteer from 'puppeteer';
import { findChrome } from './uiMock.js';

const rootDir = join(fileURLToPath(new URL('.', import.meta.url)), '..');
const electronBin = join(rootDir, 'node_modules', 'electron', 'dist', process.platform === 'win32' ? 'electron.exe' : 'electron');
const ffmpegBin = join(rootDir, 'bin', process.platform === 'win32' ? 'ffmpeg.exe' : 'ffmpeg');
const failures = [];
const checks = [];

function check(name, condition) {
  checks.push({ name, pass: Boolean(condition) });
  if (!condition) failures.push(name);
  console.log(`${condition ? 'PASS' : 'FAIL'} ${name}`);
}

function runFFmpeg(args) {
  return new Promise((resolve) => {
    const child = spawn(ffmpegBin, args, { windowsHide: true });
    let output = '';
    child.stdout.on('data', (data) => { output += data.toString(); });
    child.stderr.on('data', (data) => { output += data.toString(); });
    child.on('error', () => resolve({ code: -1, output }));
    child.on('close', (code) => resolve({ code: code ?? -1, output }));
  });
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

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function waitFor(task, timeoutMs, stepMs = 300) {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    const value = await task().catch(() => undefined);
    if (value) return value;
    if (Date.now() > deadline) return undefined;
    await sleep(stepMs);
  }
}

async function devtoolsReady(port) {
  const response = await fetch(`http://127.0.0.1:${port}/json/version`).catch(() => undefined);
  return response?.ok ? true : undefined;
}

async function mainPage(browser) {
  const pages = await browser.pages();
  return pages.find((page) => page.url().includes('index.html') && !page.url().includes('setup='));
}

async function main() {
  if (!existsSync(join(rootDir, 'dist', 'main', 'app.js')) || !existsSync(join(rootDir, 'dist', 'renderer', 'index.html'))) {
    console.error('缺少构建产物，请先执行 npm run build');
    process.exit(1);
  }
  const home = await mkdtemp(join(tmpdir(), 's3recordCapture'));
  const dataDir = join(home, '.splatoon3record');
  const cacheDir = join(dataDir, 'cache');
  const videoDir = join(dataDir, 'videos');
  await mkdir(cacheDir, { recursive: true });
  await mkdir(videoDir, { recursive: true });
  await mkdir(join(home, 'userData'), { recursive: true });
  await writeFile(join(dataDir, 'config.json'), JSON.stringify({
    settings: {
      videoDevice: '', audioDevice: '', width: 1280, height: 720, fps: 60, flipVertical: false,
      encoder: 'software', quality: 22, saveDir: videoDir,
      autoPush: false, autoRecord: false, autoLaunch: false, blurNickname: false, monitorAudio: false, pollSeconds: 10,
    },
    pushEnabled: false,
    setupDone: true,
    handledIds: [],
  }, null, 2), 'utf8');
  const matchDir = join(dataDir, 'matches');
  await mkdir(matchDir, { recursive: true });
  const blurProbe = join(videoDir, 'blurprobe.mp4');
  const probeSource = await runFFmpeg(['-hide_banner', '-loglevel', 'error', '-y', '-f', 'lavfi', '-i', 'color=c=blue:s=320x240:r=30:d=2', '-c:v', 'libx264', '-pix_fmt', 'yuv420p', blurProbe]);
  if (probeSource.code !== 0) throw new Error('打码探针录像生成失败');
  const fakeVideo = join(home, 'fakevideo.y4m');
  const fakeSource = await runFFmpeg(['-hide_banner', '-loglevel', 'error', '-y', '-f', 'lavfi', '-i', 'testsrc2=size=1280x720:rate=60,noise=alls=45:allf=t+u', '-t', '3', '-pix_fmt', 'yuv420p', '-f', 'yuv4mpegpipe', fakeVideo]);
  if (fakeSource.code !== 0) throw new Error('高细节采集源生成失败');
  await writeFile(join(matchDir, 'blurprobe.json'), JSON.stringify({
    matchId: 'blurprobe', kind: 'regular', mode: 'regular', rule: 'TURF_WAR', startAt: Date.now() - 20000, endAt: Date.now(),
    duration: 20, result: 'WIN', isDisconnected: false, isSalmon: false, videoPath: blurProbe, rawData: {},
  }, null, 2), 'utf8');

  const port = await freePort();
  const livePort = await freePort();
  const child = spawn(electronBin, [
    rootDir,
    `--remote-debugging-port=${port}`,
    `--user-data-dir=${join(home, 'userData')}`,
    '--use-fake-device-for-media-stream',
    '--use-fake-ui-for-media-stream',
    '--mute-audio',
    `--use-file-for-fake-video-capture=${fakeVideo}`,
  ], {
    cwd: rootDir,
    env: {
      ...process.env,
      USERPROFILE: home,
      HOME: home,
      APPDATA: join(home, 'userData'),
      LOCALAPPDATA: join(home, 'userData'),
      LIVE_PORT: String(livePort),
    },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  const appLog = [];
  child.stdout.on('data', (data) => appLog.push(data.toString()));
  child.stderr.on('data', (data) => appLog.push(data.toString()));

  let browser;
  try {
    check('应用进程启动并开放调试端口', Boolean(await waitFor(() => devtoolsReady(port), 40000)));
    browser = await puppeteer.connect({ browserURL: `http://127.0.0.1:${port}`, defaultViewport: null });
    const page = await waitFor(() => mainPage(browser), 20000);
    if (!page) throw new Error('未找到主窗口页面');
    await page.waitForSelector('mdui-top-app-bar', { timeout: 30000 });
    check('主窗口渲染状态页', await page.evaluate(() => document.body.innerText.includes('状态')));

    const devices = await page.evaluate(async () => {
      const list = await navigator.mediaDevices.enumerateDevices();
      return list.filter((item) => item.kind === 'videoinput' || item.kind === 'audioinput').map((item) => ({ id: item.deviceId, kind: item.kind, label: item.label }));
    });
    const video = devices.find((item) => item.kind === 'videoinput');
    const audio = devices.find((item) => item.kind === 'audioinput');
    check('枚举到虚拟采集设备', Boolean(video?.id));
    check('枚举到虚拟音频设备', Boolean(audio?.id));
    if (!video) throw new Error('虚拟摄像头不可用');

    const saved = await page.evaluate(async (videoId, audioId) => {
      const status = await window.recordApi.getStatus();
      return window.recordApi.saveSettings({ ...status.settings, videoDevice: videoId, audioDevice: audioId });
    }, video.id, audio?.id || '');
    check('保存采集设备设置', saved.settings.videoDevice === video.id);
    check('采集画面接入预览', await page.waitForFunction(() => document.querySelector('.preview-video')?.srcObject instanceof MediaStream, { timeout: 20000 }).then(() => true).catch(() => false));

    const live = await waitFor(async () => {
      const status = await page.evaluate(() => window.recordApi.getStatus());
      return status.streamWidth > 0 ? status : undefined;
    }, 20000);
    check('主进程收到采集规格上报', Boolean(live) && live.streamWidth > 0 && live.streamHeight > 0);
    check('采集格式来自浏览器录制编码', Boolean(live?.streamFormat) && /video\//.test(live.streamFormat) && live.streamAudio === true);

    const previewPlaying = await page.waitForFunction(() => {
      const video = document.querySelector('.preview-video');
      return Boolean(video) && video.readyState >= 2 && !video.paused && video.videoWidth > 0;
    }, { timeout: 20000 }).then(() => true).catch(() => false);
    check('采集画面开始播放', previewPlaying);

    const pipPoint = await page.evaluate(() => {
      const rect = document.querySelector('.preview-box')?.getBoundingClientRect();
      return rect ? { x: Math.round(rect.left + rect.width / 2), y: Math.round(rect.top + rect.height / 2) } : null;
    });
    let pipEntered = false;
    if (pipPoint && previewPlaying) {
      for (let attempt = 0; attempt < 3 && !pipEntered; attempt += 1) {
        await page.mouse.move(pipPoint.x, pipPoint.y);
        await page.mouse.down({ clickCount: 1 }).catch(() => undefined);
        await page.mouse.up({ clickCount: 1 }).catch(() => undefined);
        await page.mouse.down({ clickCount: 2 }).catch(() => undefined);
        await page.mouse.up({ clickCount: 2 }).catch(() => undefined);
        pipEntered = Boolean(await waitFor(async () => {
          const entered = await page.evaluate(() => document.pictureInPictureElement === document.querySelector('.preview-video')).catch(() => false);
          return entered ? { entered } : undefined;
        }, 4000, 400));
      }
    }
    check('双击预览进入画中画窗口', pipEntered);
    if (pipEntered) {
      const pipState = await page.evaluate(() => {
        const video = document.querySelector('.preview-video');
        return { native: [video.videoWidth, video.videoHeight], playing: !video.paused && video.readyState >= 2, notice: document.querySelector('.preview-moved')?.textContent || '' };
      });
      check('画中画窗口沿用采集流原生画幅', pipState.native[0] === live.streamWidth && pipState.native[1] === live.streamHeight && pipState.playing);
      check('画中画打开时主窗口预览关闭', pipState.notice.includes('画面已转移到画中画窗口'));
      await page.evaluate(() => document.exitPictureInPicture()).catch(() => undefined);
      check('退出画中画后主窗口恢复预览', await page.waitForFunction(() => !document.pictureInPictureElement && !document.querySelector('.preview-moved'), { timeout: 8000 }).then(() => true).catch(() => false));
    }

    await page.evaluate(() => {
      const media = navigator.mediaDevices;
      const original = media.getUserMedia.bind(media);
      window.__captureGetUserMediaCalls = 0;
      media.getUserMedia = (...constraints) => {
        window.__captureGetUserMediaCalls += 1;
        return original(...constraints);
      };
    });
    const previewTargetPromise = browser.waitForTarget((target) => target.type() === 'page' && target.opener() === page.target() && target.url().includes('preview=1'), { timeout: 15000 }).catch(() => undefined);
    await page.evaluate(() => {
      const button = Array.from(document.querySelectorAll('.status-actions mdui-button')).find((element) => element.textContent?.includes('打开预览窗口'));
      button?.click();
    });
    const previewTarget = await previewTargetPromise;
    const previewPage = await previewTarget?.page();
    check('状态页按钮打开独立预览窗口', Boolean(previewPage));
    try {
      if (previewPage) {
        const previewReady = await previewPage.waitForFunction(() => {
          const video = document.querySelector('#root > video');
          return video?.srcObject instanceof MediaStream && video.readyState >= 2 && !video.paused && video.videoWidth > 0;
        }, { timeout: 20000 }).then(() => true).catch(() => false);
        check('独立预览窗口标题为预览窗口', await previewPage.title() === '预览窗口');
        check('独立预览窗口仅显示视频而无启动层和导航', await previewPage.evaluate(() =>
          document.querySelectorAll('video').length === 1 && document.querySelector('#root > video') !== null
          && !document.querySelector('#boot, mdui-top-app-bar, mdui-navigation-drawer') && !document.body.innerText.trim()));
        const previewSize = await previewPage.evaluate(() => {
          const video = document.querySelector('#root > video');
          return [video?.videoWidth, video?.videoHeight];
        });
        check('独立预览窗口沿用采集流原生画幅', previewReady && previewSize[0] === live.streamWidth && previewSize[1] === live.streamHeight);

        await previewPage.evaluateOnNewDocument(() => {
          const media = navigator.mediaDevices;
          const original = media.getUserMedia.bind(media);
          window.__captureGetUserMediaCalls = 0;
          media.getUserMedia = (...constraints) => {
            window.__captureGetUserMediaCalls += 1;
            return original(...constraints);
          };
        });
        await previewPage.reload({ waitUntil: 'domcontentloaded' });
        const reloaded = await previewPage.waitForFunction(() => {
          const video = document.querySelector('#root > video');
          return typeof window.__captureGetUserMediaCalls === 'number' && video?.srcObject instanceof MediaStream && video.readyState >= 2 && !video.paused;
        }, { timeout: 20000 }).then(() => true).catch(() => false);
        check('独立预览复用采集流而不再次请求采集设备', reloaded && await previewPage.evaluate(() => window.__captureGetUserMediaCalls === 0) && await page.evaluate(() => window.__captureGetUserMediaCalls === 0));
      }
    } finally {
      await previewPage?.close().catch(() => undefined);
    }
    check('关闭独立预览后主窗口继续使用原采集流', Boolean(previewPage) && Boolean(await waitFor(async () => {
      if (browser.targets().includes(previewTarget)) return undefined;
      return page.evaluate(() => {
        const video = document.querySelector('.preview-video');
        return video?.srcObject instanceof MediaStream && video.srcObject.getVideoTracks()[0]?.readyState === 'live'
          && video.videoWidth > 0 && !video.paused;
      });
    }, 8000)));

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
    check('主进程原生推理后端可用', ['CUDA', 'HIP', 'ROCm', 'WebGPU', 'DirectML', 'CoreML', 'CPU'].includes(native.device));
    check('主进程原生推理能跑通一帧', native.ms > 0 && native.boxes >= 0);

    const blurSource = await page.evaluate(async (matchId) => {
      const url = await window.recordApi.getVideoUrl(matchId);
      if (!url) return { ok: false, reason: '未返回录像地址' };
      return new Promise((resolve) => {
        const video = document.createElement('video');
        video.crossOrigin = 'anonymous';
        video.muted = true;
        video.src = url;
        const timer = setTimeout(() => {
          video.remove();
          resolve({ ok: false, reason: '加载超时' });
        }, 10000);
        video.addEventListener('loadedmetadata', () => {
          clearTimeout(timer);
          const tracks = (() => {
            try {
              const canvas = document.createElement('canvas');
              canvas.width = 32;
              canvas.height = 32;
              canvas.getContext('2d').drawImage(video, 0, 0, 32, 32);
              const stream = canvas.captureStream(5);
              const count = stream.getTracks().length;
              stream.getTracks().forEach((track) => track.stop());
              return count;
            } catch {
              return 0;
            }
          })();
          video.remove();
          resolve({ ok: tracks > 0, reason: tracks > 0 ? 'ok' : '画布被污染' });
        });
        video.addEventListener('error', () => {
          clearTimeout(timer);
          video.remove();
          resolve({ ok: false, reason: `媒体错误 ${video.error?.code ?? -1}` });
        });
        document.body.appendChild(video);
      });
    }, 'blurprobe');
    check('相册打码读取归档画面时画布保持干净', blurSource.ok === true);

    await page.evaluate(() => {
      const item = document.querySelectorAll('mdui-navigation-drawer mdui-list-item')[4];
      item?.dispatchEvent(new MouseEvent('click', { bubbles: true, composed: true }));
    });
    const canvasWidth = live.streamWidth;
    const canvasHeight = live.streamHeight;
    const canvasFits = await page.waitForFunction((width, height) => {
      const canvas = document.querySelector('.live-stage .live-canvas');
      const video = document.querySelector('.live-pane .preview-video');
      return Boolean(canvas && video) && video.videoWidth === width && video.videoHeight === height && canvas.width === width && canvas.height === height;
    }, { timeout: 15000 }, canvasWidth, canvasHeight).then(() => true).catch(() => false);
    check('直播页渲染打码后的推流画面', canvasFits);
    check('直播画布沿用采集流原生画幅', canvasFits && await page.evaluate(() => {
      const canvas = document.querySelector('.live-stage .live-canvas');
      const video = document.querySelector('.live-pane .preview-video');
      return canvas.width === video.videoWidth && canvas.height === video.videoHeight;
    }));
    await page.evaluate(() => {
      const element = document.querySelector('mdui-switch[name="blurNickname"]');
      if (!element) return;
      element.checked = true;
      element.dispatchEvent(new Event('change', { bubbles: true, composed: true }));
    });
    check('未开播但停在直播页时开启打码会加载推理模型', await page.waitForFunction(() => {
      const row = Array.from(document.querySelectorAll('.status-row')).find((item) => item.querySelector('.status-label')?.textContent === '推理设备');
      const value = (row?.querySelector('.status-value')?.textContent || '').trim();
      return ['CUDA', 'HIP', 'ROCm', 'WebGPU', 'DirectML', 'CoreML', 'CPU'].includes(value);
    }, { timeout: 120000 }).then(() => true).catch(() => false));
    await page.evaluate(() => {
      document.querySelectorAll('mdui-navigation-drawer mdui-list-item')[0]?.dispatchEvent(new MouseEvent('click', { bubbles: true, composed: true }));
    });
    await page.waitForFunction(() => document.querySelector('.page-title')?.textContent === '状态', { timeout: 8000 }).catch(() => undefined);
    check('未开播时离开直播页会停止出画与推理', await page.waitForFunction(() => document.querySelector('.live-canvas') === null, { timeout: 8000 }).then(() => true).catch(() => false));
    await page.evaluate(() => {
      document.querySelectorAll('mdui-navigation-drawer mdui-list-item')[4]?.dispatchEvent(new MouseEvent('click', { bubbles: true, composed: true }));
    });
    await page.waitForFunction(() => document.querySelector('.page-title')?.textContent === '直播', { timeout: 8000 }).catch(() => undefined);
    check('回到直播页后重新出画并加载推理', await page.waitForFunction(() => {
      const canvas = document.querySelector('.live-stage .live-canvas');
      const row = Array.from(document.querySelectorAll('.status-row')).find((item) => item.querySelector('.status-label')?.textContent === '推理设备');
      const value = (row?.querySelector('.status-value')?.textContent || '').trim();
      return Boolean(canvas) && ['CUDA', 'HIP', 'ROCm', 'WebGPU', 'DirectML', 'CoreML', 'CPU'].includes(value);
    }, { timeout: 120000 }).then(() => true).catch(() => false));
    await page.evaluate(() => {
      const element = document.querySelector('mdui-switch[name="blurNickname"]');
      if (!element) return;
      element.checked = false;
      element.dispatchEvent(new Event('change', { bubbles: true, composed: true }));
    });
    check('直播页未开播时显示本机观看地址', await page.evaluate((livePort) => Array.from(document.querySelectorAll('.live-address')).some((item) => (item.textContent || '').trim() === `http://localhost:${livePort}/`), livePort));
    check('直播页不显示监听地址', await page.evaluate(() => !document.body.innerText.includes('监听地址')));
    await page.evaluate(() => {
      const button = Array.from(document.querySelectorAll('.status-actions mdui-button')).find((element) => element.textContent?.includes('开始直播'));
      button?.dispatchEvent(new MouseEvent('click', { bubbles: true, composed: true }));
    });
    const started = await waitFor(async () => {
      const status = await page.evaluate(() => window.recordApi.getStatus());
      return status.liveState === 'live' ? status : undefined;
    }, 30000);
    check('直播页开始直播后主进程进入直播状态', Boolean(started));
    check('开播但未开启打码时不加载推理模型', await page.evaluate(() => {
      const row = Array.from(document.querySelectorAll('.status-row')).find((item) => item.querySelector('.status-label')?.textContent === '推理设备');
      const value = (row?.querySelector('.status-value')?.textContent || '').trim();
      return value === '未开启打码';
    }));
    const liveStatus = await waitFor(async () => {
      const status = await fetch(`http://127.0.0.1:${livePort}/status`).then((item) => item.json()).catch(() => undefined);
      return status?.live ? status : undefined;
    }, 30000);
    check('本机网页服务返回直播状态', Boolean(liveStatus));
    const viewer = await puppeteer.launch({
      headless: true,
      executablePath: await findChrome(),
      args: ['--no-first-run', '--disable-extensions', '--autoplay-policy=no-user-gesture-required', '--mute-audio'],
    });
    try {
      const viewerPage = await viewer.newPage();
      await viewerPage.goto(`http://127.0.0.1:${livePort}/`, { waitUntil: 'domcontentloaded' });
      const playing = await viewerPage.waitForFunction(() => {
        const stats = window.__liveStats;
        return Boolean(stats) && stats.video > 0 && stats.width > 0 && stats.audio > 0;
      }, { timeout: 40000 }).then(() => true).catch(() => false);
      check('本机网页直接播放直播画面', playing);
      const shape = await viewerPage.evaluate(() => {
        const stats = window.__liveStats;
        return { width: stats.width, height: stats.height, audio: stats.audio, rtc: document.documentElement.innerHTML.includes('RTCPeerConnection'), text: document.body.innerText.replace(/\s/g, '') };
      });
      check('网页直播沿用采集原始画幅', shape.width === live.streamWidth && shape.height === live.streamHeight);
      check('网页直播走本机服务拉流且未静音', shape.rtc === false && shape.audio > 0);
      check('网页直播不叠加任何文字信息', shape.text === '');
      await page.evaluate(() => {
        const element = document.querySelector('mdui-switch[name="blurNickname"]');
        if (!element) return;
        element.checked = true;
        element.dispatchEvent(new Event('change', { bubbles: true, composed: true }));
      });
      const liveBlurEnabled = await page.waitForFunction(() => {
        const row = Array.from(document.querySelectorAll('.status-row')).find((item) => item.querySelector('.status-label')?.textContent === '直播状态');
        const state = (row?.querySelector('.status-value')?.textContent || '').trim();
        const target = Array.from(document.querySelectorAll('.status-row')).find((item) => item.querySelector('.status-label')?.textContent === '打码目标');
        const boxText = (target?.querySelector('.status-value')?.textContent || '').trim();
        return state === '直播中' && /^\d+ 个$/.test(boxText);
      }, { timeout: 10000 }).then(() => true).catch(() => false);
      check('直播过程中开启昵称打码实时生效且保持直播中', liveBlurEnabled);
      check('开启打码后模型加载并报告推理设备', await page.waitForFunction(() => {
        const row = Array.from(document.querySelectorAll('.status-row')).find((item) => item.querySelector('.status-label')?.textContent === '推理设备');
        const value = (row?.querySelector('.status-value')?.textContent || '').trim();
        return ['CUDA', 'HIP', 'ROCm', 'WebGPU', 'DirectML', 'CoreML', 'CPU'].includes(value);
      }, { timeout: 120000 }).then(() => true).catch(() => false));
      check('直播过程中开启昵称打码未出现打码错误', await page.evaluate(() => !Array.from(document.querySelectorAll('.status-row')).some((item) => item.querySelector('.status-label')?.textContent === '打码错误')));
      check('开启打码后画面按推理结果出帧', await page.waitForFunction(() => {
        const row = Array.from(document.querySelectorAll('.status-row')).find((item) => item.querySelector('.status-label')?.textContent === '画面帧率');
        const rate = Number.parseFloat((row?.querySelector('.status-value')?.textContent || '').trim()) || 0;
        const infer = Array.from(document.querySelectorAll('.status-row')).find((item) => item.querySelector('.status-label')?.textContent === '推理帧率');
        const inferRate = Number.parseFloat((infer?.querySelector('.status-value')?.textContent || '').trim()) || 0;
        return rate > 0 && inferRate > 0;
      }, { timeout: 30000 }).then(() => true).catch(() => false));
      const blurFlow = await viewerPage.evaluate(() => new Promise((done) => {
        const stats = window.__liveStats;
        const start = stats.video;
        setTimeout(() => done(stats.video - start), 3000);
      }));
      check('开启打码后网页持续收到推迟出画的画面', blurFlow > 0);
      const blurFps = await viewerPage.evaluate(() => new Promise((done) => {
        const stats = window.__liveStats;
        const start = stats.video;
        const at = performance.now();
        setTimeout(() => done((stats.video - start) / ((performance.now() - at) / 1000)), 3000);
      }));
      check('开启打码后直播输出满载设定帧率', blurFps >= 24);
      await page.evaluate(() => {
        const element = document.querySelector('mdui-switch[name="blurNickname"]');
        if (!element) return;
        element.checked = false;
        element.dispatchEvent(new Event('change', { bubbles: true, composed: true }));
      });
      const liveBlurDisabled = await page.waitForFunction(() => {
        const row = Array.from(document.querySelectorAll('.status-row')).find((item) => item.querySelector('.status-label')?.textContent === '直播状态');
        const state = (row?.querySelector('.status-value')?.textContent || '').trim();
        const target = Array.from(document.querySelectorAll('.status-row')).find((item) => item.querySelector('.status-label')?.textContent === '打码目标');
        const boxText = (target?.querySelector('.status-value')?.textContent || '').trim();
        return state === '直播中' && boxText === '未开启';
      }, { timeout: 10000 }).then(() => true).catch(() => false);
      check('直播过程中关闭打码实时生效且未中断直播', liveBlurDisabled);
      check('关闭打码后不残留打码错误', await page.evaluate(() => !Array.from(document.querySelectorAll('.status-row')).some((item) => item.querySelector('.status-label')?.textContent === '打码错误')));
      const rateSeries = [];
      for (let round = 0; round < 8; round += 1) {
        const value = await page.evaluate(() => {
          const row = Array.from(document.querySelectorAll('.status-row')).find((item) => item.querySelector('.status-label')?.textContent === '直播码率');
          return Number.parseFloat((row?.querySelector('.status-value')?.textContent || '').trim()) || 0;
        });
        rateSeries.push(value);
        await sleep(2000);
      }
      console.log('  发送端码率', JSON.stringify(rateSeries));
      check('高细节画面下直播码率能顶到 8 Mbps 以上', Math.max(...rateSeries) >= 8);
      const viewerFps = await viewerPage.evaluate(() => new Promise((done) => {
        const stats = window.__liveStats;
        const start = stats.video;
        const begin = performance.now();
        const step = () => {
          const spent = performance.now() - begin;
          if (spent > 2000) {
            done(Math.round(((stats.video - start) * 1000) / spent));
            return;
          }
          setTimeout(step, 100);
        };
        step();
      }));
      check('网页直播帧率与采集一致', live.streamFps > 0 && Math.abs(viewerFps - live.streamFps) <= 8);
      const wire = await viewerPage.evaluate(async () => {
        const stats = window.__liveStats;
        const series = [];
        let last = stats.bytes;
        for (let round = 0; round < 5; round += 1) {
          await new Promise((done) => setTimeout(done, 3000));
          const next = stats.bytes;
          series.push(Math.round((((next - last) * 8) / 3000 / 1000) * 100) / 100);
          last = next;
        }
        return {
          codec: stats.codec,
          width: stats.width,
          height: stats.height,
          mbps: series.length ? series[series.length - 1] : 0,
          series,
        };
      });
      console.log('  直播链路', JSON.stringify(wire));
      check('网页直播使用观看端可解码的 HEVC 或 H264', /^(?:hvc1|hev1|avc1)/i.test(wire?.codec || '') && playing);
      check('直播编码画幅与采集一致', wire?.width === live.streamWidth && wire?.height === live.streamHeight);
    } finally {
      await viewer.close();
    }
    await page.evaluate(() => {
      const button = Array.from(document.querySelectorAll('.status-actions mdui-button')).find((element) => element.textContent?.includes('停止直播'));
      button?.dispatchEvent(new MouseEvent('click', { bubbles: true, composed: true }));
    });
    check('直播页停止直播通知主进程', Boolean(await waitFor(async () => {
      const status = await page.evaluate(() => window.recordApi.getStatus());
      return status.liveState === 'idle' ? status : undefined;
    }, 20000)));
    const idle = await fetch(`http://127.0.0.1:${livePort}/status`).then((item) => item.json()).catch(() => undefined);
    check('停止直播后网页服务仍在监听', idle?.live === false);
    const livePipPoint = await page.evaluate(() => {
      const rect = document.querySelector('.live-pane .preview-box')?.getBoundingClientRect();
      return rect ? { x: Math.round(rect.left + rect.width / 2), y: Math.round(rect.top + rect.height / 2) } : null;
    });
    if (livePipPoint) {
      await page.mouse.move(livePipPoint.x, livePipPoint.y);
      await page.mouse.down({ clickCount: 1 }).catch(() => undefined);
      await page.mouse.up({ clickCount: 1 }).catch(() => undefined);
      await page.mouse.down({ clickCount: 2 }).catch(() => undefined);
      await page.mouse.up({ clickCount: 2 }).catch(() => undefined);
      await sleep(1500);
    }
    check('直播页双击不进入画中画', await page.evaluate(() => document.pictureInPictureElement === null));
    await page.evaluate(() => {
      const item = document.querySelectorAll('mdui-navigation-drawer mdui-list-item')[0];
      item?.dispatchEvent(new MouseEvent('click', { bubbles: true, composed: true }));
    });
    check('从直播页返回状态页', await page.waitForFunction(() => document.querySelector('.page-title')?.textContent === '状态', { timeout: 8000 }).then(() => true).catch(() => false));

    const second = spawn(electronBin, [
      rootDir,
      `--user-data-dir=${join(home, 'userData')}`,
      '--use-fake-device-for-media-stream',
      '--use-fake-ui-for-media-stream',
      '--mute-audio',
    ], {
      cwd: rootDir,
      env: {
        ...process.env,
        USERPROFILE: home,
        HOME: home,
        APPDATA: join(home, 'userData'),
        LOCALAPPDATA: join(home, 'userData'),
      },
      stdio: 'ignore',
    });
    const secondExit = await Promise.race([
      new Promise((resolve) => second.once('exit', (code) => resolve({ code }))),
      sleep(15000).then(() => undefined),
    ]);
    if (!secondExit) second.kill();
    check('重复启动只保留主实例', Boolean(secondExit));
    check('第二实例未打断主实例采集', await page.evaluate(() => document.querySelector('.preview-video')?.srcObject instanceof MediaStream));

    await page.evaluate(() => {
      const button = Array.from(document.querySelectorAll('.status-actions mdui-button')).find((element) => element.textContent?.includes('开始录制'));
      button?.dispatchEvent(new MouseEvent('click', { bubbles: true, composed: true }));
    });
    const recording = await waitFor(async () => {
      const status = await page.evaluate(() => window.recordApi.getStatus());
      return status.recordState === 'recording' ? status : undefined;
    }, 20000);
    check('开始录制后主进程记录录制状态', Boolean(recording));

    const rotated = await waitFor(async () => {
      const names = await readdir(cacheDir).catch(() => []);
      const name = names.find((item) => /^segment\d+p\d+\.(mp4|mkv|webm)$/.test(item));
      if (!name) return undefined;
      const info = await stat(join(cacheDir, name)).catch(() => undefined);
      return info && info.size > 0 ? { name, size: info.size } : undefined;
    }, 40000);
    check('录制过程中按时长轮转出完整分段', Boolean(rotated));
    check('缓存分段写入非空数据', Boolean(rotated) && rotated.size > 0);
    if (!rotated) {
      const probe = await page.evaluate(async () => {
        const stream = document.querySelector('.preview-video').srcObject;
        const runs = [];
        for (const type of ['video/mp4;codecs=avc1,mp4a.40.2', 'video/webm']) {
          const events = [];
          const recorder = new MediaRecorder(stream, { mimeType: type, videoBitsPerSecond: 12000000, audioBitsPerSecond: 192000 });
          recorder.ondataavailable = (event) => events.push(event.data.size);
          recorder.onerror = (event) => events.push(`error:${event.error?.name || event.error?.message || 'unknown'}`);
          recorder.start();
          await new Promise((resolve) => setTimeout(resolve, 8000));
          const state = recorder.state;
          recorder.stop();
          await new Promise((resolve) => setTimeout(resolve, 800));
          runs.push({ type, events, state });
        }
        return runs;
      });
      console.log('  录制诊断', JSON.stringify(probe));
    }

    const before = (await page.evaluate(() => window.recordApi.getStatus())).segments;
    await sleep(1500);
    await page.evaluate(() => {
      const button = Array.from(document.querySelectorAll('.status-actions mdui-button')).find((element) => element.textContent?.includes('停止录制'));
      button?.dispatchEvent(new MouseEvent('click', { bubbles: true, composed: true }));
    });
    const records = await waitFor(async () => {
      const status = await page.evaluate(() => window.recordApi.getStatus());
      if (status.segments <= before) return undefined;
      const manifest = await readFile(join(cacheDir, 'segments.json'), 'utf8').catch(() => '[]');
      const list = JSON.parse(manifest);
      return Array.isArray(list) && list.length > 1 ? list : undefined;
    }, 30000);
    check('停止录制后收尾分段封装为分段文件', Boolean(records));
    const record = Array.isArray(records) ? [...records].sort((a, b) => b.endAt - b.startAt - (a.endAt - a.startAt))[0] : undefined;
    const sealed = record ? record.filePath.split(/[\\/]/).pop() : undefined;
    check('分段登记进缓存清单', Boolean(record) && existsSync(join(cacheDir, sealed)));
    check('分段时长来自真实时间戳', Boolean(record) && record.endAt - record.startAt >= 2000);
    check('分段记录采集规格与音频标记', Boolean(record) && record.width > 0 && record.height > 0 && record.fps > 0 && record.hasAudio === true);
    const ordered = Array.isArray(records) ? [...records].sort((a, b) => a.startAt - b.startAt) : [];
    const seam = ordered.length > 1 && ordered.slice(1).every((item, index) => {
      const overlap = ordered[index].endAt - item.startAt;
      return overlap > 0 && overlap <= 2000;
    });
    check('轮转分段之间时间轴连续', seam);

    if (record && sealed) {
      const file = join(cacheDir, sealed);
      const probe = await runFFmpeg(['-hide_banner', '-i', file]);
      check('分段可被 ffmpeg 解析', /Duration:/.test(probe.output));
      check('分段使用 HEVC 或 H264 编码且包含音频轨', /Video: hevc|Video: h264/.test(probe.output) && /Audio: /.test(probe.output));
      const decode = await runFFmpeg(['-hide_banner', '-i', file, '-an', '-f', 'null', '-']);
      const counts = [...decode.output.matchAll(/frame=\s*(\d+)/g)].map((item) => Number(item[1]));
      const frames = counts.length ? Math.max(...counts) : 0;
      check('分段可完整解码', decode.code === 0 && frames > 30);
      if (!frames) console.log('  解码诊断', sealed, JSON.stringify({ code: decode.code, tail: decode.output.slice(-300) }));
      const seek = join(videoDir, 'probe.mp4');
      const cut = await runFFmpeg(['-hide_banner', '-v', 'error', '-y', '-ss', '1', '-t', '1', '-i', file, '-c:v', 'libx264', '-preset', 'veryfast', '-an', seek]);
      check('分段可按时间轴裁剪', cut.code === 0 && existsSync(seek));
    }

    const stopped = await waitFor(async () => {
      const status = await page.evaluate(() => window.recordApi.getStatus());
      return status.recordState === 'idle' && status.segments > 0 ? status : undefined;
    }, 20000);
    if (!stopped) {
      const status = await page.evaluate(() => window.recordApi.getStatus());
      console.log('  停止录制诊断', JSON.stringify({ recordState: status.recordState, recordError: status.recordError, segments: status.segments, cacheStart: status.cacheStart, cacheEnd: status.cacheEnd, manifestCount: records?.length }));
    }
    check('状态页统计到缓存分段', Boolean(stopped));
    check('缓存区间来自分段真实时间戳', Boolean(stopped?.cacheStart) && (stopped?.cacheEnd ?? 0) > (stopped?.cacheStart ?? 0));
  } finally {
    if (browser) await browser.disconnect().catch(() => undefined);
    child.kill();
    await sleep(500);
    await rm(home, { recursive: true, force: true }).catch(() => undefined);
  }

  if (failures.length) {
    console.error(`\n采集测试：${checks.length - failures.length}/${checks.length} 通过`);
    console.error(`失败项：${failures.join('、')}`);
    console.error(appLog.join('').slice(-2000));
    process.exit(1);
  }
  console.log(`\n采集测试：${checks.length}/${checks.length} 通过`);
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});

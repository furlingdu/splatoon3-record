import { build } from 'esbuild';
import { spawn } from 'node:child_process';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const rootDir = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const electronBin = join(rootDir, 'node_modules', 'electron', 'dist', process.platform === 'win32' ? 'electron.exe' : 'electron');
const ffmpegBin = join(rootDir, 'bin', process.platform === 'win32' ? 'ffmpeg.exe' : 'ffmpeg');
const timeoutMs = 90000;

function sleep(ms) {
  return new Promise((resolvePromise) => setTimeout(resolvePromise, ms));
}

function run(command, args, options = {}) {
  return new Promise((resolvePromise) => {
    const child = spawn(command, args, { windowsHide: true, ...options });
    let output = '';
    child.stdout?.on('data', (data) => { output += data.toString(); });
    child.stderr?.on('data', (data) => { output += data.toString(); });
    child.on('error', (error) => resolvePromise({ code: -1, output, error }));
    child.on('close', (code, signal) => resolvePromise({ code: code ?? -1, signal, output }));
  });
}

function runFfmpeg(args) {
  return run(ffmpegBin, args);
}

async function killProcessTree(child) {
  if (!child || child.exitCode !== null) return;
  child.kill();
  if (process.platform === 'win32' && child.pid) {
    await run('taskkill', ['/pid', String(child.pid), '/T', '/F']).catch(() => undefined);
  }
}

function durationSeconds(text) {
  const match = text.match(/Duration:\s*(\d+):(\d+):(\d+(?:\.\d+)?)/i);
  if (!match) return 0;
  return Number(match[1]) * 3600 + Number(match[2]) * 60 + Number(match[3]);
}

function progressFrames(text) {
  const matches = [...text.matchAll(/frame=\s*(\d+)/g)].map((match) => Number(match[1]));
  return matches.length ? Math.max(...matches) : 0;
}

function progressTime(text) {
  const matches = [...text.matchAll(/time=\s*([\d:.]+)/g)].map((match) => match[1]);
  const value = matches.at(-1);
  if (!value) return 0;
  const parts = value.split(':').map(Number);
  if (parts.length !== 3 || parts.some((part) => !Number.isFinite(part))) return 0;
  return parts[0] * 3600 + parts[1] * 60 + parts[2];
}

function parseVolume(text, name) {
  const match = text.match(new RegExp(`${name}_volume:\\s*(-?Infinity|-?[\\d.]+)\\s*dB`, 'i'));
  if (!match) return Number.NEGATIVE_INFINITY;
  return match[1].toLowerCase() === '-infinity' ? Number.NEGATIVE_INFINITY : Number(match[1]);
}

async function inspectSegment(file, seal, fps) {
  const probe = await runFfmpeg(['-hide_banner', '-i', file]);
  const videoTrack = /Stream #\d+:\d+[^\n]*Video:/i.test(probe.output);
  const audioTrack = /Stream #\d+:\d+[^\n]*Audio:/i.test(probe.output);
  const duration = durationSeconds(probe.output);
  const decode = await runFfmpeg([
    '-hide_banner', '-loglevel', 'info', '-i', file,
    '-map', '0:v:0', '-map', '0:a:0', '-f', 'null', '-',
    '-progress', 'pipe:1', '-nostats',
  ]);
  const frames = progressFrames(decode.output);
  const decodedTime = progressTime(decode.output);
  const volume = await runFfmpeg([
    '-hide_banner', '-i', file, '-map', '0:a:0', '-af', 'volumedetect', '-f', 'null', '-',
  ]);
  const maxVolume = parseVolume(volume.output, 'max');
  const meanVolume = parseVolume(volume.output, 'mean');
  const expectedDuration = Number.isFinite(seal?.endUs) && Number.isFinite(seal?.firstUs)
    ? Math.max(0, (seal.endUs - seal.firstUs) / 1000000)
    : 0;
  const timelineDuration = expectedDuration || duration || decodedTime;
  const expectedFrames = Math.max(1, Math.round(timelineDuration * fps));
  const frameError = Math.abs(frames - expectedFrames);
  const frameConsistent = frames > 0 && timelineDuration > 0 && frameError <= Math.max(3, Math.ceil(expectedFrames * 0.15));
  const nonSilent = Number.isFinite(maxVolume) && maxVolume > -55 && Number.isFinite(meanVolume) && meanVolume > -70;
  return {
    file,
    bytes: existsSync(file) ? (await readFile(file)).byteLength : 0,
    probeCode: probe.code,
    decodeCode: decode.code,
    volumeCode: volume.code,
    videoTrack,
    audioTrack,
    duration,
    decodedTime,
    frames,
    expectedFrames,
    expectedDuration,
    maxVolume,
    meanVolume,
    frameConsistent,
    nonSilent,
    outputTail: decode.output.slice(-1200),
  };
}

async function buildBundle(tempRoot) {
  const bundlePath = join(tempRoot, 'recording-renderer.js');
  const sourcePath = (path) => path.replaceAll('\\', '/');
  const entry = `
    const { ipcRenderer } = require('electron');
    import { SegmentRecorder } from '${sourcePath(join(rootDir, 'src', 'renderer', 'lib', 'segment.ts'))}';
    import { openVideoFeed } from '${sourcePath(join(rootDir, 'src', 'renderer', 'lib', 'videofeed.ts'))}';

    const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
    const safeError = (cause) => {
      const detail = cause || {};
      return detail.message || detail.name || String(cause || '未知错误');
    };

    let failed = false;
    async function reportFailure(cause) {
      if (failed) return;
      failed = true;
      const message = safeError(cause);
      try { await ipcRenderer.invoke('recording-failed', { message, stack: cause?.stack || '' }); } catch { /* renderer is exiting */ }
    }

    window.addEventListener('error', (event) => { void reportFailure(event.error || new Error(event.message)); });
    window.addEventListener('unhandledrejection', (event) => { void reportFailure(event.reason || new Error('未处理的 Promise 异常')); });

    async function makeSource() {
      const fake = await navigator.mediaDevices.getUserMedia({
        video: { width: { ideal: 640 }, height: { ideal: 360 }, frameRate: { ideal: 30 } },
        audio: { channelCount: 2, sampleRate: 48000, echoCancellation: false, noiseSuppression: false, autoGainControl: false },
      });
      const fakeDevices = {
        videoTracks: fake.getVideoTracks().length,
        audioTracks: fake.getAudioTracks().length,
      };
      if (!fakeDevices.videoTracks || !fakeDevices.audioTracks) throw new Error('fake-device 未提供完整音视频轨道');

      const canvas = document.createElement('canvas');
      canvas.width = 640;
      canvas.height = 360;
      const context = canvas.getContext('2d');
      if (!context) throw new Error('无法创建 canvas 画布');
      let frame = 0;
      const draw = () => {
        const phase = frame % 360;
        context.fillStyle = 'hsl(' + phase + ', 70%, 35%)';
        context.fillRect(0, 0, canvas.width, canvas.height);
        context.fillStyle = '#ffffff';
        context.font = 'bold 42px sans-serif';
        context.fillText('WebCodecs recording regression', 26, 92);
        context.font = '28px monospace';
        context.fillText('frame ' + frame, 26, 142);
        context.fillRect((phase * 3) % 560, 220, 54, 54);
        frame += 1;
      };
      draw();
      const drawTimer = window.setInterval(draw, 1000 / 30);
      const videoStream = canvas.captureStream(30);
      const videoTrack = videoStream.getVideoTracks()[0];
      if (!videoTrack) throw new Error('canvas.captureStream 未提供视频轨道');

      const audioContext = new AudioContext({ sampleRate: 48000 });
      const destination = audioContext.createMediaStreamDestination();
      const oscillator = audioContext.createOscillator();
      const gain = audioContext.createGain();
      oscillator.type = 'sine';
      oscillator.frequency.value = 440;
      gain.gain.value = 0.18;
      oscillator.connect(gain);
      gain.connect(destination);
      oscillator.start();
      await audioContext.resume();
      const audioTrack = destination.stream.getAudioTracks()[0];
      if (!audioTrack) throw new Error('AudioContext 未提供合成音频轨道');

      return {
        fake,
        fakeDevices,
        videoTrack,
        audioTrack,
        audioContext,
        oscillator,
        drawTimer,
        videoStream,
        stop() {
          window.clearInterval(drawTimer);
          oscillator.stop();
          videoTrack.stop();
          audioTrack.stop();
          fake.getTracks().forEach((track) => track.stop());
          void audioContext.close().catch(() => undefined);
        },
      };
    }

    async function main() {
      let source;
      let feed;
      let recorder;
      let writes = Promise.resolve();
      const seals = [];
      const audioEvents = [];
      const sinkErrors = [];
      const sink = {
        onError(message) {
          sinkErrors.push(String(message));
        },
        onData(id, data, position) {
          writes = writes.then(() => ipcRenderer.invoke('recording-chunk', id, data, position));
        },
        onSeal(seal) {
          const copy = {
            id: seal.id,
            firstUs: seal.firstUs,
            endUs: seal.endUs,
            spec: seal.spec,
            info: seal.info,
          };
          seals.push(copy);
          writes = writes.then(() => ipcRenderer.invoke('recording-seal', copy));
        },
        onRotate() {},
        onAudio(state, detail) {
          audioEvents.push({ state, detail: detail || '' });
        },
        onFatal(message) {
          sinkErrors.push('fatal:' + message);
        },
      };

      try {
        source = await makeSource();
        const settings = source.videoTrack.getSettings();
        const spec = {
          width: Math.max(2, Math.round(Number(settings.width) || 640)),
          height: Math.max(2, Math.round(Number(settings.height) || 360)),
          fps: Math.max(1, Math.round(Number(settings.frameRate) || 30)),
          hasAudio: true,
        };
        feed = openVideoFeed(source.videoTrack);
        recorder = await SegmentRecorder.open(source.videoTrack, source.audioTrack, 22, spec, sink, feed);

        for (let index = 0; index < 4; index += 1) {
          await wait(3000);
          recorder.rotate();
        }
        await wait(3000);
        await recorder.close();
        recorder = undefined;
        feed.stop();
        feed = undefined;
        source.stop();
        source = undefined;
        await writes;
        await ipcRenderer.invoke('recording-complete', {
          seals,
          audioEvents,
          sinkErrors,
          spec,
          fakeDevices: source?.fakeDevices,
        });
      } catch (cause) {
        try { await recorder?.close(); } catch { /* report original failure */ }
        feed?.stop();
        source?.stop();
        await reportFailure(cause);
      }
    }

    void main();
  `;
  await build({
    stdin: { contents: entry, sourcefile: join(tempRoot, 'recording-entry.ts'), loader: 'ts', resolveDir: rootDir },
    bundle: true,
    format: 'iife',
    platform: 'browser',
    target: 'chrome120',
    external: ['electron'],
    outfile: bundlePath,
    logLevel: 'silent',
  });
  return bundlePath;
}

async function createMain(tempRoot, bundlePath, htmlPath, outputDir, userDataDir, resultPath) {
  const mainPath = join(tempRoot, 'main.cjs');
  const main = `
    const { app, BrowserWindow, ipcMain } = require('electron');
    const { open, mkdir, writeFile } = require('node:fs/promises');
    const { join } = require('node:path');

    const outputDir = ${JSON.stringify(outputDir)};
    const resultPath = ${JSON.stringify(resultPath)};
    const htmlPath = ${JSON.stringify(htmlPath)};
    const userDataDir = ${JSON.stringify(userDataDir)};
    const files = new Map();
    const seals = [];
    let finished = false;

    app.setPath('userData', userDataDir);
    app.setPath('sessionData', join(userDataDir, 'session'));
    app.commandLine.appendSwitch('use-fake-device-for-media-stream');
    app.commandLine.appendSwitch('use-fake-ui-for-media-stream');
    app.commandLine.appendSwitch('disable-background-timer-throttling');
    app.commandLine.appendSwitch('disable-renderer-backgrounding');
    app.commandLine.appendSwitch('autoplay-policy', 'no-user-gesture-required');

    function safeId(id) {
      return String(id).replace(/[^a-z0-9_-]/gi, '_');
    }

    function stateFor(id) {
      const key = safeId(id);
      let state = files.get(key);
      if (!state) {
        state = { id: key, path: join(outputDir, key + '.mp4'), handle: undefined, chain: Promise.resolve(), bytes: 0, sealed: false };
        files.set(key, state);
      }
      return state;
    }

    function bufferFor(value) {
      if (value instanceof Uint8Array) return Buffer.from(value);
      if (value instanceof ArrayBuffer) return Buffer.from(value);
      if (ArrayBuffer.isView(value)) return Buffer.from(value.buffer, value.byteOffset, value.byteLength);
      throw new Error('IPC 数据不是 Uint8Array');
    }

    function enqueue(state, task) {
      const next = state.chain.then(task);
      state.chain = next.catch(() => undefined);
      return next;
    }

    async function writeChunk(id, value, position) {
      const state = stateFor(id);
      if (!Number.isSafeInteger(position) || position < 0) throw new Error('非法 MP4 chunk offset');
      return enqueue(state, async () => {
        if (state.sealed) throw new Error('MP4 已封存后仍收到数据');
        if (!state.handle) state.handle = await open(state.path, 'w+');
        const buffer = bufferFor(value);
        await state.handle.write(buffer, 0, buffer.byteLength, position);
        state.bytes = Math.max(state.bytes, position + buffer.byteLength);
      });
    }

    async function sealFile(seal) {
      const state = stateFor(seal.id);
      await enqueue(state, async () => {
        if (state.handle) {
          await state.handle.sync();
          await state.handle.close();
          state.handle = undefined;
        }
        state.sealed = true;
        seals.push({ ...seal, path: state.path, bytes: state.bytes });
      });
    }

    async function closeOpenFiles() {
      for (const state of files.values()) {
        await state.chain;
        if (state.handle) {
          await state.handle.sync();
          await state.handle.close();
          state.handle = undefined;
        }
      }
    }

    async function finish(payload) {
      await closeOpenFiles();
      const result = {
        ok: true,
        ...payload,
        seals,
        files: seals.map((seal) => ({ id: seal.id, path: seal.path, bytes: seal.bytes })),
      };
      await writeFile(resultPath, JSON.stringify(result, null, 2), 'utf8');
      finished = true;
      setTimeout(() => app.quit(), 20);
      return result;
    }

    async function fail(payload) {
      if (finished) return;
      finished = true;
      await closeOpenFiles().catch(() => undefined);
      await writeFile(resultPath, JSON.stringify({ ok: false, ...payload, seals }, null, 2), 'utf8').catch(() => undefined);
      setTimeout(() => app.exit(1), 20);
    }

    ipcMain.handle('recording-chunk', (_event, id, value, position) => writeChunk(id, value, position));
    ipcMain.handle('recording-seal', (_event, seal) => sealFile(seal));
    ipcMain.handle('recording-complete', (_event, payload) => finish(payload));
    ipcMain.handle('recording-failed', (_event, payload) => fail(payload));

    process.on('uncaughtException', (error) => { void fail({ error: error.message, stack: error.stack }); });
    process.on('unhandledRejection', (error) => { void fail({ error: String(error) }); });

    app.whenReady().then(async () => {
      await mkdir(outputDir, { recursive: true });
      const window = new BrowserWindow({
        show: false,
        webPreferences: {
          backgroundThrottling: false,
          contextIsolation: false,
          nodeIntegration: true,
          sandbox: false,
        },
      });
      window.webContents.on('console-message', (_event, _level, message) => process.stderr.write('[renderer] ' + message + '\\n'));
      window.webContents.on('render-process-gone', (_event, details) => { void fail({ error: 'renderer exited: ' + details.reason }); });
      await window.loadFile(htmlPath);
    }).catch((error) => { void fail({ error: error.message, stack: error.stack }); });
  `;
  await writeFile(mainPath, main, 'utf8');
  return mainPath;
}

async function main() {
  if (!existsSync(electronBin)) throw new Error(`Electron 不存在：${electronBin}`);
  if (!existsSync(ffmpegBin)) throw new Error(`FFmpeg 不存在：${ffmpegBin}`);

  const tempRoot = await mkdtemp(join(tmpdir(), 's3record-real-recording-'));
  const outputDir = join(tempRoot, 'segments');
  const userDataDir = join(tempRoot, 'userData');
  const resultPath = join(tempRoot, 'result.json');
  const htmlPath = join(tempRoot, 'renderer.html');
  let child;
  let timedOut = false;
  let logs = '';

  try {
    const bundlePath = await buildBundle(tempRoot);
    await writeFile(htmlPath, `<!doctype html><meta charset="utf-8"><script src="${bundlePath.replaceAll('\\', '/').replace(/^[A-Za-z]:/, (match) => '/' + match)}"></script>`, 'utf8');
    const mainPath = await createMain(tempRoot, bundlePath, htmlPath, outputDir, userDataDir, resultPath);
    child = spawn(electronBin, [mainPath, '--use-fake-device-for-media-stream', '--use-fake-ui-for-media-stream', '--mute-audio', '--disable-background-timer-throttling', '--disable-renderer-backgrounding'], {
      cwd: tempRoot,
      env: {
        ...process.env,
        RECORDING_TEST: '1',
        ELECTRON_NO_ATTACH_CONSOLE: '1',
      },
      stdio: ['ignore', 'pipe', 'pipe'],
      windowsHide: true,
    });
    child.stdout.on('data', (data) => { logs += data.toString(); });
    child.stderr.on('data', (data) => { logs += data.toString(); });

    const exit = await Promise.race([
      new Promise((resolvePromise) => child.once('exit', (code, signal) => resolvePromise({ code, signal }))),
      sleep(timeoutMs).then(() => { timedOut = true; return undefined; }),
    ]);
    if (!exit) {
      await killProcessTree(child);
      throw new Error(`Electron 录制测试超时（${timeoutMs}ms）`);
    }
    const raw = await readFile(resultPath, 'utf8').catch(() => '');
    const result = raw ? JSON.parse(raw) : undefined;
    if (!result?.ok) {
      throw new Error(`Electron renderer 录制失败：${result?.error || result?.message || `exit=${exit.code}`}\n${logs.slice(-5000)}`);
    }
    if (exit.code !== 0) throw new Error(`Electron 退出码 ${exit.code}\n${logs.slice(-5000)}`);

    const seals = result.seals || [];
    const fps = Math.max(1, Number(result.spec?.fps) || 30);
    if (seals.length < 4) throw new Error(`真实录制只封存了 ${seals.length} 段，少于 4 段`);
    const reports = [];
    for (const seal of seals) {
      const report = await inspectSegment(seal.path, seal, fps);
      reports.push(report);
      console.log(JSON.stringify({
        id: seal.id,
        bytes: report.bytes,
        videoTrack: report.videoTrack,
        audioTrack: report.audioTrack,
        decodeCode: report.decodeCode,
        frames: report.frames,
        expectedFrames: report.expectedFrames,
        duration: report.duration,
        expectedDuration: report.expectedDuration,
        maxVolume: report.maxVolume,
        meanVolume: report.meanVolume,
        frameConsistent: report.frameConsistent,
        nonSilent: report.nonSilent,
      }));
    }

    const failedReports = reports.filter((report) => (
      report.bytes <= 0
      || report.probeCode < 0
      || report.decodeCode !== 0
      || report.volumeCode !== 0
      || !report.videoTrack
      || !report.audioTrack
      || !report.nonSilent
      || !report.frameConsistent
    ));
    if (failedReports.length) {
      throw new Error(`真实 MP4 回归失败：${failedReports.length}/${reports.length} 段不满足音轨、非静音、完整解码或帧时长一致性\n${JSON.stringify(failedReports, null, 2)}`);
    }
    console.log(JSON.stringify({
      ok: true,
      electron: electronBin,
      ffmpeg: ffmpegBin,
      segments: reports.length,
      audioEvents: result.audioEvents,
      sinkErrors: result.sinkErrors,
      fakeDevices: result.fakeDevices,
      reports,
    }, null, 2));
  } finally {
    if (timedOut) await killProcessTree(child);
    await rm(tempRoot, { recursive: true, force: true }).catch(() => undefined);
  }
}

main().catch((error) => {
  console.error(error?.stack || error);
  process.exitCode = 1;
});

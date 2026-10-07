import { createServer } from 'node:http';
import { readFile, stat } from 'node:fs/promises';
import { extname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import puppeteer from 'puppeteer';

const rootDir = join(fileURLToPath(new URL('.', import.meta.url)), '..');
const siteDir = join(rootDir, 'dist', 'renderer');
const mimeTypes = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.svg': 'image/svg+xml', '.png': 'image/png', '.jpg': 'image/jpeg', '.woff2': 'font/woff2', '.json': 'application/json' };

const mockDevices = [
  {
    deviceId: 'obs1', kind: 'videoinput', label: 'OBS Virtual Camera (1234:5678)', groupId: 'g1',
    caps: { width: { max: 3840, min: 320 }, height: { max: 2160, min: 180 }, frameRate: { max: 60, min: 1 } },
  },
  {
    deviceId: 'cam2', kind: 'videoinput', label: 'Camera 2 (9abc:def0)', groupId: 'g1',
    caps: { width: { max: 1280, min: 160 }, height: { max: 720, min: 90 }, frameRate: { max: 30, min: 1 } },
  },
  { deviceId: 'audio1', kind: 'audioinput', label: 'Audio 1 (aaaa:bbbb)', groupId: 'g2' },
];

const mockMatches = [
  { matchId: 'vs-100', kind: 'regular', mode: 'REGULAR', rule: 'TURF_WAR', startAt: 1, endAt: 2, duration: 180000, result: 'WIN', isDisconnected: false, isSalmon: false, videoPath: 'D:/v/a.mp4', rawData: {} },
  { matchId: 'coop-9', kind: 'salmon', mode: 'COOP', rule: 'COOP_GROUP', startAt: 1, endAt: 2, duration: 300000, result: '', isDisconnected: true, isSalmon: true, videoPath: undefined, rawData: {} },
  { matchId: 'vs-200', kind: 'regular', mode: 'REGULAR', rule: 'TURF_WAR', startAt: 1, endAt: 2, duration: 180000, result: 'LOSE', isDisconnected: true, isSalmon: false, videoPath: 'D:/v/b.mp4', rawData: {} },
  { matchId: 'vs-300', kind: 'xBattle', mode: 'X_MATCH', rule: 'X_MATCH', startAt: 1, endAt: 2, duration: 180000, result: 'WIN', isDisconnected: false, isSalmon: false, videoPath: undefined, rawData: {} },
];

function findChrome() {
  return puppeteer.executablePath();
}

function createMockStatus(overrides = {}) {
  const now = Date.now();
  const latest = {
    matchId: 'vs-100', kind: 'regular', mode: 'REGULAR', rule: 'TURF_WAR',
    startAt: now - 180000, endAt: now, duration: 180000,
    result: 'WIN', isDisconnected: false, isSalmon: false, videoPath: 'D:/v/vs100.mp4', rawData: {},
  };
  return {
    recordState: 'idle',
    recordError: undefined,
    streamWidth: 1920,
    streamHeight: 1080,
    streamFps: 60,
    streamFormat: 'video/mp4;codecs=avc1',
    streamAudio: true,
    segments: 6,
    cacheStart: now - 300000,
    cacheEnd: now,
    hwAccel: 'CUDA',
    encoder: 'hevc_amf',
    nsoState: 'connected',
    qqState: 'connected',
    qqOwner: 'openid-owner',
    qrCode: 'https://qrcode.example/bind',
    setupDone: true,
    recentMatches: [latest],
    processingMatchIds: [latest.matchId],
    latestMatch: latest,
    pushState: 'idle',
    settings: {
      videoDevice: 'obs1', audioDevice: 'audio1', width: 1920, height: 1080, fps: 60, flipVertical: false,
      encoder: 'auto', quality: 22, saveDir: 'D:/videos',
      autoPush: true, autoRecord: false, autoLaunch: false, blurNickname: false, monitorAudio: false, pollSeconds: 10,
    },
    pushOptions: { cap: 2, codec: 'hevc', targetMb: 100 },
    liveState: 'idle',
    liveError: undefined,
    liveUrl: 'http://localhost:11567/',
    liveOptions: { port: 11567 },
    ...overrides,
  };
}

async function startServer() {
  const server = createServer(async (req, res) => {
    try {
      const url = new URL(req.url || '/', 'http://127.0.0.1');
      let path = join(siteDir, decodeURIComponent(url.pathname));
      if (extname(path) === '') path = join(path, 'index.html');
      await stat(path);
      const body = await readFile(path);
      res.writeHead(200, { 'Content-Type': mimeTypes[extname(path)] || 'application/octet-stream' });
      res.end(body);
    } catch {
      res.writeHead(404); res.end('not found');
    }
  });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  return { server, port: server.address().port };
}

async function installMock(page, status, matches) {
  await page.evaluateOnNewDocument((initialStatus, initialMatches, deviceList) => {
    let latest = initialStatus;
    const state = {
      unknown: [], chunks: [], segments: [], reports: [], links: [], calls: {}, lastSettings: null,
      baseSettings: initialStatus.settings, settingsWrites: [],
      missingDevice: null, statusListeners: [], mediaListeners: {}, audioReady: false, pipElement: null, pipOpens: 0, pipExits: 0,
      liveStarted: 0, blurStart: null, blurChunks: 0, copied: [],
      liveChunks: 0, liveViewerListeners: [],
    };
    window.__ui = state;
    const mark = (name) => { state.calls[name] = (state.calls[name] || 0) + 1; };

    const delayed = async (list) => {
      if (window.__deviceDelay) await new Promise((resolve) => setTimeout(resolve, window.__deviceDelay));
      return list;
    };

    function audioTrack() {
      try {
        const Ctor = window.AudioContext || window.webkitAudioContext;
        if (!Ctor) return undefined;
        const context = new Ctor();
        const oscillator = context.createOscillator();
        const destination = context.createMediaStreamDestination();
        oscillator.connect(destination);
        oscillator.start();
        window.__audioContext = context;
        return destination.stream.getAudioTracks()[0];
      } catch {
        return undefined;
      }
    }

    function paint(canvas, width, height) {
      const context = canvas.getContext('2d');
      let step = 0;
      const draw = () => {
        context.fillStyle = step % 2 === 0 ? '#e60012' : '#0f8a0f';
        context.fillRect(0, 0, width, height);
        context.fillStyle = '#ffffff';
        context.font = '48px sans-serif';
        context.fillText(String(step), 24, 80);
        step += 1;
      };
      draw();
      window.__paintTimer = setInterval(draw, 100);
    }

    async function openMedia(constraints) {
      const video = constraints?.video;
      const audio = constraints?.audio;
      if (!video && !audio) throw new DOMException('未选择采集设备', 'NotFoundError');
      const stream = new MediaStream();
      if (video) {
        const wanted = String(video.deviceId?.exact || '');
        if (wanted && wanted === state.missingDevice) throw new DOMException('Requested device not found', 'NotFoundError');
        if (wanted && !deviceList.some((item) => item.deviceId === wanted && item.kind === 'videoinput')) throw new DOMException('Requested device not found', 'NotFoundError');
        const caps = deviceList.find((item) => item.deviceId === wanted)?.caps || {};
        const maxWidth = caps.width?.max || 3840;
        const maxHeight = caps.height?.max || 2160;
        const maxFps = caps.frameRate?.max || 60;
        const asked = { width: Number(video.width?.exact ?? video.width?.ideal), height: Number(video.height?.exact ?? video.height?.ideal) };
        if (video.width?.exact && asked.width > maxWidth) throw new DOMException('', 'OverconstrainedError');
        if (video.height?.exact && asked.height > maxHeight) throw new DOMException('', 'OverconstrainedError');
        const forced = Number(window.__forceDefaultOpen || 0);
        if (forced > 0) window.__forceDefaultOpen = forced - 1;
        const fallback = forced > 0 ? { width: 640, height: 480, fps: 30 } : undefined;
        const width = fallback ? fallback.width : Math.min(asked.width || Math.min(1920, maxWidth), maxWidth);
        const height = fallback ? fallback.height : Math.min(asked.height || Math.min(1080, maxHeight), maxHeight);
        const fps = fallback ? fallback.fps : Math.min(Number(video.frameRate?.exact ?? video.frameRate?.ideal) || maxFps, maxFps);
        const canvas = document.createElement('canvas');
        canvas.width = width;
        canvas.height = height;
        paint(canvas, width, height);
        const track = canvas.captureStream(fps).getVideoTracks()[0];
        let actualSize = { width, height, fps };
        track.getCapabilities = () => caps;
        track.getSettings = () => ({ deviceId: wanted, width: actualSize.width, height: actualSize.height, frameRate: actualSize.fps });
        track.applyConstraints = async (constraints) => {
          if (state.blockApply && (constraints?.width || constraints?.height)) throw new DOMException('', 'OverconstrainedError');
          const nextWidth = Number(constraints?.width?.exact ?? constraints?.width?.ideal ?? actualSize.width);
          const nextHeight = Number(constraints?.height?.exact ?? constraints?.height?.ideal ?? actualSize.height);
          const nextFps = Number(constraints?.frameRate?.exact ?? constraints?.frameRate?.ideal ?? actualSize.fps);
          if ((constraints?.width?.exact && nextWidth > maxWidth)
            || (constraints?.height?.exact && nextHeight > maxHeight)
            || (constraints?.frameRate?.exact && nextFps > maxFps)) throw new DOMException('', 'OverconstrainedError');
          actualSize = { width: Math.min(nextWidth, maxWidth), height: Math.min(nextHeight, maxHeight), fps: Math.min(nextFps, maxFps) };
        };
        stream.addTrack(track);
        state.opens = (state.opens || []).concat({ width, height, fps, forced: Boolean(fallback) });
      }
      if (audio) {
        const track = audioTrack();
        if (track) stream.addTrack(track);
      }
      state.audioReady = stream.getAudioTracks().length > 0;
      state.lastConstraints = constraints;
      state.streams = (state.streams || []).concat(stream);
      stream.__tag = { deviceId: String(video?.deviceId?.exact || ''), capture: Boolean(video?.deviceId?.exact) && Boolean(audio) };
      return stream;
    }

    async function getUserMedia(constraints) {
      state.opening = (state.opening || 0) + 1;
      state.openMax = Math.max(state.openMax || 0, state.opening);
      try {
        if (window.__openTimeoutOnce && constraints?.audio) {
          window.__openTimeoutOnce = false;
          throw new DOMException('Timeout starting video source', 'NotReadableError');
        }
        if (window.__openDelay) await new Promise((resolve) => setTimeout(resolve, window.__openDelay));
        return await openMedia(constraints);
      } finally {
        state.opening -= 1;
      }
    }

    const mediaDevices = {
      enumerateDevices: () => delayed(deviceList),
      getUserMedia,
      getSupportedConstraints: () => ({}),
      addEventListener: (name, listener) => { (state.mediaListeners[name] ||= []).push(listener); },
      removeEventListener: (name, listener) => { state.mediaListeners[name] = (state.mediaListeners[name] || []).filter((item) => item !== listener); },
    };
    Object.defineProperty(navigator, 'mediaDevices', { configurable: true, value: mediaDevices });

    const api = {
      getStatus: async () => latest,
      getRuntimeInfo: async () => {
        mark('getRuntimeInfo');
        return {
          appVersion: '2.0.0', electronVersion: '38.0.0', chromeVersion: '140.0.0.0', nodeVersion: '22.0.0',
          platform: 'win32', arch: 'x64', osRelease: '10.0.26100', gpu: ['NVIDIA / GeForce RTX 4060'],
          gpuStatus: { video_decode: 'enabled', video_encode: 'enabled' }, hardwareAcceleration: true,
          displays: ['1920x1080@100%'],
        };
      },
      saveSettings: async (settings) => {
        state.lastSettings = settings;
        state.settingsWrites.push(settings);
        latest = { ...latest, settings };
        mark('saveSettings');
        state.statusListeners.forEach((callback) => callback(latest));
        return latest;
      },
      openNsoLogin: async () => mark('openNsoLogin'),
      clearNsoLogin: async () => mark('clearNsoLogin'),
      unbindNso: async () => mark('unbindNso'),
      startQqLogin: async () => mark('startQqLogin'),
      unbindQq: async () => mark('unbindQq'),
      listMatches: async () => initialMatches,
      thumb: async () => '',
      openMatch: async () => mark('openMatch'),
      openPath: async (targetPath) => { mark('openPath'); state.lastOpenedPath = targetPath; },
      saveMatch: async () => 'D:/saved.mp4',
      deleteMatch: async () => mark('deleteMatch'),
      getVideoUrl: async (matchId) => (initialMatches.some((item) => item.matchId === matchId && item.videoPath) ? `s3r-video://match/${encodeURIComponent(matchId)}` : undefined),
      writeChunk: async (id, chunk, offset) => {
        state.chunks.push({ id, size: chunk.byteLength, offset });
        return true;
      },
      writeSegment: async (draft) => {
        state.segments.push(draft);
        mark('writeSegment');
        return { filePath: `cache/${draft.id}.${draft.ext}`, startAt: draft.startAt, endAt: draft.endAt, width: draft.width, height: draft.height, fps: draft.fps, encoder: draft.encoder, hasAudio: draft.hasAudio, flip: false };
      },
      reportCapture: (report) => { state.reports.push(report); },
      startLive: async () => {
        state.liveStarted += 1;
        mark('startLive');
        if (state.liveFail) {
          latest = { ...latest, liveState: 'error', liveError: '监听端口被占用', liveUrl: undefined };
          state.statusListeners.forEach((callback) => callback(latest));
          return latest;
        }
        latest = { ...latest, liveState: 'live', liveError: undefined, liveUrl: `http://localhost:${latest.liveOptions.port}/` };
        state.statusListeners.forEach((callback) => callback(latest));
        return latest;
      },
      stopLive: async () => {
        mark('stopLive');
        latest = { ...latest, liveState: 'idle', liveError: undefined };
        state.statusListeners.forEach((callback) => callback(latest));
        return latest;
      },
      liveChunk: (chunk) => {
        state.liveChunks += 1;
        mark('liveChunk');
        void chunk;
      },
      onLiveViewers: (callback) => {
        state.liveViewerListeners.push(callback);
        return () => { state.liveViewerListeners = state.liveViewerListeners.filter((item) => item !== callback); };
      },
      startBlur: async (matchId, mime) => {
        state.blurStart = { matchId, mime };
        mark('startBlur');
        return { jobId: 'blur-1', output: 'D:/v/blur/a-昵称打码.mp4' };
      },
      writeBlurChunk: async (chunk) => {
        state.blurChunks += 1;
        return chunk.byteLength > 0;
      },
      endBlur: async () => { mark('endBlur'); return 'D:/v/blur/a-昵称打码.mp4'; },
      cancelBlur: async () => { mark('cancelBlur'); },
      startDetect: async () => {
        mark('startDetect');
        return 'DirectML';
      },
      detectFrame: async () => {
        state.detectFrames = (state.detectFrames || 0) + 1;
        return { boxes: [], ms: 12 };
      },
      stopDetect: async () => { mark('stopDetect'); },
      copyText: async (text) => {
        state.copied.push(text);
        mark('copyText');
        return true;
      },
      debugExportLast: async () => { mark('debugExportLast'); return 'D:/picked/debug.mp4'; },
      pickFolder: async () => { mark('pickFolder'); return 'D:/picked'; },
      openLink: async (url) => { state.links.push(url); },
      openPreview: async () => { mark('openPreview'); },
      finishSetup: async () => {
        mark('finishSetup');
        if (state.finishError) return { success: false, error: state.finishError };
        return { success: true };
      },
      getEvents: (callback) => {
        state.statusListeners.push(callback);
        return () => { state.statusListeners = state.statusListeners.filter((item) => item !== callback); };
      },
    };
    window.recordApi = new Proxy(api, {
      get(target, prop) {
        if (prop in target) return target[prop];
        if (typeof prop === 'string') state.unknown.push(prop);
        return () => undefined;
      },
    });

    window.__pushStatus = (next) => {
      latest = next;
      state.statusListeners.forEach((callback) => callback(next));
    };
    window.__getStatus = () => latest;
    window.__patchStatus = (patch) => {
      window.__pushStatus({ ...latest, ...patch });
    };
    window.__patchSettings = (patch) => {
      window.__patchStatus({ settings: { ...latest.settings, ...patch } });
    };
    Object.defineProperty(document, 'pictureInPictureElement', { configurable: true, get: () => state.pipElement });
    HTMLVideoElement.prototype.requestPictureInPicture = function requestPictureInPicture() {
      if (!this.srcObject) return Promise.reject(new DOMException('', 'InvalidStateError'));
      state.pipElement = this;
      state.pipOpens += 1;
      this.dispatchEvent(new Event('enterpictureinpicture'));
      return Promise.resolve({ width: 960, height: 540 });
    };
    document.exitPictureInPicture = () => {
      const element = state.pipElement;
      state.pipElement = null;
      state.pipExits += 1;
      if (element) element.dispatchEvent(new Event('leavepictureinpicture'));
      return Promise.resolve();
    };
  }, status, matches, mockDevices);
}

export { createMockStatus, findChrome, installMock, mockDevices, mockMatches, siteDir, startServer };

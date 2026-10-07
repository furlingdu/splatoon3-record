import { app, BrowserWindow, Menu, protocol, screen, shell } from 'electron';
import { release } from 'node:os';
import { initPath, matchPath, saveFolder } from './store/path.js';
import { getConfig, loadConfig, saveConfig, saveSettings } from './store/config.js';
import { createWindow, createSetup } from './window.js';
import { registerIpc } from './ipc.js';
import { SegmentStore } from './capture/segment.js';
import { SegmentWriter } from './capture/recorder.js';
import { sanitizeSettings } from './capture/settings.js';
import { cropVideo } from './match/crop.js';
import { accelSummary, prepareAccel } from './media/accel.js';
import { cancelBlur, clearBlur, endBlur, startBlur, writeBlur } from './match/blurcopy.js';
import { closeLive, liveInfo, onLiveChange, onLiveKey, onLiveViewers, openLive, pushLiveChunk, startLive, stopLive } from './live/control.js';
import { detectFrame, startDetect, stopDetect } from './detect/engine.js';
import { NsoLogin } from './nso/login.js';
import { ensureToken, getToken, isExpired } from './nso/token.js';
import { SplatnetClient } from './nso/splatnet.js';
import { makeQuery } from './nso/query.js';
import { BattlePoller } from './nso/poll.js';
import { loadSecret } from './store/secret.js';
import { pushEnv } from './store/env.js';
import { pollSecondsFixed, segmentSecondsFixed } from '../shared/constants.js';
import { clipRange, matchClock } from './match/clock.js';
import { diskShortage, failureReason } from './match/notice.js';
import { QqBot } from './qq/bot.js';
import { QqLogin } from './qq/login.js';
import { afterBaseline, coveredMatch, dedupeMatches, mergeHandled, retryMatch } from './match/detect.js';
import { purgeArchivedVideos, saveMatch, listMatches } from './match/archive.js';
import { logApp } from './store/log.js';
import { appEvent, liveViewersEvent } from '../shared/events.js';
import { registerVideoProtocol } from './protocol.js';
import type { AppStatus, BattleMatch, CaptureReport, LinkState, RecordSettings, RuntimeInfo, SegmentDraft, SetupResult, VideoRecord } from '../shared/types.js';

const nsoRetryInterval = 300000;
const sweepInterval = 60000;
const recordStates = new Set(['idle', 'starting', 'recording', 'error']);

app.commandLine.appendSwitch('disable-features', 'MediaFoundationVideoCapture');
app.commandLine.appendSwitch('enable-features', 'PlatformHEVCEncoderSupport');

let mainWindow: BrowserWindow | undefined;
let liveViewers = 0;
let setupWindow: BrowserWindow | undefined;
let config = getConfig();
let store: SegmentStore;
let writer: SegmentWriter;
let capture: CaptureReport = { recordState: 'idle', width: 0, height: 0, fps: 0, hasAudio: false };
let nso: NsoLogin;
let qq: QqBot;
let qqLogin: QqLogin;
let poller: BattlePoller | undefined;
let tokenKeeperBusy = false;
let sweepBusy = false;
let nsoRetryAt = 0;
let matches: BattleMatch[] = [];
let recentMatches: BattleMatch[] = [];
let recordBaselineAt = Date.now();
let qrUrl = '';
let qqLoginState: LinkState | undefined;
let matchQueue = Promise.resolve();
let pollGeneration = 0;
const pendingMatchIds = new Set<string>();
let pushState: AppStatus['pushState'] = 'idle';
let pushError: string | undefined;
let quitStarted = false;
let activatePending = false;

protocol.registerSchemesAsPrivileged([{
  scheme: 's3r-video',
  privileges: { standard: true, secure: true, supportFetchAPI: true, stream: true, bypassCSP: true, corsEnabled: true },
}]);

export async function bootApp(): Promise<void> {
  Menu.setApplicationMenu(null);
  recordBaselineAt = Date.now();
  await initPath();
  logApp('app start');
  config = await loadConfig();
  store = new SegmentStore();
  writer = new SegmentWriter();
  await store.openStore();
  matches = (await listMatches(matchPath)).filter((match) => !match.isSalmon && match.kind !== 'salmon');
  const handled = matches.reduce((ids, match) => mergeHandled(ids, match.matchId), config.handledIds);
  if (handled.length !== config.handledIds.length) {
    config = { ...config, handledIds: handled };
    await saveConfig(config);
  }
  nso = new NsoLogin(() => {
    pushStatus();
    if (nso.state === 'connected') void startPoll().catch((error) => console.error(error));
  });
  qq = new QqBot({ status: getStatus, latest: async () => mergedRecent()[0] ?? matches[0], changed: pushStatus });
  qqLogin = new QqLogin({
    qr: (url) => { qrUrl = url; pushStatus(); },
    state: (state) => {
      qqLoginState = state === 'connected' || state === 'unbound' ? undefined : state;
      if (state === 'connected') { qrUrl = ''; void qq.start(); }
      pushStatus();
    },
  });
  registerIpc({
    getStatus,
    getMatches: () => matches,
    nso,
    qq,
    startQqLogin: () => qqLogin.start(),
    setSettings,
    writeChunk: (id, chunk, offset) => writer.writeChunk(id, chunk, offset),
    sealSegment,
    reportCapture: setCapture,
    finishSetup,
    debugExport,
    startLive: () => startLive(),
    stopLive: () => stopLive(),
    liveChunk: (chunk) => pushLiveChunk(chunk),
    startBlur: (source, mime) => startBlur(source, mime),
    writeBlurChunk: (jobId, chunk) => writeBlur(jobId, chunk),
    endBlur: (jobId, reveal) => endBlur(jobId, reveal),
    cancelBlur: (jobId) => cancelBlur(jobId),
    startDetect: () => startDetect(),
    detectFrame: (frame, width, height, conf) => detectFrame(frame, width, height, conf),
    stopDetect: () => stopDetect(),
    openPreview,
    isMainSource: (senderId) => Boolean(mainWindow && !mainWindow.isDestroyed() && mainWindow.webContents.id === senderId),
    getRuntimeInfo: runtimeInfo,
  });
  onLiveChange(pushStatus);
  onLiveViewers((count) => {
    liveViewers = count;
    pushLiveViewers(count, count > 0);
  });
  onLiveKey(() => pushLiveViewers(liveViewers, true));
  openLive();
  const restored = nso.restore();
  const qqStart = qq.start();
  mainWindow = createWindow();
  mainWindow.webContents.on('preload-error', (_event, path, error) => console.error('[preload-error]', path, error));
  mainWindow.webContents.on('did-fail-load', (_event, code, desc, url) => console.error('[did-fail-load]', code, desc, url));
  mainWindow.webContents.on('render-process-gone', (_event, details) => console.error('[render-process-gone]', details.reason));
  mainWindow.webContents.on('console-message', (_event, level, message) => { if (level >= 2) console.error('[renderer]', message); });
  if (!config.setupDone) {
    mainWindow.hide();
    setupWindow = createSetup();
    setupWindow.on('closed', () => { setupWindow = undefined; if (!config.setupDone) app.quit(); });
  }
  if (activatePending) {
    activatePending = false;
    activateWindow();
  }
  await restored;
  await qqStart;
  applyAutoLaunch(config.settings.autoLaunch);
  startTokenKeeper();
  startCacheSweeper();
  await startPoll();
  pushStatus();
  void prepareAccel(config.settings.encoder, { kind: 'quality', quality: config.settings.quality }).then(() => pushStatus());
}

function startCacheSweeper(): void {
  setInterval(() => {
    if (sweepBusy) return;
    sweepBusy = true;
    void sweepCache();
  }, sweepInterval);
}

async function sweepCache(): Promise<void> {
  try {
    const before = store.summary();
    await store.sweepCache(writer.activeParts());
    if (store.summary().count !== before.count) pushStatus();
  } catch {
    void 0;
  } finally {
    sweepBusy = false;
  }
}

function openPreview(): Promise<void> {
  if (!mainWindow || mainWindow.isDestroyed()) return Promise.resolve();
  mainWindow.webContents.executeJavaScript(`window.open(new URL('?preview=1', location.href).href, '_blank', 'popup,width=960,height=580,resizable=yes')`, true).catch(() => undefined);
  return Promise.resolve();
}

function runtimeInfo(): Promise<RuntimeInfo> {
  return app.getGPUInfo('basic').then((info) => {
    const raw = info as { gpuDevice?: Array<{ vendorString?: string; deviceString?: string }> };
    const gpu = (raw.gpuDevice ?? []).map((item) => [item.vendorString, item.deviceString].filter(Boolean).join(' / ')).filter(Boolean);
    return {
      appVersion: app.getVersion(),
      electronVersion: process.versions.electron ?? '',
      chromeVersion: process.versions.chrome ?? '',
      nodeVersion: process.versions.node ?? '',
      platform: process.platform,
      arch: process.arch,
      osRelease: release(),
      gpu,
      gpuStatus: Object.fromEntries(Object.entries(app.getGPUFeatureStatus()).map(([key, value]) => [key, String(value)])),
      hardwareAcceleration: !app.commandLine.hasSwitch('disable-gpu'),
      displays: screen.getAllDisplays().map((item) => `${Math.round(item.size.width)}x${Math.round(item.size.height)}@${Math.round(item.scaleFactor * 100)}%`),
    };
  }).catch(() => ({
    appVersion: app.getVersion(), electronVersion: process.versions.electron ?? '', chromeVersion: process.versions.chrome ?? '', nodeVersion: process.versions.node ?? '',
    platform: process.platform, arch: process.arch, osRelease: release(), gpu: [], gpuStatus: {}, hardwareAcceleration: !app.commandLine.hasSwitch('disable-gpu'), displays: [],
  }));
}

function pushLiveViewers(count: number, key: boolean): void {
  mainWindow?.webContents.send(liveViewersEvent, { viewers: count, key });
}

function applyAutoLaunch(open: boolean): void {
  if (!app.isPackaged) return;
  app.setLoginItemSettings({ openAtLogin: open });
}

function startTokenKeeper(): void {
  setInterval(() => {
    if (tokenKeeperBusy) return;
    tokenKeeperBusy = true;
    void keepTokenFresh().finally(() => { tokenKeeperBusy = false; });
  }, 60000);
}

async function keepTokenFresh(): Promise<void> {
  try {
    if (nso.state === 'connecting' || nso.state === 'unbound') return;
    const token = await getToken();
    if (!token) return;
    if (!isExpired(token, 10 * 60000) && nso.state !== 'error') return;
    const secret = await loadSecret();
    if (!secret.nsoSession) return;
    if (nso.state === 'error' && Date.now() - nsoRetryAt < nsoRetryInterval) return;
    nsoRetryAt = Date.now();
    await nso.refresh(secret.nsoSession);
    await startPoll();
    pushStatus();
  } catch (error) {
    nso.markFailure(error);
    nso.notifyFailure();
    pushStatus();
  }
}

async function finishSetup(): Promise<SetupResult> {
  const status = getStatus();
  if (status.qqState !== 'connected') return { success: false, error: '请先连接 QQBot，再完成初始设置。' };
  if (!status.qqOwner) return { success: false, error: '请在 QQBot 私聊中发送 /bind 绑定用户后再完成初始设置。' };
  const next = { ...getConfig(), setupDone: true };
  await saveConfig(next);
  config = next;
  if (setupWindow && !setupWindow.isDestroyed()) setupWindow.close();
  setupWindow = undefined;
  if (mainWindow && !mainWindow.isDestroyed()) mainWindow.show();
  pushStatus();
  return { success: true };
}

export async function startPoll(): Promise<void> {
  const generation = ++pollGeneration;
  poller?.stop();
  poller = undefined;
  const token = await ensureToken(nso);
  if (!token || generation !== pollGeneration) return;
  const client = new SplatnetClient(token);
  const nextPoller = new BattlePoller(makeQuery(client), pollSecondsFixed * 1000, (match) => !isNew(config.handledIds, match) || !afterBaseline(match, recordBaselineAt), queueMatch, (error) => { console.error(error); pushStatus(); }, (list) => {
    recentMatches = list.slice(0, 1);
    pushStatus();
  });
  poller = nextPoller;
  nextPoller.start();
}

function isNew(handledIds: string[], match: BattleMatch): boolean {
  return dedupeMatches([match], handledIds).length > 0;
}

async function queueMatch(match: BattleMatch): Promise<void> {
  if (!isNew(config.handledIds, match) || pendingMatchIds.has(match.matchId)) return;
  pendingMatchIds.add(match.matchId);
  const clip = clipRange(match);
  const releaseRange = store.holdRange(clip.startAt, clip.endAt);
  logApp(`queue match ${match.matchId} end=${match.endAt}`);
  pushStatus();
  matchQueue = matchQueue.then(() => onMatch(match)).catch((error) => {
    logApp(`queue match error ${match.matchId} ${error instanceof Error ? error.message : String(error)}`);
    console.error(error);
  }).finally(() => {
    releaseRange();
    pendingMatchIds.delete(match.matchId);
    pushStatus();
  });
  await matchQueue;
}

async function onMatch(match: BattleMatch): Promise<void> {
  if (match.endAt <= recordBaselineAt) return;
  const records = await waitForMatch(match);
  const clip = clipRange(match);
  const folder = saveFolder(config.settings.saveDir);
  let output: string | undefined;
  let reason = '';
  let purged = false;
  const releaseRecords = store.holdRecords(records.filter((item) => item.endAt > clip.startAt && item.startAt < clip.endAt));
  try {
    for (let attempt = 0; attempt < 3; attempt++) {
      const current = attempt === 0 ? records : store.records();
      const covered = clipCovered(match, current);
      logApp(`match crop attempt ${match.matchId} attempt=${attempt} records=${current.length} covered=${covered}`);
      if (!covered) {
        if (attempt < 2) await sleepMs(2000);
        continue;
      }
      try {
        output = await cropVideo(current, match, folder, config.settings, clip);
      } catch (error) {
        reason = failureReason(error);
        logApp(`match crop error ${match.matchId} ${reason}`);
      }
      if (!output && !purged && attempt < 2 && await diskShortage(folder)) {
        purged = true;
        reason = '磁盘空间不足，已自动清理全部历史对局录像';
        await purgeArchivedVideos(matchPath).catch(() => undefined);
        refreshArchives();
        continue;
      }
      if (output) break;
      if (attempt < 2) await sleepMs(2000);
    }
  } finally {
    releaseRecords();
  }
  if (!output && retryMatch(match)) {
    logApp(`match crop deferred ${match.matchId}`);
    return;
  }
  if (!output) {
    if (!reason) reason = '画面裁剪或编码失败';
    await qq.notifyText(purged ? `${reason}，本局录像仍保存失败` : `本局录像保存失败：${reason}`).catch(() => undefined);
  }
  const stored = { ...match, videoPath: output };
  matches = [stored, ...matches.filter((item) => item.matchId !== match.matchId)].slice(0, 200);
  await saveMatch(stored, matchPath);
  config = { ...config, handledIds: mergeHandled(config.handledIds, match.matchId) };
  await saveConfig(config);
  logApp(`match crop result ${match.matchId} video=${output ? 'yes' : 'no'}`);
  void schedulePush(stored);
  pushStatus();
}

async function schedulePush(match: BattleMatch): Promise<void> {
  if (!qq.pushEnabled()) return;
  pushState = 'sending';
  pushError = undefined;
  pushStatus();
  try {
    await qq.pushMatch(match);
    pushState = 'idle';
  } catch (error) {
    pushState = 'error';
    pushError = error instanceof Error ? error.message : String(error);
  } finally {
    pushStatus();
  }
}

async function waitForMatch(match: BattleMatch): Promise<VideoRecord[]> {
  const limit = Math.max(5000, segmentSecondsFixed * 1000 + 5000);
  const deadline = Date.now() + limit;
  let records = store.records();
  while (!clipCovered(match, records) && Date.now() < deadline) {
    await sleepMs(1000);
    records = store.records();
  }
  return records;
}

function clipCovered(match: BattleMatch, records: VideoRecord[]): boolean {
  const clip = clipRange(match);
  return coveredMatch({ ...match, startAt: clip.startAt, endAt: clip.endAt }, records);
}

function sleepMs(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function setSettings(raw: unknown): Promise<AppStatus> {
  const settings: RecordSettings = sanitizeSettings(raw, config.settings);
  config = await saveSettings(settings);
  applyAutoLaunch(settings.autoLaunch);
  void prepareAccel(settings.encoder, { kind: 'quality', quality: settings.quality }).then(() => pushStatus());
  pushStatus();
  return getStatus();
}

let purgeGuardAt = 0;

function setCapture(raw: CaptureReport): void {
  const state = String(raw?.recordState ?? '');
  capture = {
    recordState: recordStates.has(state) ? (state as CaptureReport['recordState']) : 'error',
    error: typeof raw?.error === 'string' ? raw.error.slice(0, 300) : undefined,
    width: clampNumber(raw?.width, 0, 7680),
    height: clampNumber(raw?.height, 0, 4320),
    fps: Number.isFinite(Number(raw?.fps)) ? Math.min(240, Math.max(0, Number(raw.fps))) : 0,
    format: typeof raw?.format === 'string' ? raw.format.slice(0, 40) : undefined,
    hasAudio: Boolean(raw?.hasAudio),
  };
  pushStatus();
  void handleCaptureShortage(raw);
}

async function handleCaptureShortage(raw: CaptureReport): Promise<void> {
  if (raw?.recordState !== 'error' || !raw.error || !/磁盘|disk|space|enospc/i.test(raw.error)) return;
  if (Date.now() - purgeGuardAt < 600000) return;
  purgeGuardAt = Date.now();
  const freed = await purgeArchivedVideos(matchPath).catch(() => 0);
  refreshArchives();
  await qq.notifyText(freed > 0 ? '磁盘空间不足导致录制中断，已自动清理全部历史对局录像释放空间' : '磁盘空间不足导致录制中断，请清理磁盘后重新开始录制').catch(() => undefined);
}

function refreshArchives(): void {
  matches = matches.map((item) => (item.videoPath ? { ...item, videoPath: undefined } : item));
  pushStatus();
}

function clampNumber(value: unknown, min: number, max: number): number {
  const number = Number(value);
  return Number.isFinite(number) ? Math.min(max, Math.max(min, Math.round(number))) : min;
}

async function sealSegment(draft: SegmentDraft): Promise<VideoRecord | undefined> {
  const record = await writer.sealSegment(draft, Boolean(config.settings.flipVertical));
  if (record) await store.register(record);
  return record;
}

async function debugExport(): Promise<string | undefined> {
  const end = Date.now();
  const match: BattleMatch = {
    matchId: `debug-${end}`, kind: 'unknown', mode: 'DEBUG', rule: 'DEBUG',
    ...matchClock(end, 60000), result: '', isDisconnected: false, isSalmon: false, rawData: {},
  };
  const output = await cropVideo(store.records(), match, saveFolder(config.settings.saveDir), config.settings, clipRange(match)).catch((error) => { console.error(error); return undefined; });
  if (output) shell.showItemInFolder(output);
  return output;
}

export function getStatus(): AppStatus {
  const visible = mergedRecent();
  const processing = new Set(pendingMatchIds);
  const summary = store ? store.summary() : { count: 0 };
  recentMatches.forEach((match) => {
    if (isNew(config.handledIds, match) && afterBaseline(match, recordBaselineAt) && retryMatch(match)) processing.add(match.matchId);
  });
  return {
    recordState: capture.recordState,
    recordError: capture.error,
    streamWidth: capture.width,
    streamHeight: capture.height,
    streamFps: capture.fps,
    streamFormat: capture.format,
    streamAudio: capture.hasAudio,
    segments: summary.count,
    cacheStart: summary.start,
    cacheEnd: summary.end,
    ...accelSummary(),
    nsoState: nso?.state ?? 'unbound',
    nsoError: nso?.lastError || undefined,
    qqState: qqLoginState ?? qq?.linkState ?? 'unbound',
    qqOwner: getConfig().qqOwner,
    qrCode: qrUrl,
    setupDone: config.setupDone,
    recentMatches: visible,
    processingMatchIds: [...processing],
    latestMatch: visible[0] ?? matches[0],
    pushState,
    pushError,
    settings: config.settings,
    pushOptions: pushEnv(),
    ...liveInfo(),
  };
}

function mergedRecent(): BattleMatch[] {
  return recentMatches.map((match) => matches.find((item) => item.matchId === match.matchId) ?? match);
}

export function pushStatus(): void {
  try {
    const status = getStatus();
    if (mainWindow && !mainWindow.isDestroyed()) mainWindow.webContents.send(appEvent, status);
    if (setupWindow && !setupWindow.isDestroyed()) setupWindow.webContents.send(appEvent, status);
  } catch {
    void 0;
  }
}

function activateWindow(): void {
  if (quitStarted) return;
  const target = !config.setupDone && setupWindow ? setupWindow : mainWindow;
  if (!target || target.isDestroyed()) {
    activatePending = true;
    return;
  }
  if (target.isMinimized()) target.restore();
  if (!target.isVisible()) target.show();
  target.focus();
}

if (!app.requestSingleInstanceLock()) {
  app.quit();
} else {
  app.whenReady().then(() => {
    registerVideoProtocol(() => matches);
    return bootApp().catch((error) => console.error(error));
  });
  app.on('second-instance', () => activateWindow());
  app.on('window-all-closed', () => { if (process.platform !== 'darwin') app.quit(); });
  app.on('before-quit', (event) => {
    poller?.stop();
    qq?.stop();
    qqLogin?.cancel();
    if (quitStarted) return;
    quitStarted = true;
    event.preventDefault();
    const done = async (): Promise<void> => {
      stopDetect();
      await closeLive().catch(() => undefined);
      await clearBlur().catch(() => undefined);
      if (writer) await writer.closeAll();
      if (store) await store.clearCache().catch(() => undefined);
    };
    void done().finally(() => app.quit());
  });
}

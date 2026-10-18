import { app, BrowserWindow, dialog, Menu, nativeImage, protocol, screen, shell } from 'electron';
import { release } from 'node:os';
import { copyFile, mkdir, stat } from 'node:fs/promises';
import { extname, join } from 'node:path';
import { backgroundDir, initPath, matchPath, saveFolder } from './store/path.js';
import { getConfig, loadConfig, saveConfig, saveSettings, startupBackend } from './store/config.js';
import { createWindow, createSetup } from './window.js';
import { registerIpc } from './ipc.js';
import { SegmentStore } from './capture/segment.js';
import { setDesktopAudioHandler } from './capture/desktop.js';
import { SegmentWriter } from './capture/recorder.js';
import { sanitizeSettings } from './capture/settings.js';
import { cropVideo } from './match/crop.js';
import { accelSummary, prepareAccel } from './media/accel.js';
import { cancelBlur, clearBlur, endBlur, startBlur, writeBlur } from './match/blurcopy.js';
import { closeLive, liveInfo, onLiveChange, onLiveKey, onLiveViewers, openLive, pushLiveChunk, startLive, stopLive } from './live/control.js';
import { detectFrame, startDetect, stopDetect } from './detect/engine.js';
import { NsoAccounts } from './nso/login.js';
import { SplatnetClient } from './nso/splatnet.js';
import { makeQuery } from './nso/query.js';
import { BattlePoller } from './nso/poll.js';
import { pushEnv } from './store/env.js';
import { pollSecondsFixed } from '../shared/constants.js';
import { matchKey } from '../shared/nso.js';
import { clipRange, matchClock } from './match/clock.js';
import { diskShortage, failureReason } from './match/notice.js';
import { QqBot } from './qq/bot.js';
import { QqLogin } from './qq/login.js';
import { afterBaseline, coveredMatch, dedupeMatches, mergeHandled, retryMatch } from './match/detect.js';
import { coreConflict, rememberInterval, trimClip, type KnownInterval } from './match/conflict.js';
import { purgeArchivedVideos, saveMatch, listMatches } from './match/archive.js';
import { logApp } from './store/log.js';
import { checkForUpdate, setUpdateNotifier } from './update/service.js';
import { appEvent, liveViewersEvent, sealEvent, updateEvent } from '../shared/events.js';
import { registerVideoProtocol, registerBackgroundProtocol } from './protocol.js';
import type { AppStatus, AudioHealth, BattleMatch, CaptureReport, LinkState, RecordSettings, RuntimeInfo, SegmentDraft, SetupResult, VideoHealth, VideoRecord } from '../shared/types.js';

const nsoRetryInterval = 300000;
const sealWaitMs = 15000;
const sweepInterval = 60000;
const recordStates = new Set(['idle', 'starting', 'recording', 'error']);

const captureBackend = startupBackend();
app.commandLine.appendSwitch('enable-features', captureBackend === 'mf' ? 'PlatformHEVCEncoderSupport,MediaFoundationVideoCapture' : 'PlatformHEVCEncoderSupport');
if (captureBackend !== 'mf') app.commandLine.appendSwitch('disable-features', 'MediaFoundationVideoCapture');

let mainWindow: BrowserWindow | undefined;
let liveViewers = 0;
let setupWindow: BrowserWindow | undefined;
let config = getConfig();
let store: SegmentStore;
let writer: SegmentWriter;
let capture: CaptureReport = { recordState: 'idle', width: 0, height: 0, fps: 0, hasAudio: false };
let nso: NsoAccounts;
let qq: QqBot;
let qqLogin: QqLogin;
const pollers = new Map<string, BattlePoller>();
let tokenKeeperBusy = false;
let sweepBusy = false;
const nsoRetryAt = new Map<string, number>();
let matches: BattleMatch[] = [];
const recentByAccount = new Map<string, BattleMatch[]>();
let recordBaselineAt = Date.now();
let qrUrl = '';
let qqLoginState: LinkState | undefined;
let matchQueue = Promise.resolve();
let bootReady = false;
let syncTimer: NodeJS.Timeout | undefined;
const pendingMatchIds = new Set<string>();
const knownIntervals = new Map<string, KnownInterval>();
let pushState: AppStatus['pushState'] = 'idle';
let pushError: string | undefined;
let quitStarted = false;
let activatePending = false;

protocol.registerSchemesAsPrivileged([{
  scheme: 's3r-video',
  privileges: { standard: true, secure: true, supportFetchAPI: true, stream: true, bypassCSP: true, corsEnabled: true },
}, {
  scheme: 's3r-bg',
  privileges: { standard: true, secure: true, supportFetchAPI: true, bypassCSP: true, corsEnabled: true },
}]);

export async function bootApp(): Promise<void> {
  Menu.setApplicationMenu(null);
  setDesktopAudioHandler();
  recordBaselineAt = Date.now();
  await initPath();
  logApp('app start');
  config = await loadConfig();
  store = new SegmentStore();
  writer = new SegmentWriter();
  await store.openStore();
  matches = (await listMatches(matchPath)).filter((match) => !match.isSalmon && match.kind !== 'salmon');
  const archived = new Map(matches.map((match) => [match.matchId, match]));
  const migrated = config.handledIds.map((id) => {
    if (id.includes(':')) return id;
    const match = archived.get(id);
    return match?.accountId ? matchKey(match) : id;
  });
  const handled = migrated.reduce((ids, key) => mergeHandled(ids, key), [] as string[]);
  if (handled.length !== config.handledIds.length || handled.some((id, index) => id !== config.handledIds[index])) {
    config = { ...config, handledIds: handled };
    await saveConfig(config);
  }
  nso = new NsoAccounts(() => {
    pushStatus();
    scheduleSync();
  });
  qq = new QqBot({ status: getStatus, latest: async () => recentList()[0] ?? matches[0], changed: pushStatus });
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
    pickBackground: pickBackground,
    writeChunk: (id, chunk, offset) => writer.writeChunk(id, chunk, offset),
    sealSegment,
    sealSegments: () => requestSeal(),
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
    togglePreviewFullscreen,
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
  setUpdateNotifier((state) => {
    if (mainWindow && !mainWindow.isDestroyed()) mainWindow.webContents.send(updateEvent, state);
  });
  if (config.settings.updateCheck) void checkForUpdate(config.settings.updateProxy);
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
  await migrateHandledIds();
  await qqStart;
  applyAutoLaunch(config.settings.autoLaunch);
  bootReady = true;
  startTokenKeeper();
  startCacheSweeper();
  await startPoll();
  pushStatus();
  void prepareAccel(config.settings.encoder, { kind: 'quality', quality: config.settings.quality }).then(() => pushStatus());
}

let handledMigrating = false;

async function migrateHandledIds(): Promise<void> {
  if (handledMigrating) return;
  handledMigrating = true;
  try {
    const accounts = nso.statuses();
    const archived = new Map(matches.map((match) => [match.matchId, match]));
    const raw = config.handledIds.filter((id) => !id.includes(':') || id.startsWith('legacy:'));
    if (!raw.length) return;
    const mapped = config.handledIds.map((id) => {
      if (id.startsWith('legacy:')) {
        const matchId = id.slice('legacy:'.length);
        const match = archived.get(matchId);
        if (match?.accountId) return matchKey(match);
        if (accounts.length === 1) return `${accounts[0].accountId}:${matchId}`;
        return id;
      }
      if (id.includes(':')) return id;
      const match = archived.get(id);
      if (match?.accountId) return matchKey(match);
      if (accounts.length === 1) return `${accounts[0].accountId}:${id}`;
      return id;
    });
    const handled = mapped.reduce((ids, key) => mergeHandled(ids, key), [] as string[]);
    if (handled.length === config.handledIds.length && handled.every((id, index) => id === config.handledIds[index])) return;
    config = { ...config, handledIds: handled };
    await saveConfig(config);
    logApp(`migrated handled ids count=${raw.length} accounts=${accounts.length}`);
  } finally {
    handledMigrating = false;
  }
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

function togglePreviewFullscreen(senderId: number): boolean {
  if (!mainWindow || mainWindow.isDestroyed()) return false;
  const preview = BrowserWindow.getAllWindows().find((window) => window.webContents.id === senderId);
  if (!preview || preview.isDestroyed() || preview === mainWindow || !preview.webContents.getURL().endsWith('?preview=1')) return false;
  preview.setFullScreen(!preview.isFullScreen());
  return preview.isFullScreen();
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
      captureBackend,
      displays: screen.getAllDisplays().map((item) => `${Math.round(item.size.width)}x${Math.round(item.size.height)}@${Math.round(item.scaleFactor * 100)}%`),
    };
  }).catch(() => ({
    appVersion: app.getVersion(), electronVersion: process.versions.electron ?? '', chromeVersion: process.versions.chrome ?? '', nodeVersion: process.versions.node ?? '',
    platform: process.platform, arch: process.arch, osRelease: release(), gpu: [], gpuStatus: {}, hardwareAcceleration: !app.commandLine.hasSwitch('disable-gpu'), captureBackend, displays: [],
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
  if (!bootReady) return;
  try {
    for (const account of nso.statuses()) {
      if (!nso.hasAccount(account.accountId) || account.state === 'expired') continue;
      if (!nso.needsRefresh(account.accountId)) continue;
      if (Date.now() < (nsoRetryAt.get(account.accountId) ?? 0)) continue;
      try {
        await nso.refreshAccount(account.accountId);
        nsoRetryAt.delete(account.accountId);
        stopPoller(account.accountId);
      } catch (error) {
        nsoRetryAt.set(account.accountId, Date.now() + nsoRetryInterval);
        nso.markAccountFailure(account.accountId, error);
        nso.notifyFailure();
      }
    }
    await syncPollers();
    pushStatus();
  } catch (error) {
    console.error(error);
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
  for (const id of [...pollers.keys()]) stopPoller(id);
  recentByAccount.clear();
  await syncPollers();
}

let syncBusy = false;
let syncAgain = false;

function scheduleSync(): void {
  if (!bootReady) return;
  if (syncTimer) clearTimeout(syncTimer);
  syncTimer = setTimeout(() => {
    syncTimer = undefined;
    void syncPollers();
  }, 100);
}

async function syncPollers(): Promise<void> {
  if (quitStarted) return;
  if (syncBusy) {
    syncAgain = true;
    return;
  }
  syncBusy = true;
  try {
    do {
      syncAgain = false;
      await migrateHandledIds();
      const statuses = nso.statuses();
      const ids = new Set(statuses.map((item) => item.accountId));
      for (const id of [...pollers.keys()]) if (!ids.has(id)) stopPoller(id);
      for (const id of [...recentByAccount.keys()]) if (!ids.has(id)) recentByAccount.delete(id);
      for (const [key, interval] of knownIntervals) if (!ids.has(interval.accountId)) knownIntervals.delete(key);
      for (const account of statuses) {
        if (account.state === 'expired') {
          stopPoller(account.accountId);
          continue;
        }
        if (!pollers.has(account.accountId)) await startAccountPoll(account.accountId);
      }
    } while (syncAgain);
  } finally {
    syncBusy = false;
  }
  pushStatus();
}

async function startAccountPoll(accountId: string): Promise<void> {
  if (quitStarted) return;
  stopPoller(accountId);
  if (!nso.hasAccount(accountId) || !bootReady) return;
  const token = await nso.ensureAccountToken(accountId);
  if (!token || !nso.hasAccount(accountId)) return;
  const nickname = nso.nicknameOf(accountId);
  const client = new SplatnetClient(token, (next) => nso.updateAccountToken(accountId, next));
  const nextPoller = new BattlePoller(
    makeQuery(client, { accountId, nickname }),
    pollSecondsFixed * 1000,
    (match) => !isNew(config.handledIds, match) || !afterBaseline(match, recordBaselineAt),
    queueMatch,
    (error) => {
      if (!nso.hasAccount(accountId)) return;
      logApp(`poll error account=${accountId} ${error instanceof Error ? error.message : String(error)}`);
      nso.markAccountFailure(accountId, error);
      pushStatus();
    },
    (list) => {
      if (!nso.hasAccount(accountId)) return;
      recentByAccount.set(accountId, list.slice(0, 3));
      nso.markPolled(accountId);
      pushStatus();
    },
  );
  pollers.set(accountId, nextPoller);
  nextPoller.start();
  logApp(`poll start account=${accountId} nickname=${nickname}`);
}

function stopPoller(accountId: string): void {
  const poller = pollers.get(accountId);
  if (!poller) return;
  poller.stop();
  pollers.delete(accountId);
}

function isNew(handledIds: string[], match: BattleMatch): boolean {
  return dedupeMatches([match], handledIds).length > 0;
}

function conflictWith(match: BattleMatch): { key: string; accountId: string; startAt: number; endAt: number } | undefined {
  return coreConflict(match, knownIntervals);
}

function rememberMatch(match: BattleMatch): void {
  rememberInterval(knownIntervals, match);
}

function clipFor(match: BattleMatch): { startAt: number; endAt: number } {
  return trimClip(clipRange(match), match, knownIntervals);
}

async function saveConflict(match: BattleMatch, other: { key: string; accountId: string }): Promise<void> {
  const key = matchKey(match);
  const stored: BattleMatch = {
    ...match,
    videoPath: undefined,
    skipReason: `与账户 ${nso.nicknameOf(other.accountId) || other.accountId} 的对局录像区间重叠，已跳过自动裁剪`,
  };
  matches = [stored, ...matches.filter((item) => matchKey(item) !== key)].slice(0, 200);
  await saveMatch(stored, matchPath);
  config = { ...config, handledIds: mergeHandled(config.handledIds, key) };
  await saveConfig(config);
  logApp(`match conflict key=${key} other=${other.key}`);
  if (match.accountId) nso.markMatch(match.accountId);
  pushStatus();
}

async function queueMatch(match: BattleMatch): Promise<void> {
  if (!match.timeExact || match.duration <= 0 || !match.endAt || !match.accountId) {
    logApp(`match ignored key=${matchKey(match)} reason=incomplete time=${match.timeExact ? 'yes' : 'no'} duration=${match.duration}`);
    return;
  }
  if (!nso.hasAccount(match.accountId)) {
    logApp(`match ignored key=${matchKey(match)} reason=account-removed`);
    return;
  }
  const key = matchKey(match);
  if (!isNew(config.handledIds, match) || pendingMatchIds.has(key)) return;
  pendingMatchIds.add(key);
  rememberMatch(match);
  const clip = clipFor(match);
  const releaseRange = store.holdRange(clip.startAt, clip.endAt);
  logApp(`queue match key=${key} end=${match.endAt}`);
  pushStatus();
  matchQueue = matchQueue.then(async () => {
    await sleepMs(1200);
    if (!match.accountId || !nso.hasAccount(match.accountId)) return;
    const conflict = conflictWith(match);
    if (conflict) {
      await saveConflict(match, conflict);
      return;
    }
    await onMatch(match);
  }).catch((error) => {
    logApp(`queue match error key=${key} ${error instanceof Error ? error.message : String(error)}`);
    console.error(error);
  }).finally(() => {
    releaseRange();
    pendingMatchIds.delete(key);
    pushStatus();
  });
  await matchQueue;
}

async function onMatch(match: BattleMatch): Promise<void> {
  if (!match.accountId || !nso.hasAccount(match.accountId)) return;
  if (match.endAt <= recordBaselineAt) return;
  const earlyConflict = conflictWith(match);
  if (earlyConflict) {
    await saveConflict(match, earlyConflict);
    return;
  }
  const records = await waitForMatch(match);
  const laterConflict = conflictWith(match);
  if (laterConflict) {
    await saveConflict(match, laterConflict);
    return;
  }
  if (!nso.hasAccount(match.accountId)) return;
  const key = matchKey(match);
  const clip = clipFor(match);
  const folder = saveFolder(config.settings.saveDir);
  let output: string | undefined;
  let reason = '';
  let purged = false;
  const releaseRecords = store.holdRecords(records.filter((item) => item.endAt > clip.startAt && item.startAt < clip.endAt));
  try {
    for (let attempt = 0; attempt < 3; attempt++) {
      const current = attempt === 0 ? records : store.records();
      const covered = clipCovered(match, current);
      logApp(`match crop attempt key=${key} attempt=${attempt} records=${current.length} covered=${covered}`);
      if (!covered) {
        if (attempt < 2) await sleepMs(2000);
        continue;
      }
      try {
        output = await cropVideo(current, match, folder, config.settings, clip);
      } catch (error) {
        reason = failureReason(error);
        logApp(`match crop error key=${key} ${reason}`);
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
    logApp(`match crop deferred key=${key}`);
    return;
  }
  if (!output) {
    if (!reason) reason = '画面裁剪或编码失败';
    await qq.notifyText(purged ? `${reason}，本局录像仍保存失败` : `本局录像保存失败：${reason}`).catch(() => undefined);
  }
  const stored = { ...match, videoPath: output };
  matches = [stored, ...matches.filter((item) => matchKey(item) !== key)].slice(0, 200);
  await saveMatch(stored, matchPath);
  config = { ...config, handledIds: mergeHandled(config.handledIds, key) };
  await saveConfig(config);
  logApp(`match crop result key=${key} video=${output ? 'yes' : 'no'}`);
  nso.markMatch(match.accountId);
  if (output) void schedulePush(stored);
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
  const deadline = Date.now() + sealWaitMs;
  requestSeal();
  let records = store.records();
  while (!clipCovered(match, records) && Date.now() < deadline) {
    await sleepMs(1000);
    records = store.records();
  }
  return records;
}

function requestSeal(): void {
  if (mainWindow && !mainWindow.isDestroyed()) mainWindow.webContents.send(sealEvent);
}

function clipCovered(match: BattleMatch, records: VideoRecord[]): boolean {
  const clip = clipFor(match);
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
let captureAudioLog = '';
let captureVideoLog = '';
let captureVideoLogAt: number | undefined;

function setCapture(raw: CaptureReport): void {
  const state = String(raw?.recordState ?? '');
  const previous = captureBrief();
  capture = {
    recordState: recordStates.has(state) ? (state as CaptureReport['recordState']) : 'error',
    error: typeof raw?.error === 'string' ? raw.error.slice(0, 300) : undefined,
    width: clampNumber(raw?.width, 0, 7680),
    height: clampNumber(raw?.height, 0, 4320),
    fps: Number.isFinite(Number(raw?.fps)) ? Math.min(240, Math.max(0, Number(raw.fps))) : 0,
    format: typeof raw?.format === 'string' ? raw.format.slice(0, 40) : undefined,
    pixelFormat: raw?.pixelFormat === 'nv12' || raw?.pixelFormat === 'yuy2' ? raw.pixelFormat : undefined,
    encoder: typeof raw?.encoder === 'string' ? raw.encoder.slice(0, 40) : undefined,
    hasAudio: Boolean(raw?.hasAudio),
    audio: typeof raw?.audio === 'string' ? raw.audio.slice(0, 60) : undefined,
    audioSource: typeof raw?.audioSource === 'string' ? raw.audioSource.slice(0, 40) : undefined,
    audioHealth: captureAudioHealth(raw?.audioHealth),
    videoHealth: captureVideoHealth(raw?.videoHealth),
  };
  const brief = captureBrief();
  if (brief !== previous) logApp(`capture ${brief}${capture.error ? ` error=${capture.error}` : ''}`);
  const health = capture.audioHealth;
  const audioLog = `${capture.audio ?? ''}|${capture.audioSource ?? ''}|${health?.rollbacks ?? 0}|${health?.recoveries ?? 0}|${health?.cuts ?? 0}`;
  if (audioLog !== captureAudioLog) {
    captureAudioLog = audioLog;
    logApp(`capture audio ${capture.audio ?? 'none'} source=${capture.audioSource ?? '-'} rollbacks=${health?.rollbacks ?? 0} recoveries=${health?.recoveries ?? 0} cuts=${health?.cuts ?? 0}`);
  }
  const video = capture.videoHealth;
  const videoLog = video ? `${video.inputFrames}|${video.encodedFrames}|${video.droppedFrames}|${video.queuePeak}` : '';
  const now = Date.now();
  if (videoLog !== captureVideoLog && (captureVideoLogAt === undefined || now - captureVideoLogAt >= 30000)) {
    captureVideoLog = videoLog;
    captureVideoLogAt = now;
    logApp(`capture video input=${video?.inputFrames ?? 0} encoded=${video?.encodedFrames ?? 0} dropped=${video?.droppedFrames ?? 0} queuePeak=${video?.queuePeak ?? 0} audioFps=${health?.fps ?? 0} audioAgeMs=${health?.ageMs ?? 0}`);
  }
  pushStatus();
  void handleCaptureShortage(raw);
}

function captureAudioHealth(raw: AudioHealth | undefined): AudioHealth | undefined {
  if (!raw) return undefined;
  return {
    fps: clampNumber(raw.fps, 0, 1000),
    ageMs: clampNumber(raw.ageMs, 0, 3600000),
    rollbacks: clampNumber(raw.rollbacks, 0, 100000),
    recoveries: clampNumber(raw.recoveries, 0, 100000),
    cuts: clampNumber(raw.cuts, 0, 100000),
  };
}

function captureVideoHealth(raw: VideoHealth | undefined): VideoHealth | undefined {
  if (!raw) return undefined;
  return {
    inputFrames: clampNumber(raw.inputFrames, 0, 1000000000),
    encodedFrames: clampNumber(raw.encodedFrames, 0, 1000000000),
    droppedFrames: clampNumber(raw.droppedFrames, 0, 1000000000),
    queuePeak: clampNumber(raw.queuePeak, 0, 1000000),
  };
}

function captureBrief(): string {
  return `${capture.recordState} ${capture.width}x${capture.height}@${capture.fps} ${capture.format ?? ''} ${capture.encoder ?? ''}${capture.audio ? ` audio=${capture.audio}` : ''}`.trim();
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

async function pickBackground(): Promise<string | undefined> {
  const result = await dialog.showOpenDialog({
    title: '选择背景图片',
    properties: ['openFile'],
    filters: [{ name: '图片', extensions: ['png', 'jpg', 'jpeg', 'webp', 'gif', 'bmp'] }],
  });
  if (result.canceled || !result.filePaths[0]) return undefined;
  const file = result.filePaths[0];
  const ext = extname(file).toLowerCase();
  if (!['.png', '.jpg', '.jpeg', '.webp', '.gif', '.bmp'].includes(ext)) throw new Error('不支持的背景图片格式');
  const info = await stat(file).catch(() => undefined);
  if (!info || info.size > 20 * 1024 * 1024) throw new Error('背景图片超过 20MB 或无法读取');
  if (nativeImage.createFromPath(file).isEmpty()) throw new Error('无法解码该背景图片');
  await mkdir(backgroundDir, { recursive: true });
  const name = `background-${Date.now()}${ext}`;
  const target = join(backgroundDir, name);
  await copyFile(file, target);
  return target;
}

async function debugExport(): Promise<string | undefined> {  const end = Date.now();
  const match: BattleMatch = {
    matchId: `debug-${end}`, kind: 'unknown', mode: 'DEBUG', rule: 'DEBUG',
    ...matchClock(end, 60000), result: '', isDisconnected: false, isSalmon: false, rawData: {},
  };
  const output = await cropVideo(store.records(), match, saveFolder(config.settings.saveDir), config.settings, clipRange(match)).catch((error) => { console.error(error); return undefined; });
  if (output) shell.showItemInFolder(output);
  return output;
}

export function getStatus(): AppStatus {
  const visible = recentList();
  const processing = new Set(pendingMatchIds);
  const summary = store ? store.summary() : { count: 0 };
  visible.forEach((match) => {
    if (isNew(config.handledIds, match) && afterBaseline(match, recordBaselineAt) && retryMatch(match)) processing.add(matchKey(match));
  });
  const accounts = nso?.statuses() ?? [];
  return {
    recordState: capture.recordState,
    recordError: capture.error,
    streamWidth: capture.width,
    streamHeight: capture.height,
    streamFps: capture.fps,
    streamFormat: capture.format,
    streamPixelFormat: capture.pixelFormat,
    streamEncoder: capture.encoder,
    streamAudio: capture.hasAudio,
    streamAudioState: capture.audio,
    streamAudioSource: capture.audioSource,
    streamAudioHealth: capture.audioHealth,
    streamVideoHealth: capture.videoHealth,
    segments: summary.count,
    cacheStart: summary.start,
    cacheEnd: summary.end,
    ...accelSummary(),
    nsoState: nso?.state ?? 'unbound',
    nsoError: nso?.lastError || undefined,
    nsoAccounts: accounts,
    nsoCurrentAccountId: nso?.currentAccountId,
    nsoCurrentNickname: nso?.currentNickname,
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

function recentList(): BattleMatch[] {
  const list = [...recentByAccount.values()].flat().sort((a, b) => b.endAt - a.endAt).slice(0, 8);
  return list.map((match) => matches.find((item) => matchKey(item) === matchKey(match)) ?? match);
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
    registerBackgroundProtocol(() => config.settings.backgroundPath);
    return bootApp().catch((error) => console.error(error));
  });
  app.on('second-instance', () => activateWindow());
  app.on('window-all-closed', () => { if (process.platform !== 'darwin') app.quit(); });
  app.on('before-quit', (event) => {
    for (const id of [...pollers.keys()]) stopPoller(id);
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

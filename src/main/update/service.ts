import { app, net, shell } from 'electron';
import { spawn } from 'node:child_process';
import { createWriteStream } from 'node:fs';
import { chmod, mkdir, rename, rm, stat } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import { publicEnv, updateEnv, userAgent } from '../store/env.js';
import { dataPath } from '../store/path.js';
import { isNewer } from './checker.js';
import { notesOf, pickAsset, releaseUrl, safeFileName, updateUrls, type ReleaseData } from './release.js';
import type { UpdateAsset, UpdateState } from '../../shared/types.js';

const notesLimit = 4000;
const progressIntervalMs = 150;

let state: UpdateState = { current: publicEnv().version, available: false, phase: 'idle', progress: 0, received: 0, total: 0 };
let notifier: (state: UpdateState) => void = () => undefined;
let downloadTask: Promise<UpdateState> | undefined;
let progressAt = 0;

export function setUpdateNotifier(handler: (state: UpdateState) => void): void {
  notifier = handler;
}

export function updateState(): UpdateState {
  return state;
}

export async function checkForUpdate(proxy: boolean): Promise<UpdateState> {
  setState({ phase: 'checking', error: undefined });
  try {
    const release = await releaseInfo(proxy);
    const latest = String(release.tag_name ?? '').replace(/^v/i, '');
    const asset = pickAsset(release.assets ?? [], process.platform, process.arch);
    const available = Boolean(latest) && isNewer(state.current, latest) && Boolean(asset);
    const target = available && asset ? await downloadedTarget(asset) : undefined;
    return setState({
      latest: latest || state.current,
      notes: notesOf(release.body, notesLimit),
      asset: available ? asset : undefined,
      available,
      path: target,
      phase: target ? 'ready' : 'idle',
      progress: target ? 1 : 0,
      received: 0,
      total: asset?.size ?? 0,
      error: undefined,
    });
  } catch (cause) {
    return setState({ available: false, asset: undefined, path: undefined, phase: 'error', error: messageOf(cause) });
  }
}

export function downloadUpdate(proxy: boolean): Promise<UpdateState> {
  downloadTask = downloadTask ?? runDownload(proxy).finally(() => { downloadTask = undefined; });
  return downloadTask;
}

export async function installUpdate(): Promise<UpdateState> {
  const file = state.path;
  if (!file || !(await exists(file))) return setState({ phase: 'error', error: '安装包不存在，请重新下载' });
  setState({ phase: 'installing', error: undefined });
  const failure = await launchInstaller(file);
  if (failure) return setState({ phase: 'ready', error: failure });
  app.quit();
  return updateState();
}

function setState(part: Partial<UpdateState>): UpdateState {
  state = { ...state, ...part };
  notifier(state);
  return state;
}

function reportProgress(part: Partial<UpdateState>): void {
  const now = Date.now();
  if (now - progressAt < progressIntervalMs) return;
  progressAt = now;
  setState(part);
}

async function runDownload(proxy: boolean): Promise<UpdateState> {
  const asset = state.asset;
  if (!state.available || !asset) return state;
  const target = join(dataPath, 'update', safeFileName(asset.name));
  if (state.path === target && (await exists(target))) return setState({ phase: 'ready' });
  setState({ phase: 'downloading', path: undefined, error: undefined, progress: 0, received: 0, total: asset.size });
  progressAt = 0;
  let failure: unknown;
  for (const url of updateUrls(asset.url, updateEnv().proxyPrefix, proxy)) {
    try {
      const received = await saveFile(url, target);
      return setState({ phase: 'ready', path: target, progress: 1, received, total: received });
    } catch (cause) {
      failure = cause;
    }
  }
  await rm(partPath(target), { force: true }).catch(() => undefined);
  return setState({ phase: 'error', error: messageOf(failure), progress: 0, received: 0 });
}

async function saveFile(url: string, target: string): Promise<number> {
  const response = await net.fetch(url, { headers: { 'User-Agent': userAgent } });
  if (!response.ok || !response.body) throw new Error(`下载失败：HTTP ${response.status}`);
  const total = Number(response.headers.get('content-length') ?? 0);
  if (total > 0) setState({ total });
  await mkdir(dirname(target), { recursive: true });
  const part = partPath(target);
  const file = createWriteStream(part);
  const reader = response.body.getReader();
  let received = 0;
  try {
    for (;;) {
      const step = await reader.read();
      if (step.done) break;
      const chunk = Buffer.from(step.value);
      received += chunk.byteLength;
      if (!file.write(chunk)) await new Promise<void>((resolve) => file.once('drain', () => resolve()));
      reportProgress({ received, progress: total > 0 ? Math.min(1, received / total) : 0 });
    }
  } finally {
    await new Promise<void>((resolve) => file.end(() => resolve()));
    await reader.cancel().catch(() => undefined);
  }
  if (received === 0) throw new Error('下载失败：文件为空');
  await rename(part, target);
  return received;
}

async function releaseInfo(proxy: boolean): Promise<ReleaseData> {
  const target = releaseUrl(publicEnv().projectUrl);
  if (!target) throw new Error('未配置项目仓库地址');
  let failure: unknown;
  for (const url of updateUrls(target, updateEnv().proxyPrefix, proxy)) {
    try {
      const response = await net.fetch(url, { headers: { 'User-Agent': userAgent, Accept: 'application/vnd.github+json' } });
      if (!response.ok) throw new Error(`获取更新失败：HTTP ${response.status}`);
      const data = await response.json() as ReleaseData;
      if (typeof data.tag_name === 'string') return data;
      failure = new Error('发行版信息缺少版本号');
    } catch (cause) {
      failure = cause;
    }
  }
  throw failure instanceof Error ? failure : new Error('获取更新失败');
}

async function downloadedTarget(asset: UpdateAsset): Promise<string | undefined> {
  const target = join(dataPath, 'update', safeFileName(asset.name));
  return (await exists(target)) ? target : undefined;
}

function partPath(target: string): string {
  return `${target}.part`;
}

async function exists(file: string): Promise<boolean> {
  return (await stat(file).catch(() => undefined))?.isFile() ?? false;
}

async function launchInstaller(file: string): Promise<string | undefined> {
  try {
    if (process.platform === 'win32' || process.platform === 'linux') {
      if (process.platform === 'linux') await chmod(file, 0o755);
      spawn(file, [], { detached: true, stdio: 'ignore' }).unref();
      return undefined;
    }
    const failure = await shell.openPath(file);
    return failure || undefined;
  } catch (cause) {
    return messageOf(cause);
  }
}

function messageOf(cause: unknown): string {
  const text = (cause instanceof Error ? cause.message : String(cause ?? '')).replace(/^Error invoking remote method '[^']*':\s*(Error:\s*)?/, '').trim();
  return text || '更新失败';
}

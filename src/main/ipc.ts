import { clipboard, dialog, ipcMain, shell, BrowserWindow } from 'electron';
import { copyFile, mkdir } from 'node:fs/promises';
import { basename, dirname } from 'node:path';
import { ipcNames } from '../shared/events.js';
import { blurConfidence } from '../shared/constants.js';
import { clearSecret } from './store/secret.js';
import { matchPath } from './store/path.js';
import { removeMatch } from './match/archive.js';
import { getThumb, dropThumb } from './media/thumbs.js';
import { makeVideoUrl } from './media/video.js';
import type { AppStatus, BattleMatch, BlurJob, CaptureReport, DetectReply, LiveChunk, RuntimeInfo, SegmentDraft, SetupResult, VideoRecord } from '../shared/types.js';
import type { NsoLogin } from './nso/login.js';
import type { QqBot } from './qq/bot.js';

const liveChunkBytes = 8 * 1024 * 1024;

export interface IpcContext {
  getStatus: () => AppStatus;
  getMatches: () => BattleMatch[];
  nso: NsoLogin;
  qq: QqBot;
  startQqLogin: () => void;
  setSettings: (raw: unknown) => Promise<AppStatus>;
  writeChunk: (id: string, chunk: Uint8Array, offset: number) => Promise<boolean>;
  sealSegment: (draft: SegmentDraft) => Promise<VideoRecord | undefined>;
  reportCapture: (report: CaptureReport) => void;
  finishSetup: () => Promise<SetupResult>;
  debugExport: () => Promise<string | undefined>;
  startLive: () => Promise<void>;
  stopLive: () => Promise<void>;
  liveChunk: (chunk: LiveChunk) => void;
  startBlur: (source: string, mime: string) => Promise<BlurJob | undefined>;
  writeBlurChunk: (jobId: string, chunk: Uint8Array) => Promise<boolean>;
  endBlur: (jobId: string, reveal: boolean) => Promise<string | undefined>;
  cancelBlur: (jobId: string) => Promise<void>;
  startDetect: () => Promise<string>;
  detectFrame: (frame: Uint8Array, width: number, height: number, conf: number) => Promise<DetectReply>;
  stopDetect: () => void;
  openPreview: () => Promise<void>;
  isMainSource: (senderId: number) => boolean;
  getRuntimeInfo: () => Promise<RuntimeInfo>;
}

export function registerIpc(context: IpcContext): void {
  ipcMain.handle(ipcNames.getStatus, () => context.getStatus());
  ipcMain.handle(ipcNames.saveSettings, (_event, raw: unknown) => context.setSettings(raw));
  ipcMain.handle(ipcNames.openNsoLogin, () => context.nso.open(BrowserWindow.getFocusedWindow() ?? undefined));
  ipcMain.handle(ipcNames.clearNsoLogin, () => context.nso.clearAndOpen(BrowserWindow.getFocusedWindow() ?? undefined));
  ipcMain.handle(ipcNames.unbindNso, () => context.nso.clear());
  ipcMain.handle(ipcNames.startQqLogin, () => context.startQqLogin());
  ipcMain.handle(ipcNames.unbindQq, () => unbindQq(context.qq));
  ipcMain.handle(ipcNames.listMatches, () => context.getMatches());
  ipcMain.handle(ipcNames.getThumb, (_event, id: string) => getThumb(context.getMatches(), textArg(id)));
  ipcMain.handle(ipcNames.openMatch, (_event, id: string) => openMatch(context.getMatches(), textArg(id)));
  ipcMain.handle(ipcNames.saveMatch, (_event, id: string) => saveMatchFile(context.getMatches(), textArg(id)));
  ipcMain.handle(ipcNames.deleteMatch, (_event, id: string) => deleteMatch(context.getMatches(), textArg(id)));
  ipcMain.handle(ipcNames.getVideoUrl, (_event, id: string) => videoUrl(context.getMatches(), textArg(id)));
  ipcMain.handle(ipcNames.writeChunk, (_event, id: string, chunk: ArrayBuffer, offset: number) => writeChunk(context, id, chunk, offset));
  ipcMain.handle(ipcNames.writeSegment, (_event, draft: SegmentDraft) => context.sealSegment(draft));
  ipcMain.on(ipcNames.reportCapture, (_event, report: CaptureReport) => context.reportCapture(report));
  ipcMain.handle(ipcNames.debugExport, () => context.debugExport());
  ipcMain.handle(ipcNames.openPath, (_event, targetPath: string) => openPathItem(textArg(targetPath)));
  ipcMain.handle(ipcNames.pickFolder, () => pickFolder());
  ipcMain.handle(ipcNames.finishSetup, () => context.finishSetup());
  ipcMain.handle(ipcNames.openLink, (_event, url: string) => openLink(textArg(url)));
  ipcMain.handle(ipcNames.startLive, () => startLive(context));
  ipcMain.handle(ipcNames.stopLive, () => stopLive(context));
  ipcMain.on(ipcNames.liveChunk, (_event, raw: unknown) => {
    const chunk = liveChunkArg(raw);
    if (chunk) context.liveChunk(chunk);
  });
  ipcMain.handle(ipcNames.startBlur, (_event, id: string, mime: string) => startBlur(context, textArg(id), textArg(mime)));
  ipcMain.handle(ipcNames.writeBlurChunk, (_event, jobId: string, chunk: ArrayBuffer) => context.writeBlurChunk(textArg(jobId), chunkBytes(chunk)));
  ipcMain.handle(ipcNames.endBlur, (_event, jobId: string, reveal: unknown) => context.endBlur(textArg(jobId), reveal !== false));
  ipcMain.handle(ipcNames.cancelBlur, (_event, jobId: string) => context.cancelBlur(textArg(jobId)));
  ipcMain.handle(ipcNames.startDetect, () => context.startDetect());
  ipcMain.handle(ipcNames.detectFrame, (_event, frame: ArrayBuffer, width: number, height: number, conf: number) => context.detectFrame(chunkBytes(frame), sizeArg(width), sizeArg(height), rateArg(conf)));
  ipcMain.handle(ipcNames.stopDetect, () => { context.stopDetect(); });
  ipcMain.handle(ipcNames.copyText, (_event, text: string) => { clipboard.writeText(copyTextArg(text)); });
  ipcMain.handle(ipcNames.openPreview, (event) => context.isMainSource(event.sender.id) ? context.openPreview() : undefined);
  ipcMain.handle(ipcNames.getRuntimeInfo, () => context.getRuntimeInfo());
}

function sizeArg(value: unknown): number {
  const size = Math.round(Number(value));
  return Number.isFinite(size) && size > 0 && size <= 8192 ? size : 0;
}

function fpsArg(value: unknown): number {
  const fps = Number(value);
  return Number.isFinite(fps) && fps > 0 && fps <= 240 ? fps : 0;
}

function rateArg(value: unknown): number {
  const rate = Number(value);
  return Number.isFinite(rate) && rate > 0 && rate < 1 ? rate : blurConfidence;
}

function chunkBytes(chunk: unknown): Uint8Array {
  if (chunk instanceof ArrayBuffer) return new Uint8Array(chunk);
  if (ArrayBuffer.isView(chunk)) return new Uint8Array(chunk.buffer, chunk.byteOffset, chunk.byteLength);
  return new Uint8Array(0);
}

function liveChunkArg(raw: unknown): LiveChunk | undefined {
  if (!raw || typeof raw !== 'object') return undefined;
  const chunk = raw as Record<string, unknown>;
  const timestampUs = Math.round(Number(chunk.timestampUs));
  if (chunk.kind === 'video' || chunk.kind === 'audio') {
    const data = bytesArg(chunk.data);
    if (!data) return undefined;
    const stamp = Number.isFinite(timestampUs) && timestampUs > 0 ? timestampUs : 0;
    return chunk.kind === 'video' ? { kind: 'video', key: Boolean(chunk.key), timestampUs: stamp, data } : { kind: 'audio', timestampUs: stamp, data };
  }
  if (chunk.kind !== 'meta') return undefined;
  return {
    kind: 'meta',
    codec: typeof chunk.codec === 'string' ? chunk.codec.slice(0, 40) : '',
    width: sizeArg(chunk.width),
    height: sizeArg(chunk.height),
    fps: fpsArg(chunk.fps),
    channels: Math.min(2, sizeArg(chunk.channels)),
    sampleRate: sizeArg(chunk.sampleRate),
    description: bytesArg(chunk.description),
  };
}

function bytesArg(value: unknown): ArrayBuffer | undefined {
  if (value instanceof ArrayBuffer) return value.byteLength <= liveChunkBytes ? value : undefined;
  if (ArrayBuffer.isView(value) && value.byteLength <= liveChunkBytes) return value.buffer.slice(value.byteOffset, value.byteOffset + value.byteLength) as ArrayBuffer;
  return undefined;
}

async function startLive(context: IpcContext): Promise<AppStatus> {
  await context.startLive();
  return context.getStatus();
}

async function stopLive(context: IpcContext): Promise<AppStatus> {
  await context.stopLive();
  return context.getStatus();
}

async function startBlur(context: IpcContext, id: string, mime: string): Promise<BlurJob | undefined> {
  const match = context.getMatches().find((item) => item.matchId === id);
  if (!match?.videoPath) return undefined;
  return context.startBlur(match.videoPath, mime);
}

function textArg(value: unknown): string {
  return typeof value === 'string' ? value.slice(0, 300) : '';
}

function copyTextArg(value: unknown): string {
  return typeof value === 'string' ? value.slice(0, 16000) : '';
}


async function writeChunk(context: IpcContext, id: string, chunk: ArrayBuffer, offset: number): Promise<boolean> {
  if (!(chunk instanceof ArrayBuffer)) return false;
  const position = Math.round(Number(offset));
  if (!Number.isFinite(position) || position < 0) return false;
  return context.writeChunk(textArg(id), new Uint8Array(chunk), position);
}

async function videoUrl(matches: BattleMatch[], id: string): Promise<string | undefined> {
  const match = matches.find((item) => item.matchId === id);
  return match?.videoPath ? makeVideoUrl(match.matchId) : undefined;
}

async function unbindQq(qq: QqBot): Promise<void> {
  qq.stop();
  await clearSecret(['qqAppId', 'qqSecret']);
}

async function openMatch(matches: BattleMatch[], id: string): Promise<void> {
  const match = matches.find((item) => item.matchId === id);
  if (match?.videoPath) shell.showItemInFolder(match.videoPath);
}

async function openPathItem(targetPath: string): Promise<void> {
  if (targetPath) shell.showItemInFolder(targetPath);
}

async function saveMatchFile(matches: BattleMatch[], id: string): Promise<string | undefined> {
  const match = matches.find((item) => item.matchId === id);
  if (!match?.videoPath) return undefined;
  const result = await dialog.showSaveDialog({ defaultPath: basename(match.videoPath) });
  if (result.canceled || !result.filePath) return undefined;
  await mkdir(dirname(result.filePath), { recursive: true }).catch(() => undefined);
  await copyFile(match.videoPath, result.filePath);
  return result.filePath;
}

async function deleteMatch(matches: BattleMatch[], id: string): Promise<void> {
  const match = matches.find((item) => item.matchId === id);
  if (!match) return;
  await removeMatch(match, matchPath);
  dropThumb(id);
}

async function pickFolder(): Promise<string | undefined> {
  const result = await dialog.showOpenDialog({ properties: ['openDirectory', 'createDirectory'] });
  return result.canceled ? undefined : result.filePaths[0];
}

function openLink(url: string): Promise<void> | undefined {
  if (!/^https?:\/\//.test(url)) return undefined;
  return shell.openExternal(url);
}

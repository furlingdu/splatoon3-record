import { defaultSettings, segmentSecondsFixed } from '../../shared/constants.js';
import type { SegmentDraft } from '../../shared/types.js';
import { SegmentRecorder, type SegmentSeal, type SegmentSpec } from './segment.js';
import { frameWall, seedOrigin } from './stamp.js';
import { openVideoFeed, type VideoFeed } from './videofeed.js';

const minSegmentMs = 5000;

let source: MediaStream | undefined;
let writes: Promise<void> = Promise.resolve();
let generation = 0;
let active = false;
let mime = '';
let codecText = '';
let planned = 'video/mp4';
let segmentMs = minSegmentMs;
let stampOrigin: number | undefined;
let recordQuality = defaultSettings.quality;
let failure: string | undefined;
let audioState: string | undefined;
let audioNotice: ((state: string, detail?: string) => void) | undefined;
let stopping = false;
let feed: VideoFeed | undefined;
let recorder: SegmentRecorder | undefined;
let rotateTimer: number | undefined;
let openedAt = 0;
let sealPending = false;

export function setRecordQuality(quality: number): void {
  recordQuality = quality;
}

export function recordState(): 'idle' | 'recording' | 'error' {
  if (failure) return 'error';
  return active ? 'recording' : 'idle';
}

export function recordError(): string | undefined {
  return failure;
}

export function recordFormat(): string {
  return mime || planned;
}

export function recordEncoder(): string {
  return codecText;
}

export function recordAudio(): string | undefined {
  return audioState;
}

export function planFormat(stream: MediaStream): string {
  if (!mime) planned = stream.getVideoTracks().length ? 'video/mp4' : '';
  return recordFormat();
}

export function clearRecord(): void {
  failure = undefined;
}

export async function startRecord(stream: MediaStream, onAudio?: (state: string, detail?: string) => void): Promise<void> {
  await stopRecord();
  segmentMs = Math.max(minSegmentMs, segmentSecondsFixed * 1000);
  stampOrigin = undefined;
  failure = undefined;
  audioState = undefined;
  audioNotice = onAudio;
  source = stream;
  active = true;
  generation += 1;
  const gen = generation;
  const track = stream.getVideoTracks()[0];
  if (track) feed = openVideoFeed(track);
  const session = await openRecorder(gen);
  if (!session) {
    const message = failure || '当前系统不支持可用的录制编码格式';
    source = undefined;
    active = false;
    throw new Error(message);
  }
  recorder = session;
  openedAt = Date.now();
  scheduleRotate(gen);
}

export function sealNow(): void {
  if (sealPending || stopping || !active || !recorder) return;
  const gen = generation;
  const wait = Math.max(0, minSegmentMs - (Date.now() - openedAt));
  sealPending = true;
  window.setTimeout(() => {
    sealPending = false;
    rotateFile(gen);
  }, wait);
}

export async function stopRecord(): Promise<void> {
  stopping = true;
  generation += 1;
  active = false;
  if (rotateTimer !== undefined) {
    window.clearTimeout(rotateTimer);
    rotateTimer = undefined;
  }
  try {
    await closeRecorder();
    await writes;
  } finally {
    feed?.stop();
    feed = undefined;
    source = undefined;
    recorder = undefined;
    stopping = false;
  }
}

function evenSize(value: number): number {
  return Math.max(2, Math.floor(Math.round(Number(value) || 0) / 2) * 2);
}

function rotateFile(gen: number): void {
  if (stopping || gen !== generation || !recorder) return;
  recorder.rotate();
}

function scheduleRotate(gen: number): void {
  if (rotateTimer !== undefined) window.clearTimeout(rotateTimer);
  rotateTimer = window.setTimeout(() => {
    rotateTimer = undefined;
    rotateFile(gen);
  }, segmentMs);
}

async function openRecorder(gen: number): Promise<SegmentRecorder | undefined> {
  if (stopping || gen !== generation) return undefined;
  const stream = source;
  const track = stream?.getVideoTracks()[0];
  const audioTrack = stream?.getAudioTracks()[0];
  if (!stream || !track) return undefined;
  const size = track.getSettings();
  const spec: SegmentSpec = {
    width: evenSize(size?.width ?? 0),
    height: evenSize(size?.height ?? 0),
    fps: Math.round(Number(size?.frameRate ?? 0)),
    hasAudio: Boolean(audioTrack && audioTrack.readyState === 'live'),
  };
  try {
    const session = await SegmentRecorder.open(track, spec.hasAudio ? audioTrack : undefined, recordQuality, spec, {
      onError: (message) => { failure = message; },
      onAudio: (state, detail) => {
        audioState = detail ? `${state}:${detail}` : state;
        audioNotice?.(state, detail);
      },
      onData: (id, data, position) => {
        enqueue(() => window.recordApi.writeChunk(id, partBytes(data), position).then((stored) => {
          if (!stored) failure = failure || '缓存写入失败，请检查磁盘空间';
        }));
      },
      onSeal: (seal) => { enqueue(() => sealSegment(seal)); },
      onRotate: () => {
        openedAt = Date.now();
        scheduleRotate(gen);
      },
    }, feed);
    if (stopping || gen !== generation) {
      await session.close().catch(() => undefined);
      return undefined;
    }
    const firstUs = session.firstTimestamp();
    const now = Date.now();
    stampOrigin = seedOrigin(stampOrigin, now, firstUs);
    failure = undefined;
    const info = session.info();
    mime = info.mime;
    planned = mime;
    codecText = `${info.mime.split('codecs=')[1] || info.codec} ${info.hardware ? '硬编' : '软编'}`;
    return session;
  } catch (cause) {
    if (gen === generation && !stopping) failure = errorText(cause);
    return undefined;
  }
}

function partBytes(data: Uint8Array): ArrayBuffer {
  const part = new Uint8Array(data.byteLength);
  part.set(data);
  return part.buffer;
}

async function sealSegment(seal: SegmentSeal): Promise<void> {
  const now = Date.now();
  const draft: SegmentDraft = {
    id: seal.id,
    ext: seal.info.ext,
    startAt: frameWall(stampOrigin, seal.firstUs, now),
    endAt: seal.endUs === undefined ? now : frameWall(stampOrigin, seal.endUs, now),
    width: seal.spec.width,
    height: seal.spec.height,
    fps: seal.spec.fps,
    hasAudio: seal.spec.hasAudio,
    encoder: seal.info.codec,
  };
  await window.recordApi.writeSegment(draft).catch(() => undefined);
}

async function closeRecorder(): Promise<void> {
  const session = recorder;
  recorder = undefined;
  if (!session) return;
  try {
    await session.close();
  } catch (cause) {
    failure = failure || errorText(cause);
  }
}

function enqueue(task: () => Promise<unknown>): void {
  writes = writes.then(task).then(() => undefined).catch((cause) => {
    failure = failure || errorText(cause);
  });
}

function errorText(cause: unknown): string {
  const detail = cause as { error?: { message?: string; name?: string }; message?: string; name?: string };
  return detail?.message || detail?.error?.message || detail?.error?.name || detail?.name || '录制中断';
}

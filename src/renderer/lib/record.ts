import { defaultSettings, segmentSecondsFixed } from '../../shared/constants.js';
import type { SegmentDraft } from '../../shared/types.js';
import { SegmentEncoder, type SegmentInfo, type SegmentSpec } from './segment.js';

interface PendingSegment {
  id: string;
  startAt: number;
  endAt?: number;
  spec: SegmentSpec;
}

interface SegmentRun {
  encoder: SegmentEncoder;
  segment: PendingSegment;
  rotateTimer?: number;
  closeTimer?: number;
  flushed: () => Promise<void>;
}

const minSegmentMs = 5000;
const boundaryDelayMs = 1000;
const stopPadMs = 300;
const rotateRetryMs = 1000;

let source: MediaStream | undefined;
let queue = Promise.resolve();
let counter = 0;
let generation = 0;
let active = false;
let mime = '';
let planned = 'video/mp4';
let segmentMs = minSegmentMs;
let recordQuality = defaultSettings.quality;
let failure: string | undefined;
let stopping = false;
const live = new Set<SegmentRun>();

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

export function planFormat(stream: MediaStream): string {
  if (!mime) planned = stream.getVideoTracks().length ? 'video/mp4' : '';
  return recordFormat();
}

export function clearRecord(): void {
  failure = undefined;
}

export async function startRecord(stream: MediaStream): Promise<void> {
  await stopRecord();
  segmentMs = Math.max(minSegmentMs, segmentSecondsFixed * 1000);
  failure = undefined;
  source = stream;
  active = true;
  generation += 1;
  const run = await openEncoder(generation);
  if (!run) {
    const message = failure || '当前系统不支持可用的录制编码格式';
    source = undefined;
    active = false;
    throw new Error(message);
  }
}

export async function stopRecord(): Promise<void> {
  stopping = true;
  generation += 1;
  active = false;
  try {
    await closeRecorder();
    await queue;
  } finally {
    source = undefined;
    stopping = false;
  }
}

function evenSize(value: number): number {
  return Math.max(2, Math.floor(Math.round(Number(value) || 0) / 2) * 2);
}

async function openEncoder(gen: number): Promise<SegmentRun | undefined> {
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
  const segment: PendingSegment = { id: nextId(), startAt: Date.now(), spec };
  let pending = Promise.resolve();
  try {
    const encoder = await SegmentEncoder.open(track, spec.hasAudio ? audioTrack : undefined, recordQuality, spec, {
      onError: (message) => { failure = message; },
      onData: (data, position) => {
        pending = pending
          .then(() => window.recordApi.writeChunk(segment.id, partBytes(data), position))
          .then((stored) => { if (!stored) failure = failure || '缓存写入失败，请检查磁盘空间'; })
          .catch((cause) => { failure = failure || errorText(cause); });
      },
    });
    if (stopping || gen !== generation) {
      await encoder.close().catch(() => undefined);
      return undefined;
    }
    segment.startAt = Date.now();
    failure = undefined;
    const run: SegmentRun = { encoder, segment, flushed: () => pending };
    live.add(run);
    mime = encoder.info().mime;
    planned = mime;
    run.rotateTimer = window.setTimeout(() => {
      run.rotateTimer = undefined;
      if (gen === generation) void rotateSegment(run, gen);
    }, segmentMs);
    return run;
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

async function rotateSegment(run: SegmentRun, gen: number): Promise<void> {
  if (stopping || gen !== generation) return;
  const next = await openEncoder(gen);
  if (!next) {
    if (stopping || gen !== generation) return;
    run.rotateTimer = window.setTimeout(() => {
      run.rotateTimer = undefined;
      if (gen === generation) void rotateSegment(run, gen);
    }, rotateRetryMs);
    return;
  }
  const boundary = next.segment.startAt + boundaryDelayMs;
  run.segment.endAt = boundary;
  run.closeTimer = window.setTimeout(() => {
    run.closeTimer = undefined;
    void closeRun(run);
  }, Math.max(0, boundary + stopPadMs - Date.now()));
}

async function closeRun(run: SegmentRun): Promise<void> {
  if (run.rotateTimer !== undefined) {
    window.clearTimeout(run.rotateTimer);
    run.rotateTimer = undefined;
  }
  if (run.closeTimer !== undefined) {
    window.clearTimeout(run.closeTimer);
    run.closeTimer = undefined;
  }
  live.delete(run);
  const endAt = run.segment.endAt ?? Date.now();
  const info = run.encoder.info();
  try {
    await run.encoder.close();
    await run.flushed();
  } catch (cause) {
    failure = failure || errorText(cause);
    return;
  }
  queue = queue
    .then(() => sealSegment(run.segment, endAt, info))
    .catch((error) => {
      failure = errorText(error);
    });
}

async function closeRecorder(): Promise<void> {
  const runs = [...live].sort((a, b) => a.segment.startAt - b.segment.startAt);
  const now = Date.now();
  for (const run of runs) {
    if (run.segment.endAt === undefined || run.segment.endAt > now) run.segment.endAt = now;
  }
  await Promise.all(runs.map((run) => closeRun(run)));
}

async function sealSegment(segment: PendingSegment, endAt: number, info: SegmentInfo): Promise<void> {
  const draft: SegmentDraft = {
    id: segment.id,
    ext: info.ext,
    startAt: segment.startAt,
    endAt,
    width: segment.spec.width,
    height: segment.spec.height,
    fps: segment.spec.fps,
    hasAudio: segment.spec.hasAudio,
    encoder: info.codec,
  };
  await window.recordApi.writeSegment(draft).catch(() => undefined);
}

function errorText(cause: unknown): string {
  const detail = cause as { error?: { message?: string; name?: string }; message?: string; name?: string };
  return detail?.message || detail?.error?.message || detail?.error?.name || detail?.name || '录制中断';
}

function nextId(): string {
  counter += 1;
  return `seg${Date.now().toString(36)}${counter.toString(36)}`.toLowerCase();
}

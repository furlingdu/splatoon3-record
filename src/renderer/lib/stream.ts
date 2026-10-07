import type { LiveChunk } from '../../shared/types.js';

interface StreamOptions {
  canvas: HTMLCanvasElement;
  source?: MediaStream;
  width: number;
  height: number;
  fps: number;
  bitrate: number;
  onError: (message: string) => void;
}

const keyIntervalMs = 1000;
const maxQueue = 4;
const audioBatchMs = 20;

let encoder: VideoEncoder | undefined;
let codec = '';
let codecText = '';
let description: ArrayBuffer | undefined;
let metaSent = false;
let pendingKey = false;
let lastKey = 0;
let sentBytes = 0;
let running = false;
let currentOptions: StreamOptions | undefined;
let audioReader: ReadableStreamDefaultReader<AudioData> | undefined;
let audioPending: Float32Array[] = [];
let audioFrames = 0;
let audioChannels = 0;
let audioRate = 48000;
let delayMs = 0;
let audioQueue: { due: number; data: ArrayBuffer }[] = [];
let audioTimer = 0;

export function streamCodec(): string {
  return codecText;
}

export function streamBytes(): number {
  return sentBytes;
}

export function streamOpen(): boolean {
  return running;
}

export function setStreamDelay(ms: number): void {
  const value = Math.round(Number(ms));
  delayMs = Number.isFinite(value) ? Math.max(0, Math.min(500, value)) : 0;
}

export async function openStream(options: StreamOptions): Promise<void> {
  closeStream();
  const skipped = new Set<string>();
  let selected: { encoder: VideoEncoder; config: VideoEncoderConfig } | undefined;
  for (;;) {
    const support = await chooseCodec(options.width, options.height, options.fps, options.bitrate, skipped);
    if (!support) break;
    const config: VideoEncoderConfig = {
      codec: support.codec,
      width: options.width,
      height: options.height,
      bitrate: options.bitrate,
      framerate: options.fps,
      hardwareAcceleration: support.acceleration,
      latencyMode: 'realtime',
      bitrateMode: support.bitrateMode,
    };
    const next = new VideoEncoder({
      output: (chunk, metadata) => {
        if (encoder === next) output(options, chunk, metadata);
      },
      error: (cause) => {
        if (encoder !== next) return;
        options.onError(cause.message || '直播编码中断');
        closeStream();
      },
    });
    try {
      next.configure(config);
      selected = { encoder: next, config };
      break;
    } catch {
      next.close();
      skipped.add(`${support.codec}:${support.acceleration}:${support.bitrateMode}`);
    }
  }
  if (!selected) throw new Error('没有可用的直播编码器，请检查显卡驱动');
  encoder = selected.encoder;
  codec = selected.config.codec;
  codecText = `${codec} ${selected.config.hardwareAcceleration === 'prefer-hardware' ? '硬编' : '软编'}`;
  running = true;
  pendingKey = true;
  lastKey = 0;
  sentBytes = 0;
  metaSent = false;
  description = undefined;
  currentOptions = options;
  startAudio(options);
}

export function closeStream(): void {
  running = false;
  currentOptions = undefined;
  const active = encoder;
  encoder = undefined;
  if (active) {
    try {
      active.close();
    } catch {
      void 0;
    }
  }
  const reader = audioReader;
  audioReader = undefined;
  if (reader) void reader.cancel().catch(() => undefined);
  audioPending = [];
  audioFrames = 0;
  audioChannels = 0;
  audioRate = 48000;
  delayMs = 0;
  audioQueue = [];
  if (audioTimer) {
    window.clearTimeout(audioTimer);
    audioTimer = 0;
  }
  metaSent = false;
  description = undefined;
  codecText = '';
  sentBytes = 0;
}

export function encodeFrame(canvas: HTMLCanvasElement): void {
  const active = encoder;
  if (!running || !active || active.state !== 'configured') return;
  if (!audioReader && currentOptions) startAudio(currentOptions);
  const now = performance.now();
  if (active.encodeQueueSize > maxQueue) {
    pendingKey = true;
    return;
  }
  const key = pendingKey || now - lastKey >= keyIntervalMs;
  if (key) {
    pendingKey = false;
    lastKey = now;
  }
  const frame = new VideoFrame(canvas, { timestamp: Math.round(now * 1000) });
  try {
    active.encode(frame, { keyFrame: key });
  } finally {
    frame.close();
  }
}

export function requestKey(): void {
  pendingKey = true;
}

function output(options: StreamOptions, chunk: EncodedVideoChunk, metadata?: EncodedVideoChunkMetadata): void {
  if (!running) return;
  if (!metaSent) {
    description = bytesOf(metadata?.decoderConfig?.description);
    metaSent = true;
    sendMeta(options);
  }
  const data = new ArrayBuffer(chunk.byteLength);
  chunk.copyTo(data);
  sentBytes += chunk.byteLength;
  post({ kind: 'video', key: chunk.type === 'key', timestampUs: Math.round(chunk.timestamp), data });
}

function sendMeta(options: StreamOptions): void {
  post({
    kind: 'meta',
    codec,
    width: options.width,
    height: options.height,
    fps: options.fps,
    channels: audioChannels,
    sampleRate: audioRate,
    description,
  });
}

function startAudio(options: StreamOptions): void {
  const track = options.source?.getAudioTracks().find((item) => item.readyState === 'live');
  if (!track || typeof MediaStreamTrackProcessor === 'undefined') return;
  try {
    const processor = new MediaStreamTrackProcessor({ track });
    audioReader = processor.readable.getReader();
    track.addEventListener('ended', () => {
      const reader = audioReader;
      audioReader = undefined;
      if (reader) void reader.cancel().catch(() => undefined);
    }, { once: true });
    void pumpAudio(options);
  } catch {
    audioReader = undefined;
  }
}

async function pumpAudio(options: StreamOptions): Promise<void> {
  const reader = audioReader;
  if (!reader) return;
  for (;;) {
    const step = await reader.read().catch(() => ({ done: true, value: undefined }) as ReadableStreamReadResult<AudioData>);
    if (step.done || !step.value) return;
    const data = step.value;
    try {
      if (!running) return;
      collectAudio(options, data);
    } finally {
      data.close();
    }
  }
}

function collectAudio(options: StreamOptions, data: AudioData): void {
  if (!audioChannels) {
    audioChannels = Math.min(2, data.numberOfChannels);
    audioRate = data.sampleRate || 48000;
    if (metaSent) sendMeta(options);
  }
  audioPending.push(interleave(data));
  audioFrames += data.numberOfFrames;
  if (audioFrames >= Math.round((audioRate * audioBatchMs) / 1000)) flushAudio();
}

function flushAudio(): void {
  if (!audioPending.length) return;
  let total = 0;
  for (const item of audioPending) total += item.length;
  const merged = new Float32Array(total);
  let offset = 0;
  for (const item of audioPending) {
    merged.set(item, offset);
    offset += item.length;
  }
  audioPending = [];
  audioFrames = 0;
  const data = merged.buffer;
  if (delayMs <= 0) {
    post({ kind: 'audio', timestampUs: 0, data });
    return;
  }
  audioQueue.push({ due: performance.now() + delayMs, data });
  if (!audioTimer) audioTimer = window.setTimeout(releaseAudio, delayMs);
}

function releaseAudio(): void {
  audioTimer = 0;
  const now = performance.now();
  const split = splitDue(audioQueue, now);
  audioQueue = split.rest;
  for (const item of split.ready) post({ kind: 'audio', timestampUs: 0, data: item.data });
  if (audioQueue.length) audioTimer = window.setTimeout(releaseAudio, Math.max(1, Math.round(audioQueue[0].due - now)));
}

export function splitDue<T extends { due: number }>(items: T[], now: number): { ready: T[]; rest: T[] } {
  const ready: T[] = [];
  const rest: T[] = [];
  for (const item of items) {
    if (item.due <= now) ready.push(item);
    else rest.push(item);
  }
  return { ready, rest };
}

function interleave(data: AudioData): Float32Array {
  const frames = data.numberOfFrames;
  const channels = Math.max(1, Math.min(2, data.numberOfChannels));
  const plane = new Float32Array(frames);
  const merged = new Float32Array(frames * channels);
  for (let channel = 0; channel < channels; channel += 1) {
    data.copyTo(plane, { planeIndex: channel, format: 'f32-planar' });
    for (let index = 0; index < frames; index += 1) merged[index * channels + channel] = plane[index];
  }
  return merged;
}

async function chooseCodec(width: number, height: number, fps: number, bitrate: number, skipped: Set<string>): Promise<{ codec: string; acceleration: HardwareAcceleration; bitrateMode: VideoEncoderBitrateMode } | undefined> {
  if (typeof VideoEncoder === 'undefined' || typeof VideoDecoder === 'undefined') return undefined;
  const rate = width * height * Math.max(1, fps);
  const avc = rate > 1920 * 1080 * 60 ? 'avc1.640034' : rate >= 1920 * 1080 * 30 ? 'avc1.64002A' : 'avc1.640028';
  const candidates = ['hvc1.1.6.L150.B0', 'hev1.1.6.L150.B0', avc, 'avc1.640033', 'avc1.64002A', 'avc1.640028'];
  for (const candidate of Array.from(new Set(candidates))) {
    let decodable = false;
    for (const acceleration of ['prefer-hardware', 'no-preference'] as HardwareAcceleration[]) {
      const support = await VideoDecoder.isConfigSupported({ codec: candidate, codedWidth: width, codedHeight: height, optimizeForLatency: true, hardwareAcceleration: acceleration }).catch(() => undefined);
      if (support?.supported) {
        decodable = true;
        break;
      }
    }
    if (!decodable) continue;
    for (const acceleration of ['prefer-hardware', 'no-preference'] as HardwareAcceleration[]) {
      for (const mode of ['constant', 'variable'] as VideoEncoderBitrateMode[]) {
        if (skipped.has(`${candidate}:${acceleration}:${mode}`)) continue;
        const support = await VideoEncoder.isConfigSupported({
          codec: candidate,
          width,
          height,
          bitrate,
          framerate: fps,
          bitrateMode: mode,
          hardwareAcceleration: acceleration,
          latencyMode: 'realtime',
        }).catch(() => undefined);
        if (support?.supported) return { codec: candidate, acceleration, bitrateMode: mode };
      }
    }
  }
  return undefined;
}

function bytesOf(value: AllowSharedBufferSource | undefined): ArrayBuffer | undefined {
  if (!value) return undefined;
  if (value instanceof ArrayBuffer) return value;
  const view = value as ArrayBufferView;
  return view.buffer.slice(view.byteOffset, view.byteOffset + view.byteLength) as ArrayBuffer;
}

function post(chunk: LiveChunk): void {
  window.recordApi.liveChunk(chunk);
}

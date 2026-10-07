import { blurConfidence, detectFrameWidth, detectWorkers } from '../../shared/constants.js';

export interface DetectBox {
  x: number;
  y: number;
  width: number;
  height: number;
}

export interface DetectResult {
  boxes: DetectBox[];
  ms: number;
}

let device = '';
let failure = '';
let ready = false;
let starting: Promise<void> | undefined;
let running = 0;
let slots = 0;
const freeSlots: number[] = [];
const waiters: ((index: number) => void)[] = [];
const frames: { canvas: HTMLCanvasElement; ctx: CanvasRenderingContext2D }[] = [];
let frameWidth = detectFrameWidth;
let epoch = 0;

export function detectDevice(): string {
  return device;
}

export function setDetectWidth(width: number): void {
  frameWidth = Math.min(detectFrameWidth, Math.max(480, Math.round(width)));
}

export function detectFailure(): string {
  return failure;
}

export function detectRunning(): boolean {
  return running > 0;
}

export function modelReady(): boolean {
  return ready;
}

export function unloadModel(): void {
  epoch += 1;
  ready = false;
  device = '';
  failure = '';
  starting = undefined;
  void window.recordApi.stopDetect().catch(() => undefined);
}

export function loadModel(): Promise<void> {
  if (ready) return Promise.resolve();
  if (starting) return starting;
  const mine = epoch;
  starting = window.recordApi.startDetect()
    .then((value) => {
      if (mine !== epoch) {
        void window.recordApi.stopDetect().catch(() => undefined);
        return;
      }
      device = value || 'CPU';
      failure = '';
      ready = true;
    })
    .catch((cause) => {
      if (mine !== epoch) return;
      ready = false;
      failure = messageOf(cause);
      throw new Error(failure, { cause });
    })
    .finally(() => {
      if (mine === epoch) starting = undefined;
    });
  return starting;
}

export function detectNicknames(source: HTMLCanvasElement | HTMLVideoElement): Promise<DetectResult> {
  return acquireSlot().then(async (index) => {
    try {
      return await inferFrame(source, index);
    } finally {
      releaseSlot(index);
    }
  });
}

function acquireSlot(): Promise<number> {
  const free = freeSlots.pop();
  if (free !== undefined) return Promise.resolve(free);
  if (slots < detectWorkers) return Promise.resolve(slots++);
  return new Promise((resolve) => waiters.push(resolve));
}

function releaseSlot(index: number): void {
  const next = waiters.shift();
  if (next) next(index);
  else freeSlots.push(index);
}

async function inferFrame(source: HTMLCanvasElement | HTMLVideoElement, index: number): Promise<DetectResult> {
  running += 1;
  try {
    await loadModel();
    if (!ready) return { boxes: [], ms: 0 };
    const width = source instanceof HTMLVideoElement ? source.videoWidth : source.width;
    const height = source instanceof HTMLVideoElement ? source.videoHeight : source.height;
    const shot = shrinkFrame(source, width, height, index);
    if (!shot) return { boxes: [], ms: 0 };
    const image = shot.ctx.getImageData(0, 0, shot.width, shot.height);
    const data = image.data;
    const buffer = data.byteOffset === 0 && data.byteLength === data.buffer.byteLength
      ? data.buffer
      : data.buffer.slice(data.byteOffset, data.byteOffset + data.byteLength);
    const reply = await window.recordApi.detectFrame(buffer as ArrayBuffer, shot.width, shot.height, blurConfidence);
    const scale = width / shot.width;
    return { boxes: reply.boxes.map((box) => growBox(box, scale)), ms: reply.ms };
  } finally {
    running -= 1;
  }
}

function shrinkFrame(source: HTMLCanvasElement | HTMLVideoElement, width: number, height: number, index: number): { ctx: CanvasRenderingContext2D; width: number; height: number } | undefined {
  if (!width || !height) return undefined;
  while (frames.length <= index) {
    const canvas = document.createElement('canvas');
    const ctx = canvas.getContext('2d', { willReadFrequently: true });
    if (!ctx) return undefined;
    frames.push({ canvas, ctx });
  }
  const { canvas, ctx } = frames[index];
  const ratio = Math.min(1, frameWidth / Math.max(width, height));
  const targetWidth = Math.max(1, Math.round(width * ratio));
  const targetHeight = Math.max(1, Math.round(height * ratio));
  if (canvas.width !== targetWidth) canvas.width = targetWidth;
  if (canvas.height !== targetHeight) canvas.height = targetHeight;
  ctx.drawImage(source, 0, 0, targetWidth, targetHeight);
  return { ctx, width: targetWidth, height: targetHeight };
}

function growBox(box: DetectBox, scale: number): DetectBox {
  if (scale === 1) return box;
  return {
    x: box.x * scale,
    y: box.y * scale,
    width: box.width * scale,
    height: box.height * scale,
  };
}

function messageOf(cause: unknown): string {
  const detail = (cause ?? {}) as { message?: string; name?: string };
  const text = (cause instanceof Error ? cause.message : String(cause ?? '')).replace(/^Error invoking remote method '[^']*':\s*(Error:\s*)?/, '').trim();
  return text || detail.name || '推理后端启动失败';
}

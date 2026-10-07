import { useEffect, useState } from 'react';
import { liveBitrateBps } from '../../shared/bitrate.js';
import { detectFrameWidth, detectWorkers } from '../../shared/constants.js';
import { activeStream, previewStream, streamInfo } from './device.js';
import { createFramePump } from './framepump.js';
import { blurBoxes, fitBoxes, flipBoxes, mergeBoxes, overlayBoxes } from './blur.js';
import { detectDevice, detectFailure, detectNicknames, loadModel, modelReady, setDetectWidth, unloadModel } from './detect.js';
import { updateTracks } from './track.js';
import { closeStream, encodeFrame, openStream, requestKey, setStreamDelay, streamBytes, streamCodec, streamOpen } from './stream.js';
import type { DetectBox } from './detect.js';
import type { TrackBox } from './track.js';
import type { AppStatus, RecordSettings } from '../../shared/types.js';
export interface LiveView {
  streaming: boolean;
  starting: boolean;
  blurOn: boolean;
  debugBoxes: boolean;
  drawFps: number;
  inferFps: number;
  boxes: number;
  device: string;
  viewers: number;
  codec: string;
  rate: number;
  error?: string;
}

const stageStyle = 'position:fixed;left:-10000px;top:0;width:2px;height:2px;overflow:hidden;pointer-events:none';
const detectSlowMs = 50;
const detectFastMs = 30;
const detectMinWidth = 480;
const trackLimit = 20;
const readyLimit = 4;
const pendingLimit = detectWorkers + readyLimit;

interface FrameSlot {
  canvas: HTMLCanvasElement;
  ctx: CanvasRenderingContext2D;
  at: number;
}

interface ReadyFrame {
  slot: FrameSlot;
  boxes: DetectBox[];
  sequence: number;
}

let stage: HTMLDivElement | undefined;
let video: HTMLVideoElement | undefined;
let canvas: HTMLCanvasElement | undefined;
let brush: CanvasRenderingContext2D | null = null;
let live = false;
let stopFrames: (() => void) | undefined;
let rateTimer = 0;
let loop = false;
let mounted = false;
let starting = false;
let blurOn = false;
let debugBoxes = false;
let flip = false;
let tracks: TrackBox[] = [];
let error = '';
let drawn = 0;
let inferred = 0;
let drawRate = 0;
let inferRate = 0;
let liveSettings: RecordSettings | undefined;
let viewers = 0;
let rateMbps = 0;
let sampleBytes = 0;
let sampleAt = 0;
let viewersBound = false;
let detectAge = 0;
let detectWidth = detectFrameWidth;
let nextSequence = 0;
let nextPresentSequence = 0;
let detectEpoch = 0;
const pendingFrames = new Set<number>();
const completedFrames = new Map<number, ReadyFrame | undefined>();
let ready: ReadyFrame[] = [];
let readyWidth = 0;
let readyHeight = 0;
let shownSlot: FrameSlot | undefined;
let lastBoxes: DetectBox[] = [];
const framePool: FrameSlot[] = [];
const listeners = new Set<(view: LiveView) => void>();

export function liveView(): LiveView {
  return {
    streaming: live,
    starting,
    blurOn,
    debugBoxes,
    drawFps: drawRate,
    inferFps: inferRate,
    boxes: tracks.length,
    device: detectDevice(),
    viewers,
    codec: streamCodec(),
    rate: rateMbps,
    error: error || detectFailure() || undefined,
  };
}

export function useLive(status?: RecordSettings): LiveView {
  const [view, setView] = useState<LiveView>(liveView);
  useEffect(() => {
    const listener = (): void => setView(liveView());
    listeners.add(listener);
    listener();
    return () => {
      listeners.delete(listener);
    };
  }, []);
  useEffect(() => {
    if (status) liveSettings = status;
    const nextBlur = Boolean(status?.blurNickname);
    if (blurOn !== nextBlur) {
      blurOn = nextBlur;
      if (!nextBlur) {
        tracks = [];
        debugBoxes = false;
        error = '';
        detectEpoch += 1;
        clearFrames();
      }
      syncDetect();
      emit();
    }
    flip = Boolean(status?.flipVertical);
  }, [status, status?.blurNickname, status?.flipVertical]);
  return view;
}

export function setBlurEnabled(on: boolean): void {
  if (blurOn === on) return;
  blurOn = on;
  if (!on) {
    tracks = [];
    debugBoxes = false;
    error = '';
    detectEpoch += 1;
    clearFrames();
  }
  syncDetect();
  emit();
}

function blurActive(): boolean {
  return live || mounted;
}

function syncDetect(): void {
  if (blurOn && blurActive()) void loadModel().catch(() => undefined);
  else unloadModel();
}

export function setDebugBoxes(on: boolean): void {
  if (debugBoxes === on) return;
  debugBoxes = on;
  emit();
}

export function liveError(): string {
  return error;
}

export function liveStreaming(): boolean {
  return live;
}

export function mountLive(container: HTMLElement): void {
  bindViewers();
  startLoop();
  mounted = true;
  if (canvas && canvas.parentElement !== container) container.appendChild(canvas);
  syncDetect();
  emit();
}

export function unmountLive(): void {
  mounted = false;
  if (canvas?.parentElement) canvas.parentElement.removeChild(canvas);
  syncDetect();
  if (!live) stopLoop();
}

export async function startLiveStream(settings: RecordSettings): Promise<void> {
  await stopLiveStream();
  if (!activeStream()) throw new Error('采集设备未就绪，请先在状态页开始采集');
  bindViewers();
  startLoop();
  if (!canvas || !video) throw new Error('直播画布未就绪，请重试');
  liveSettings = settings;
  starting = true;
  emit();
  try {
    await tuneStage(settings);
    const status: AppStatus = await window.recordApi.startLive();
    if (status.liveState !== 'live') throw new Error(status.liveError || '直播启动失败');
    live = true;
    error = '';
    syncDetect();
    syncCoder();
  } finally {
    starting = false;
    emit();
  }
}

export async function stopLiveStream(): Promise<void> {
  live = false;
  closeStream();
  viewers = 0;
  rateMbps = 0;
  tracks = [];
  detectEpoch += 1;
  clearFrames();
  unloadModel();
  await window.recordApi.stopLive().catch(() => undefined);
  if (!mounted) stopLoop();
  emit();
}

function startLoop(): void {
  if (loop) return;
  openStage();
  if (!canvas || !video) return;
  attachStream();
  loop = true;
  stopFrames = createFramePump(
    () => activeStream()?.getVideoTracks()[0],
    sourceVideo,
    () => streamInfo().fps || liveSettings?.fps || 60,
    paintSource,
  );
  rateTimer = window.setInterval(updateRates, 1000);
}

function stopLoop(): void {
  loop = false;
  stopFrames?.();
  stopFrames = undefined;
  if (rateTimer) {
    window.clearInterval(rateTimer);
    rateTimer = 0;
  }
  drawRate = 0;
  inferRate = 0;
  rateMbps = 0;
  detectAge = 0;
  detectWidth = detectFrameWidth;
  setDetectWidth(detectWidth);
  clearFrames();
  tracks = [];
}



async function tuneStage(settings: RecordSettings): Promise<void> {
  const deadline = Date.now() + 1500;
  let info = streamInfo();
  while ((!info.width || !info.height) && Date.now() < deadline) {
    await sleepMs(50);
    info = streamInfo();
  }
  resizeStage(info.width || settings.width, info.height || settings.height);
}

function resizeStage(width: number, height: number): void {
  if (!canvas || !width || !height) return;
  if (canvas.width === width && canvas.height === height) return;
  tracks = [];
  detectEpoch += 1;
  clearFrames();
  canvas.width = width;
  canvas.height = height;
}

function sleepMs(ms: number): Promise<void> {
  return new Promise((resolve) => window.setTimeout(resolve, ms));
}

function openStage(): void {
  if (stage || !document.body) return;
  stage = document.createElement('div');
  stage.setAttribute('style', stageStyle);
  video = document.createElement('video');
  video.muted = true;
  video.playsInline = true;
  video.autoplay = true;
  stage.appendChild(video);
  document.body.appendChild(stage);
  const info = streamInfo();
  canvas = document.createElement('canvas');
  canvas.className = 'live-canvas';
  canvas.width = info.width || 1280;
  canvas.height = info.height || 720;
  brush = canvas.getContext('2d');
}

function attachStream(): void {
  const element = video;
  const stream = previewStream();
  if (!element || !stream || element.srcObject === stream) return;
  element.srcObject = stream;
  void element.play().catch(() => undefined);
}

function sourceVideo(): HTMLVideoElement | undefined {
  const preview = document.querySelector<HTMLVideoElement>('video.preview-video');
  if (preview && preview.readyState >= 2 && preview.videoWidth && preview.videoHeight) {
    if (video && video.srcObject) video.srcObject = null;
    return preview;
  }
  attachStream();
  return video;
}

function paintSource(element: CanvasImageSource): void {
  if (!canvas || !brush || !activeStream()) return;
  const media = element as CanvasImageSource & {
    videoWidth?: number;
    videoHeight?: number;
    displayWidth?: number;
    displayHeight?: number;
    codedWidth?: number;
    codedHeight?: number;
  };
  const width = Math.round(Number(media.videoWidth ?? media.displayWidth ?? media.codedWidth ?? 0));
  const height = Math.round(Number(media.videoHeight ?? media.displayHeight ?? media.codedHeight ?? 0));
  if (!width || !height) return;
  resizeStage(width, height);
  if (!blurOn || !blurActive()) {
    drawFrame(element, width, height);
    if (live && viewers > 0) encodeFrame(canvas);
    return;
  }
  if (modelReady() && pendingFrames.size + completedFrames.size + ready.length < pendingLimit) captureFrame(element, width, height);
  if (ready.length) presentFrame(ready.shift() as ReadyFrame, width, height);
  else if (shownSlot && shownSlot.canvas.width === width && shownSlot.canvas.height === height) presentSlot(shownSlot, lastBoxes, width, height);
}

function captureFrame(element: CanvasImageSource, width: number, height: number): void {
  const at = performance.now();
  const slot = takeSlot(width, height);
  slot.ctx.drawImage(element, 0, 0, width, height);
  slot.at = at;
  const sequence = nextSequence++;
  const epoch = detectEpoch;
  pendingFrames.add(sequence);
  void runDetect(slot, width, height, at, sequence, epoch);
}

async function runDetect(slot: FrameSlot, width: number, height: number, at: number, sequence: number, epoch: number): Promise<void> {
  try {
    const result = await detectNicknames(slot.canvas);
    pendingFrames.delete(sequence);
    if (epoch !== detectEpoch || !blurOn || !blurActive()) {
      recycleSlot(slot);
      return;
    }
    const rtt = performance.now() - at;
    tuneDetect(rtt);
    const boxes = fitBoxes(mergeBoxes(result.boxes), width, height);
    completedFrames.set(sequence, { slot, boxes, sequence });
    inferred += 1;
    error = '';
    flushCompleted();
  } catch (cause) {
    pendingFrames.delete(sequence);
    if (epoch === detectEpoch) completedFrames.set(sequence, undefined);
    recycleSlot(slot);
    const text = messageOf(cause);
    if (!blurOn || stopMessage(text)) return;
    error = text;
    flushCompleted();
    emit();
  }
}

function flushCompleted(): void {
  while (completedFrames.has(nextPresentSequence)) {
    const frame = completedFrames.get(nextPresentSequence);
    completedFrames.delete(nextPresentSequence);
    nextPresentSequence += 1;
    if (!frame) continue;
    tracks = capTracks(updateTracks(tracks, frame.boxes, frame.slot.at, performance.now()));
    queueFrame(frame, frame.slot.canvas.width, frame.slot.canvas.height);
  }
}

function queueFrame(frame: ReadyFrame, width: number, height: number): void {
  if (readyWidth !== width || readyHeight !== height) {
    for (const stale of ready) recycleSlot(stale.slot);
    ready = [];
    readyWidth = width;
    readyHeight = height;
  }
  ready.push(frame);
  while (ready.length > readyLimit) recycleSlot((ready.shift() as ReadyFrame).slot);
}

function presentFrame(frame: ReadyFrame, width: number, height: number): void {
  const previous = shownSlot;
  shownSlot = frame.slot;
  presentSlot(frame.slot, frame.boxes, width, height, true);
  if (previous && previous !== shownSlot) recycleSlot(previous);
}

function presentSlot(slot: FrameSlot, boxes: DetectBox[], width: number, height: number, updateDelay = false): void {
  if (!brush || !canvas || canvas.width !== width || canvas.height !== height) return;
  brush.save();
  if (flip) {
    brush.translate(0, height);
    brush.scale(1, -1);
  }
  brush.drawImage(slot.canvas, 0, 0, width, height);
  brush.restore();
  const shown = flip ? flipBoxes(boxes, height) : boxes;
  if (shown.length) blurBoxes(brush, shown, width, height);
  if (debugBoxes && shown.length) overlayBoxes(brush, shown);
  lastBoxes = boxes;
  if (updateDelay) setStreamDelay(Math.max(0, performance.now() - slot.at));
  drawn += 1;
  if (live && viewers > 0) encodeFrame(canvas);
}

function takeSlot(width: number, height: number): FrameSlot {
  const slot = framePool.pop() ?? makeSlot();
  if (slot.canvas.width !== width) slot.canvas.width = width;
  if (slot.canvas.height !== height) slot.canvas.height = height;
  return slot;
}

function makeSlot(): FrameSlot {
  const element = document.createElement('canvas');
  const ctx = element.getContext('2d');
  if (!ctx) throw new Error('打码缓冲画布初始化失败');
  return { canvas: element, ctx, at: 0 };
}

function recycleSlot(slot: FrameSlot): void {
  if (slot === shownSlot) return;
  if (framePool.length < readyLimit + 2) framePool.push(slot);
}

function clearFrames(): void {
  ready = [];
  completedFrames.clear();
  pendingFrames.clear();
  nextPresentSequence = nextSequence;
  shownSlot = undefined;
  lastBoxes = [];
  framePool.length = 0;
  setStreamDelay(0);
}

function drawFrame(source: CanvasImageSource, width: number, height: number): void {
  if (!brush) return;
  brush.save();
  if (flip) {
    brush.translate(0, height);
    brush.scale(1, -1);
  }
  brush.drawImage(source, 0, 0, width, height);
  brush.restore();
  drawn += 1;
}

function stopMessage(text: string): boolean {
  return text.includes('推理后端已停止');
}

function tuneDetect(age: number): void {
  detectAge = detectAge ? detectAge * 0.7 + age * 0.3 : age;
  if (detectAge > detectSlowMs && detectWidth > detectMinWidth) {
    detectWidth = detectMinWidth;
    setDetectWidth(detectWidth);
  } else if (detectAge < detectFastMs && detectWidth < detectFrameWidth) {
    detectWidth = detectFrameWidth;
    setDetectWidth(detectWidth);
  }
}

function capTracks(list: TrackBox[]): TrackBox[] {
  if (list.length <= trackLimit) return list;
  return [...list].sort((left, right) => right.seen - left.seen).slice(0, trackLimit);
}

function fail(message: string): void {
  error = message;
  live = false;
  closeStream();
  unloadModel();
  stopLoop();
  void window.recordApi.stopLive().catch(() => undefined);
  emit();
}

function updateRates(): void {
  drawRate = drawn;
  inferRate = inferred;
  drawn = 0;
  inferred = 0;
  const total = streamBytes();
  const now = performance.now();
  if (sampleAt && now > sampleAt && total >= sampleBytes) rateMbps = Math.round(((total - sampleBytes) * 8) / ((now - sampleAt) / 1000) / 100000) / 10;
  else rateMbps = 0;
  sampleBytes = total;
  sampleAt = now;
  emit();
}

function bindViewers(): void {
  if (viewersBound) return;
  viewersBound = true;
  window.recordApi.onLiveViewers((event) => {
    viewers = Math.max(0, Math.round(event.viewers));
    if (event.key) requestKey();
    syncCoder();
    emit();
  });
}

function syncCoder(): void {
  if (!canvas) return;
  if (!live || viewers === 0) {
    if (streamOpen()) closeStream();
    return;
  }
  if (streamOpen()) return;
  const info = streamInfo();
  const width = canvas.width || info.width || liveSettings?.width || 1280;
  const height = canvas.height || info.height || liveSettings?.height || 720;
  const fps = Math.max(1, info.fps || liveSettings?.fps || 60);
  void openStream({ canvas, source: activeStream(), width, height, fps, bitrate: liveBitrateBps(width, height), onError: (message) => fail(message) })
    .catch((cause) => fail(messageOf(cause)));
}

function emit(): void {
  const view = liveView();
  for (const listener of listeners) listener(view);
}

function messageOf(cause: unknown): string {
  const text = (cause instanceof Error ? cause.message : String(cause ?? '')).replace(/^Error invoking remote method '[^']*':\s*(Error:\s*)?/, '').trim();
  return text || '直播失败';
}

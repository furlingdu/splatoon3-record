import { useEffect, useState } from 'react';
import { chooseMime } from '../../shared/capture.js';
import { recordFallbackBps } from '../../shared/bitrate.js';
import { blurJobWorkers, liveTimesliceMs } from '../../shared/constants.js';
import { blurBoxes, fitBoxes, mergeBoxes } from './blur.js';
import { startPaint } from './paint.js';
import { detectNicknames, loadModel } from './detect.js';
import type { DetectBox } from './detect.js';
import type { RecordSettings } from '../../shared/types.js';

export interface BlurTaskView {
  id: string;
  matchId: string;
  running: boolean;
  progress: number;
  output?: string;
  error?: string;
}

export interface BlurJobView {
  running: boolean;
  total: number;
  done: number;
  progress: number;
  output?: string;
  error?: string;
  tasks: BlurTaskView[];
}

export interface BlurSource {
  matchId: string;
  videoUrl: string;
}

interface BlurTask {
  id: string;
  matchId: string;
  videoUrl: string;
  settings: RecordSettings;
  state: 'queued' | 'running' | 'done' | 'error' | 'canceled';
  progress: number;
  output: string;
  error: string;
  jobId: string;
  boxes: DetectBox[];
  detecting: boolean;
  writes: Promise<void>;
  video?: HTMLVideoElement;
  canvas?: HTMLCanvasElement;
  brush?: CanvasRenderingContext2D;
  probe?: HTMLCanvasElement;
  probeCtx?: CanvasRenderingContext2D;
  recorder?: MediaRecorder;
  stream?: MediaStream;
  stopPaint?: () => void;
}

let tasks: BlurTask[] = [];
const active = new Map<string, BlurTask>();
let queue: BlurTask[] = [];
let seq = 0;
let pumping = false;
const listeners = new Set<(view: BlurJobView) => void>();

export function blurView(): BlurJobView {
  const total = tasks.length;
  const finished = tasks.filter((task) => task.state === 'done' || task.state === 'error').length;
  const progress = total ? tasks.reduce((sum, task) => sum + (task.state === 'done' ? 1 : task.progress), 0) / total : 0;
  const failed = tasks.find((task) => task.state === 'error');
  const saved = [...tasks].reverse().find((task) => task.state === 'done');
  return {
    running: tasks.some((task) => task.state === 'running' || task.state === 'queued'),
    total,
    done: finished,
    progress,
    output: saved?.output,
    error: failed?.error,
    tasks: tasks.map(taskView),
  };
}

export function useBlurJob(): BlurJobView {
  const [view, setView] = useState<BlurJobView>(blurView);
  useEffect(() => {
    const listener = (): void => setView(blurView());
    listeners.add(listener);
    listener();
    return () => {
      listeners.delete(listener);
    };
  }, []);
  return view;
}

export async function startBlurJob(matchId: string, videoUrl: string, settings: RecordSettings): Promise<void> {
  await startBlurJobs([{ matchId, videoUrl }], settings);
}

export async function startBlurJobs(sources: BlurSource[], settings: RecordSettings): Promise<void> {
  await cancelBlurJob();
  tasks = sources.map((source) => createTask(source, settings));
  queue = [...tasks];
  if (!tasks.length) return;
  emit();
  pump();
}

export async function cancelBlurJob(id?: string): Promise<void> {
  const targets = id ? tasks.filter((task) => task.id === id || task.matchId === id) : [...tasks];
  if (!targets.length) return;
  queue = queue.filter((task) => !targets.includes(task));
  await Promise.all(targets.map((task) => cancelTask(task)));
  tasks = id ? tasks.filter((task) => !targets.includes(task)) : [];
  emit();
}

function createTask(source: BlurSource, settings: RecordSettings): BlurTask {
  seq += 1;
  return {
    id: `${source.matchId}-${seq}`,
    matchId: source.matchId,
    videoUrl: source.videoUrl,
    settings,
    state: 'queued',
    progress: 0,
    output: '',
    error: '',
    jobId: '',
    boxes: [],
    detecting: false,
    writes: Promise.resolve(),
  };
}

function taskView(task: BlurTask): BlurTaskView {
  return {
    id: task.id,
    matchId: task.matchId,
    running: task.state === 'running',
    progress: task.progress,
    output: task.output || undefined,
    error: task.error || undefined,
  };
}

function pump(): void {
  if (pumping) return;
  pumping = true;
  try {
    while (active.size < blurJobWorkers && queue.length) {
      const task = queue.shift();
      if (!task) break;
      active.set(task.id, task);
      void runTask(task);
    }
  } finally {
    pumping = false;
  }
}

async function runTask(task: BlurTask): Promise<void> {
  if (task.state !== 'queued') return;
  task.state = 'running';
  emit();
  try {
    const created = await window.recordApi.startBlur(task.matchId, chooseBlurMime());
    if (!created) throw new Error('该对局没有可用的录像文件');
    task.jobId = created.jobId;
    await openVideo(task);
  } catch (cause) {
    await failTask(task, messageOf(cause));
  }
}

async function openVideo(task: BlurTask): Promise<void> {
  const element = document.createElement('video');
  element.src = task.videoUrl;
  element.muted = true;
  element.playsInline = true;
  element.crossOrigin = 'anonymous';
  element.style.cssText = 'position:fixed;left:-10000px;top:0;width:2px;height:2px;opacity:0;pointer-events:none';
  document.body.appendChild(element);
  task.video = element;
  await waitMeta(element);
  const width = element.videoWidth;
  const height = element.videoHeight;
  if (!width || !height) throw new Error('无法读取录像画幅');
  task.canvas = document.createElement('canvas');
  task.canvas.width = width;
  task.canvas.height = height;
  task.probe = document.createElement('canvas');
  task.probe.width = width;
  task.probe.height = height;
  const brush = task.canvas.getContext('2d');
  const probeCtx = task.probe.getContext('2d');
  if (!brush || !probeCtx) throw new Error('打码画布初始化失败');
  task.brush = brush;
  task.probeCtx = probeCtx;
  const choice = chooseMime((type) => MediaRecorder.isTypeSupported(type), false);
  if (!choice) throw new Error('当前系统不支持可用的打码编码格式');
  task.stream = task.canvas.captureStream(Math.max(1, Math.round(30)));
  const next = new MediaRecorder(task.stream, { mimeType: choice.type, videoBitsPerSecond: recordFallbackBps(width, height) });
  next.ondataavailable = (event) => collect(task, event.data);
  next.onerror = (event) => void failTask(task, errorText(event));
  next.start(liveTimesliceMs);
  task.recorder = next;
  void loadModel().catch(() => undefined);
  element.addEventListener('ended', () => void finishTask(task));
  element.addEventListener('timeupdate', () => {
    if (element.duration && Number.isFinite(element.duration) && element.duration > 0) {
      task.progress = Math.min(0.99, Math.max(0, element.currentTime / element.duration));
      emit();
    }
  });
  await element.play();
  task.stopPaint = startPaint(() => paintTask(task), 30);
}

function paintTask(task: BlurTask): void {
  const element = task.video;
  if (task.state !== 'running' || !element || !task.brush || !task.probeCtx || !task.canvas || !task.probe) return;
  if (element.readyState < 2) return;
  const width = task.canvas.width;
  const height = task.canvas.height;
  task.probeCtx.drawImage(element, 0, 0, width, height);
  task.brush.drawImage(element, 0, 0, width, height);
  if (task.boxes.length) blurBoxes(task.brush, task.boxes, width, height);
  if (!task.detecting) void detectTask(task, width, height);
}

async function detectTask(task: BlurTask, width: number, height: number): Promise<void> {
  if (!task.probe) return;
  task.detecting = true;
  try {
    const result = await detectNicknames(task.probe);
    if (task.state === 'running') task.boxes = fitBoxes(mergeBoxes(result.boxes), width, height);
  } catch (cause) {
    await failTask(task, messageOf(cause));
  } finally {
    task.detecting = false;
  }
}

function collect(task: BlurTask, blob: Blob): void {
  if (!blob.size || !task.jobId) return;
  task.writes = task.writes
    .then(async () => {
      const stored = await window.recordApi.writeBlurChunk(task.jobId, await blob.arrayBuffer());
      if (!stored) throw new Error('打码数据写入失败');
    })
    .catch((cause) => failTask(task, messageOf(cause)));
}

async function finishTask(task: BlurTask): Promise<void> {
  if (task.state !== 'running') return;
  const current = task.recorder;
  task.recorder = undefined;
  if (current && current.state !== 'inactive') await new Promise<void>((resolve) => {
    current.addEventListener('stop', () => resolve(), { once: true });
    try {
      current.stop();
    } catch {
      resolve();
    }
  });
  await task.writes.catch(() => undefined);
  closeMedia(task);
  const id = task.jobId;
  task.jobId = '';
  if (!id) {
    settleTask(task, true, '');
    return;
  }
  const saved = await window.recordApi.endBlur(id, tasks.length === 1).catch(() => undefined);
  settleTask(task, Boolean(saved), saved || '打码视频合成失败，已保留原文件');
}

async function cancelTask(task: BlurTask): Promise<void> {
  if (task.state === 'done' || task.state === 'error' || task.state === 'canceled') return;
  task.state = 'canceled';
  closeMedia(task);
  const id = task.jobId;
  task.jobId = '';
  active.delete(task.id);
  if (id) await window.recordApi.cancelBlur(id).catch(() => undefined);
  emit();
  pump();
}

async function failTask(task: BlurTask, message: string): Promise<void> {
  if (task.state !== 'running') return;
  closeMedia(task);
  const id = task.jobId;
  task.jobId = '';
  active.delete(task.id);
  if (id) await window.recordApi.cancelBlur(id).catch(() => undefined);
  settleTask(task, false, message);
}

function settleTask(task: BlurTask, ok: boolean, detail: string): void {
  active.delete(task.id);
  task.state = ok ? 'done' : 'error';
  if (ok) {
    task.output = detail;
    task.error = '';
    task.progress = 1;
  } else {
    task.error = detail;
  }
  emit();
  pump();
}

function closeMedia(task: BlurTask): void {
  if (task.stopPaint) {
    task.stopPaint();
    task.stopPaint = undefined;
  }
  const element = task.video;
  task.video = undefined;
  if (element) {
    element.pause();
    element.removeAttribute('src');
    element.load();
    element.remove();
  }
  task.stream?.getTracks().forEach((track) => track.stop());
  task.stream = undefined;
  task.canvas = undefined;
  task.brush = undefined;
  task.probe = undefined;
  task.probeCtx = undefined;
  task.boxes = [];
}

function waitMeta(element: HTMLVideoElement): Promise<void> {
  return new Promise<void>((resolve, reject) => {
    const done = (): void => {
      element.removeEventListener('loadedmetadata', done);
      element.removeEventListener('error', bad);
      resolve();
    };
    const bad = (): void => {
      element.removeEventListener('loadedmetadata', done);
      element.removeEventListener('error', bad);
      reject(new Error('无法打开该录像文件'));
    };
    element.addEventListener('loadedmetadata', done);
    element.addEventListener('error', bad);
  });
}

function chooseBlurMime(): string {
  return chooseMime((type) => MediaRecorder.isTypeSupported(type), false)?.type ?? 'video/webm';
}

function emit(): void {
  const view = blurView();
  for (const listener of listeners) listener(view);
}

function errorText(cause: unknown): string {
  const detail = cause as { error?: { message?: string; name?: string }; message?: string; name?: string };
  return detail?.message || detail?.error?.message || detail?.error?.name || detail?.name || '打码中断';
}

function messageOf(cause: unknown): string {
  const text = (cause instanceof Error ? cause.message : String(cause ?? '')).replace(/^Error invoking remote method '[^']*':\s*(Error:\s*)?/, '').trim();
  return text || '打码失败';
}

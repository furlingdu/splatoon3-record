import { useEffect, useState } from 'react';
import { activeStream, applySize, closeStream, listDevices, openStream, planSize, streamInfo } from './device.js';
import { clearRecord, planFormat, recordError, recordFormat, recordState, setRecordQuality, startRecord, stopRecord } from './record.js';
import type { AppStatus, CaptureDevice, RecordSettings, RecordState } from '../../shared/types.js';

export interface SessionView {
  recordState: RecordState;
  recordError?: string;
  devices: CaptureDevice[];
  format: string;
  width: number;
  height: number;
  fps: number;
  hasAudio: boolean;
  revision: number;
  applying: boolean;
  error?: string;
}

let desire: RecordSettings | undefined;
let applied: RecordSettings | undefined;
let appliedKey = '';
let devices: CaptureDevice[] = [];
let error: string | undefined;
let wanted = false;
let seeded = false;
let running = false;
const listeners = new Set<(view: SessionView) => void>();
const deviceless: Promise<void> = Promise.resolve();

function captureView(): SessionView {
  const info = streamInfo();
  return {
    recordState: error ? 'error' : recordState(),
    recordError: error ?? recordError(),
    devices,
    format: recordFormat(),
    width: info.width,
    height: info.height,
    fps: info.fps,
    hasAudio: info.hasAudio,
    revision: info.revision,
    applying: running,
    error,
  };
}

function emitView(): void {
  const view = captureView();
  for (const listener of listeners) listener(view);
}

function reportCapture(): void {
  const view = captureView();
  window.recordApi.reportCapture({
    recordState: view.recordState,
    error: view.recordError,
    width: view.width,
    height: view.height,
    fps: view.fps,
    format: view.format,
    hasAudio: view.hasAudio,
  });
}

function refreshView(): void {
  emitView();
  reportCapture();
}

export function applySettings(next?: RecordSettings): Promise<void> {
  if (!next) return deviceless;
  desire = next;
  planSize(next.width, next.height, next.fps);
  setRecordQuality(next.quality);
  if (!seeded) {
    seeded = true;
    wanted = next.autoRecord;
  }
  if (settingsKey(next) === appliedKey) return deviceless;
  return reconcileSettings();
}

async function reconcileSettings(): Promise<void> {
  if (running) return;
  running = true;
  emitView();
  let switched = false;
  try {
    while (desire && settingsKey(desire) !== appliedKey) {
      const target = desire;
      const previous = applied;
      let rebuilt = false;
      if (!previous || previous.videoDevice !== target.videoDevice || previous.audioDevice !== target.audioDevice) switched = true;
      try {
        rebuilt = await openTarget(target, previous);
        error = undefined;
      } catch (cause) {
        error = messageOf(cause);
      }
      applied = target;
      appliedKey = settingsKey(target);
      if (!error && wanted && rebuilt) await beginRecord();
      refreshView();
    }
  } finally {
    running = false;
    if (switched) await refreshDevices();
    emitView();
  }
}

async function openTarget(target: RecordSettings, previous?: RecordSettings): Promise<boolean> {
  const deviceChanged = !previous || previous.videoDevice !== target.videoDevice || previous.audioDevice !== target.audioDevice;
  if (deviceChanged || !activeStream()) {
    await stopRecord();
    const stream = await openStream(target);
    planFormat(stream);
    return settleSize(target);
  }
  if (previous.width === target.width && previous.height === target.height && previous.fps === target.fps) return false;
  if (await applySize(target.width, target.height, target.fps)) return true;
  await stopRecord();
  return reopen(target);
}

async function settleSize(target: RecordSettings): Promise<boolean> {
  if (!target.width || !target.height || sizeMatched(target)) return true;
  if (await applySize(target.width, target.height, target.fps)) return true;
  await stopRecord();
  return reopen(target);
}

async function reopen(target: RecordSettings): Promise<boolean> {
  const stream = await openStream(target, true).catch(() => openStream(target));
  planFormat(stream);
  return true;
}

function sizeMatched(target: RecordSettings): boolean {
  const info = streamInfo();
  return info.width === Math.round(target.width) && info.height === Math.round(target.height)
    && info.fps > 0 && Math.abs(info.fps - target.fps) <= 0.5;
}

async function beginRecord(): Promise<void> {
  const stream = activeStream();
  if (!stream) return;
  clearRecord();
  try {
    await startRecord(stream);
  } catch (cause) {
    error = messageOf(cause);
  }
}

export async function startCapture(): Promise<void> {
  wanted = true;
  await reconcileSettings();
  if (desire) await beginRecord();
  refreshView();
}

export async function stopCapture(): Promise<void> {
  wanted = false;
  await stopRecord();
  refreshView();
}

export async function retryCapture(): Promise<void> {
  applied = undefined;
  appliedKey = '';
  await reconcileSettings();
}

export async function refreshDevices(): Promise<CaptureDevice[]> {
  devices = await listDevices(desire?.videoDevice).catch(() => [] as CaptureDevice[]);
  emitView();
  return devices;
}

export function useSession(status?: AppStatus, enabled = true): SessionView {
  const [view, setView] = useState<SessionView>(captureView);
  useEffect(() => {
    const listener = (): void => setView(captureView());
    listeners.add(listener);
    listener();
    return () => {
      listeners.delete(listener);
    };
  }, []);
  useEffect(() => {
    if (!enabled) return;
    void applySettings(status?.settings);
  }, [enabled, status?.settings]);
  useEffect(() => {
    if (!enabled) return;
    void refreshDevices();
    const handler = (): void => {
      void refreshDevices();
    };
    navigator.mediaDevices?.addEventListener?.('devicechange', handler);
    return () => {
      navigator.mediaDevices?.removeEventListener?.('devicechange', handler);
    };
  }, [enabled]);
  return view;
}

export function closeSession(): void {
  closeStream();
  void stopRecord();
}

const mediaErrors: Record<string, string> = {
  NotAllowedError: '系统未授权访问采集设备，请在系统隐私设置里允许摄像头与麦克风',
  NotFoundError: '未找到所选采集设备，请到设置页重新选择',
  OverconstrainedError: '采集设备不支持当前分辨率或帧率，请到状态页调低后重试',
  NotReadableError: '采集设备正被其他程序占用，请关闭占用程序后重试',
  AbortError: '采集设备启动被中断，请重试',
};

function messageOf(cause: unknown): string {
  const detail = cause as { message?: string; name?: string };
  const text = (cause instanceof Error ? cause.message : String(cause ?? '')).replace(/^Error invoking remote method '[^']*':\s*(Error:\s*)?/, '').trim();
  return text || mediaErrors[detail?.name ?? ''] || '采集失败';
}

function settingsKey(settings: RecordSettings): string {
  return `${settings.videoDevice}:${settings.audioDevice}:${settings.width}x${settings.height}@${settings.fps}`;
}

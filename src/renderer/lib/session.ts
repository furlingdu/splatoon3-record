import { useEffect, useState } from 'react';
import { activeStream, applySize, closeStream, listDevices, openStream, planSize, probeFps, recordAudioSource, recordAudioTrack, streamInfo } from './device.js';
import { fpsOptions } from '../../shared/capture.js';
import { clearRecord, planFormat, recordAudio, recordAudioHealth, recordEncoder, recordError, recordFormat, recordState, recordVideoHealth, setRecordQuality, startRecord, stopRecord } from './record.js';
import type { AppStatus, CaptureDevice, RecordSettings, RecordState } from '../../shared/types.js';

export interface SessionView {
  recordState: RecordState;
  recordError?: string;
  devices: CaptureDevice[];
  format: string;
  encoder: string;
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
let heartbeatUsers = 0;
let heartbeatTimer: number | undefined;

function captureView(): SessionView {
  const info = streamInfo();
  return {
    recordState: error ? 'error' : recordState(),
    recordError: error ?? recordError(),
    devices,
    format: recordFormat(),
    encoder: recordEncoder(),
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
    pixelFormat: desire?.captureFormat,
    encoder: view.encoder,
    hasAudio: view.hasAudio,
    audio: recordAudio(),
    audioSource: recordAudioSource(),
    audioHealth: recordAudioHealth(),
    videoHealth: recordVideoHealth(),
  });
}

function refreshView(): void {
  emitView();
  reportCapture();
}

function stopCaptureHeartbeat(): void {
  if (heartbeatTimer !== undefined) {
    window.clearInterval(heartbeatTimer);
    heartbeatTimer = undefined;
  }
}

function updateCaptureHeartbeat(enabled: boolean): void {
  heartbeatUsers += enabled ? 1 : -1;
  if (heartbeatUsers > 0 && heartbeatTimer === undefined) {
    heartbeatTimer = window.setInterval(reportCapture, 5000);
  } else if (heartbeatUsers <= 0) {
    heartbeatUsers = 0;
    stopCaptureHeartbeat();
  }
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
    for (let pass = 0; pass < 4; pass += 1) {
      const target = desire;
      if (!target || settingsKey(target) === appliedKey) break;
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
  const deviceChanged = !previous || previous.videoDevice !== target.videoDevice || previous.audioDevice !== target.audioDevice
    || previous.desktopAudio !== target.desktopAudio || previous.micAudio !== target.micAudio || previous.micDevice !== target.micDevice
    || previous.captureFormat !== target.captureFormat;
  if (deviceChanged || !activeStream()) {
    await stopRecord();
    const stream = await openStream(target, true).catch(() => openStream(target));
    planFormat(stream);
    if (!sizeMatched(target)) await applySize(target.width, target.height, target.fps);
    await probeFps(fpsOptions);
    return true;
  }
  if (previous.width === target.width && previous.height === target.height && previous.fps === target.fps) return false;
  if (await applySize(target.width, target.height, target.fps)) {
    await probeFps(fpsOptions);
    return true;
  }
  await stopRecord();
  const stream = await openStream(target, true).catch(() => openStream(target));
  planFormat(stream);
  if (!sizeMatched(target)) await applySize(target.width, target.height, target.fps);
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
    await startRecord(stream, recordAudioTrack(), () => refreshView());
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
    updateCaptureHeartbeat(true);
    return () => updateCaptureHeartbeat(false);
  }, [enabled]);
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
  OverconstrainedError: '采集设备不支持当前分辨率或帧率，请到设置页更换档位后重试',
  NotReadableError: '采集设备正被其他程序占用，请关闭占用程序后重试',
  AbortError: '采集设备启动被中断，请重试',
};

function messageOf(cause: unknown): string {
  const detail = cause as { message?: string; name?: string };
  const text = (cause instanceof Error ? cause.message : String(cause ?? '')).replace(/^Error invoking remote method '[^']*':\s*(Error:\s*)?/, '').trim();
  return text || mediaErrors[detail?.name ?? ''] || '采集失败';
}

function settingsKey(settings: RecordSettings): string {
  return `${settings.videoDevice}:${settings.audioDevice}:${settings.width}x${settings.height}@${settings.fps}:${settings.captureFormat}:${settings.desktopAudio ? 1 : 0}:${settings.micAudio ? 1 : 0}:${settings.micDevice ?? ''}`;
}

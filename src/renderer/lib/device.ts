import { cleanNames, matchDevice } from '../../shared/capture.js';
import type { CaptureDevice, RecordSettings } from '../../shared/types.js';

let stream: MediaStream | undefined;
let recordTrack: MediaStreamTrack | undefined;
let extraStreams: MediaStream[] = [];
let mixContext: AudioContext | undefined;
let recordSourceLabel = '';
let desiredSize: { width: number; height: number; fps: number } | undefined;
let mediaQueue: Promise<unknown> = Promise.resolve();
let revision = 0;
const capsCache = new Map<string, DeviceCaps>();
const fpsCache = new Map<string, number[]>();
const capsPending = new Map<string, Promise<DeviceCaps | undefined>>();

export interface StreamInfo {
  width: number;
  height: number;
  fps: number;
  hasAudio: boolean;
  revision: number;
}

interface DeviceCaps {
  maxWidth: number;
  maxHeight: number;
  maxFps: number;
}

export function activeStream(): MediaStream | undefined {
  return stream;
}

export function recordAudioTrack(): MediaStreamTrack | undefined {
  const track = recordTrack;
  return track && track.readyState === 'live' ? track : undefined;
}

export function recordAudioSource(): string | undefined {
  return recordSourceLabel || undefined;
}

export function resumeRecordAudio(): void {
  const context = mixContext;
  if (context && context.state === 'suspended') void context.resume().catch(() => undefined);
}

let previewView: MediaStream | undefined;
let previewFrom: MediaStream | undefined;

export function previewStream(): MediaStream | undefined {
  const current = activeStream();
  if (!current) {
    previewFrom = undefined;
    previewView = undefined;
    return undefined;
  }
  if (previewFrom !== current || !previewView) {
    previewFrom = current;
    const tracks = current.getVideoTracks();
    previewView = tracks.length ? new MediaStream(tracks) : undefined;
  }
  return previewView;
}

export function probedFps(deviceId: string, width: number, height: number): number[] | undefined {
  return fpsCache.get(fpsKey(deviceId, width, height));
}

export async function probeFps(candidates: number[]): Promise<number[]> {
  const track = stream?.getVideoTracks()[0];
  if (!track) return [];
  const before = track.getSettings();
  const deviceId = String(before.deviceId ?? '');
  const width = Math.round(Number(before.width ?? 0));
  const height = Math.round(Number(before.height ?? 0));
  const keep = Number(before.frameRate ?? 0);
  if (!deviceId || !width || !height || !candidates.length) return [];
  const key = fpsKey(deviceId, width, height);
  const cached = fpsCache.get(key);
  if (cached) return cached;
  const usable: number[] = [];
  for (const fps of candidates) {
    const applied = await applyRate(track, width, height, fps);
    const reached = Math.round(Number(track.getSettings().frameRate ?? 0));
    if (applied && reached > 0 && !usable.includes(reached)) usable.push(reached);
  }
  if (keep > 0) await applyRate(track, width, height, keep);
  usable.sort((left, right) => left - right);
  fpsCache.set(key, usable);
  return usable;
}

async function applyRate(track: MediaStreamTrack, width: number, height: number, fps: number): Promise<boolean> {
  return track
    .applyConstraints({ width: { ideal: width }, height: { ideal: height }, frameRate: { ideal: fps } })
    .then(() => true)
    .catch(() => false);
}

function fpsKey(deviceId: string, width: number, height: number): string {
  return `${deviceId}|${Math.round(width)}x${Math.round(height)}`;
}

export function planSize(width: number, height: number, fps: number): void {
  if (width > 0 && height > 0) desiredSize = { width, height, fps };
}

export async function listDevices(selected?: string): Promise<CaptureDevice[]> {
  let devices = await navigator.mediaDevices.enumerateDevices().catch(() => [] as MediaDeviceInfo[]);
  if (devices.some((item) => !item.label)) {
    await queueMedia(grantLabels);
    devices = await navigator.mediaDevices.enumerateDevices().catch(() => [] as MediaDeviceInfo[]);
  }
  const list = devices
    .filter((item) => item.kind === 'videoinput' || item.kind === 'audioinput')
    .map((item) => ({ id: item.deviceId, name: item.label, kind: item.kind === 'audioinput' ? ('audio' as const) : ('video' as const) }));
  return enrichCaps(cleanNames(list), selected);
}

async function enrichCaps(devices: CaptureDevice[], selected?: string): Promise<CaptureDevice[]> {
  const target = matchDevice(devices, 'video', selected);
  if (!target || target.maxWidth) return devices;
  const caps = await deviceCaps(target.id);
  if (!caps) return devices;
  return devices.map((item) => (item.id === target.id ? { ...item, ...caps } : item));
}

async function deviceCaps(id: string): Promise<DeviceCaps | undefined> {
  const cached = capsCache.get(id);
  if (cached) return cached;
  const live = liveCaps(id);
  if (live) return live;
  const pending = capsPending.get(id);
  if (pending) return pending;
  const task = queueMedia(() => probeCaps(id));
  capsPending.set(id, task);
  try {
    return await task;
  } finally {
    capsPending.delete(id);
  }
}

async function probeCaps(id: string): Promise<DeviceCaps | undefined> {
  const live = liveCaps(id);
  if (live) return live;
  const probe = await navigator.mediaDevices.getUserMedia({ video: probeRequest(id) }).catch(() => undefined);
  if (!probe) return undefined;
  const track = probe.getVideoTracks()[0];
  const caps = track ? trackCaps(track) : undefined;
  probe.getTracks().forEach((item) => item.stop());
  if (caps) capsCache.set(id, caps);
  return caps;
}

function liveCaps(id: string): DeviceCaps | undefined {
  const track = stream?.getVideoTracks()[0];
  if (!track || String(track.getSettings().deviceId ?? '') !== id) return undefined;
  const caps = trackCaps(track);
  if (caps) capsCache.set(id, caps);
  return caps;
}

function trackCaps(track: MediaStreamTrack): DeviceCaps | undefined {
  const caps = (() => {
    try {
      return track.getCapabilities?.() ?? {};
    } catch {
      return {};
    }
  })();
  const maxWidth = Math.round(Number(caps.width?.max ?? 0));
  const maxHeight = Math.round(Number(caps.height?.max ?? 0));
  if (!maxWidth || !maxHeight) return undefined;
  return {
    maxWidth,
    maxHeight,
    maxFps: Math.round(Number(caps.frameRate?.max ?? 0)),
  };
}

function probeRequest(id: string): MediaTrackConstraints {
  const base: MediaTrackConstraints = { deviceId: { exact: id } };
  if (!desiredSize) return base;
  return { ...base, width: { ideal: desiredSize.width }, height: { ideal: desiredSize.height }, frameRate: { ideal: desiredSize.fps } };
}

async function grantLabels(): Promise<void> {
  const size: MediaTrackConstraints = desiredSize ? { width: { ideal: desiredSize.width }, height: { ideal: desiredSize.height }, frameRate: { ideal: desiredSize.fps } } : {};
  const attempts: MediaStreamConstraints[] = [{ video: size, audio: true }, { video: size }, { audio: true }];
  for (const constraints of attempts) {
    const probe = await navigator.mediaDevices.getUserMedia(constraints).catch(() => undefined);
    if (!probe) continue;
    probe.getTracks().forEach((track) => track.stop());
    return;
  }
}

export function openStream(settings: RecordSettings, exactSize = false): Promise<MediaStream> {
  return queueMedia(() => openDevice(settings, exactSize));
}

async function openDevice(settings: RecordSettings, exactSize: boolean): Promise<MediaStream> {
  const videoId = await resolveDevice('videoinput', settings.videoDevice);
  const audioId = await resolveDevice('audioinput', settings.audioDevice);
  const micId = settings.micAudio ? await resolveDevice('audioinput', settings.micDevice ?? '') : undefined;
  const video: MediaTrackConstraints | false = videoId
    ? {
      deviceId: { exact: videoId },
      width: exactSize ? { exact: settings.width } : { ideal: settings.width },
      height: exactSize ? { exact: settings.height } : { ideal: settings.height },
      frameRate: exactSize ? { exact: settings.fps } : { ideal: settings.fps },
    }
    : false;
  const audio: MediaTrackConstraints | false = audioId
    ? { deviceId: { exact: audioId }, channelCount: 2, sampleRate: 48000, echoCancellation: false, noiseSuppression: false, autoGainControl: false }
    : false;
  if (!video && !audio) throw new Error('未选择采集设备');
  desiredSize = { width: settings.width, height: settings.height, fps: settings.fps };
  closeStream();
  const camera = await openCamera({ video, audio });
  try {
    recordTrack = await openRecordTrack(camera, settings, micId);
    recordSourceLabel = sourceLabel(settings, micId, camera.getAudioTracks().length > 0);
  } catch (cause) {
    camera.getTracks().forEach((track) => track.stop());
    recordTrack = undefined;
    recordSourceLabel = '';
    stopExtras();
    throw cause;
  }
  stream = camera;
  revision += 1;
  if (videoId) liveCaps(videoId);
  return stream;
}

async function openRecordTrack(camera: MediaStream, settings: RecordSettings, micId?: string): Promise<MediaStreamTrack | undefined> {
  const sources: MediaStreamTrack[] = [];
  if (settings.desktopAudio) {
    sources.push(await openDesktopTrack());
  } else {
    const base = camera.getAudioTracks()[0];
    if (base) sources.push(base);
  }
  if (micId) {
    sources.push(await openMicTrack(micId));
  }
  if (!sources.length) return undefined;
  if (sources.length === 1) return sources[0];
  return mixTracks(sources);
}

async function openDesktopTrack(): Promise<MediaStreamTrack> {
  const display = await navigator.mediaDevices.getDisplayMedia({ video: true, audio: true });
  display.getVideoTracks().forEach((track) => track.stop());
  const track = display.getAudioTracks()[0];
  if (!track) {
    display.getTracks().forEach((item) => item.stop());
    throw new Error('未捕获到电脑声音，请确认系统有可用的播放设备');
  }
  extraStreams.push(display);
  return track;
}

async function openMicTrack(id: string): Promise<MediaStreamTrack> {
  const mic = await navigator.mediaDevices.getUserMedia({
    audio: { deviceId: { exact: id }, channelCount: 1, echoCancellation: false, noiseSuppression: false, autoGainControl: false },
  });
  extraStreams.push(mic);
  return mic.getAudioTracks()[0];
}

function sourceLabel(settings: RecordSettings, micId: string | undefined, captureAudio: boolean): string {
  const sources = [settings.desktopAudio ? '电脑声音' : captureAudio ? '采集卡音频' : '', micId ? '麦克风' : ''].filter(Boolean);
  return sources.join('+') || '';
}

function mixTracks(tracks: MediaStreamTrack[]): MediaStreamTrack {
  const context = new AudioContext({ sampleRate: 48000 });
  mixContext = context;
  const destination = context.createMediaStreamDestination();
  for (const track of tracks) context.createMediaStreamSource(new MediaStream([track])).connect(destination);
  void context.resume().catch(() => undefined);
  return destination.stream.getAudioTracks()[0];
}

function stopExtras(): void {
  for (const item of extraStreams) item.getTracks().forEach((track) => track.stop());
  extraStreams = [];
  const context = mixContext;
  mixContext = undefined;
  if (context) void context.close().catch(() => undefined);
}

async function openCamera(constraints: MediaStreamConstraints): Promise<MediaStream> {
  for (let attempt = 0; ; attempt += 1) {
    try {
      return await navigator.mediaDevices.getUserMedia(constraints);
    } catch (cause) {
      if (attempt >= 2 || !shouldRetry(cause)) throw cause;
      await sleep(500 * (attempt + 1));
    }
  }
}

function shouldRetry(cause: unknown): boolean {
  const detail = cause as { name?: string; message?: string };
  if (detail?.name === 'NotReadableError' || detail?.name === 'AbortError') return true;
  return /timeout starting video source|could not start video source/i.test(detail?.message ?? '');
}

function queueMedia<T>(task: () => Promise<T>): Promise<T> {
  const run = mediaQueue.then(task, task);
  mediaQueue = run.then(() => undefined, () => undefined);
  return run;
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => window.setTimeout(resolve, ms));
}

async function resolveDevice(kind: MediaDeviceKind, wanted: string): Promise<string | undefined> {
  if (!wanted) return undefined;
  const devices = await navigator.mediaDevices.enumerateDevices().catch(() => [] as MediaDeviceInfo[]);
  const found = pickDevice(devices, kind, wanted);
  if (found) return found.deviceId;
  if (!devices.some((item) => !item.label)) return wanted;
  await grantLabels();
  const refreshed = await navigator.mediaDevices.enumerateDevices().catch(() => [] as MediaDeviceInfo[]);
  return pickDevice(refreshed, kind, wanted)?.deviceId ?? wanted;
}

function pickDevice(devices: MediaDeviceInfo[], kind: MediaDeviceKind, wanted: string): MediaDeviceInfo | undefined {
  const list: CaptureDevice[] = devices.map((item) => ({ id: item.deviceId, name: item.label, kind: item.kind === 'audioinput' ? ('audio' as const) : ('video' as const) }));
  const hit = matchDevice(list, kind === 'audioinput' ? 'audio' : 'video', wanted);
  return hit ? devices.find((item) => item.deviceId === hit.id) : undefined;
}

export async function applySize(width: number, height: number, fps: number): Promise<boolean> {
  const track = stream?.getVideoTracks()[0];
  if (!track) return false;
  desiredSize = { width, height, fps };
  const attempts: MediaTrackConstraints[] = [
    { width: { exact: width }, height: { exact: height }, frameRate: { exact: fps } },
    { width: { ideal: width }, height: { ideal: height }, frameRate: { ideal: fps } },
  ];
  for (const constraints of attempts) {
    const applied = await track.applyConstraints(constraints).then(() => true).catch(() => false);
    if (applied && sizeApplied(track, width, height, fps)) return true;
  }
  return false;
}

function sizeApplied(track: MediaStreamTrack, width: number, height: number, fps: number): boolean {
  const settings = track.getSettings();
  const actualFps = Number(settings.frameRate ?? 0);
  return Math.round(Number(settings.width ?? 0)) === Math.round(width)
    && Math.round(Number(settings.height ?? 0)) === Math.round(height)
    && Number.isFinite(actualFps)
    && actualFps > 0
    && Math.abs(actualFps - fps) <= 0.5;
}

export function closeStream(): void {
  fpsCache.clear();
  recordTrack = undefined;
  recordSourceLabel = '';
  stopExtras();
  if (!stream) return;
  stream.getTracks().forEach((track) => track.stop());
  stream = undefined;
  revision += 1;
}

export function streamInfo(): StreamInfo {
  const track = stream?.getVideoTracks()[0];
  const settings = track?.getSettings();
  return {
    width: Math.round(Number(settings?.width ?? 0)),
    height: Math.round(Number(settings?.height ?? 0)),
    fps: Number.isFinite(settings?.frameRate) && Number(settings?.frameRate) > 0 ? Number(settings?.frameRate) : 0,
    hasAudio: Boolean(stream?.getAudioTracks().length),
    revision,
  };
}

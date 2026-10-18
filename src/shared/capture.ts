import type { CaptureDevice, CaptureFormat, CaptureMode } from './types.js';

export interface Resolution {
  width: number;
  height: number;
}

export function formatLabel(format: CaptureFormat): string {
  return format === 'yuy2' ? 'YUY2' : 'NV12';
}

export function modeFormats(modes: CaptureMode[], current?: CaptureFormat): CaptureFormat[] {
  if (!modes.length) return current ? [current] : ['nv12', 'yuy2'];
  const list: CaptureFormat[] = [];
  for (const item of modes) if (!list.includes(item.format)) list.push(item.format);
  if (current && !list.includes(current)) list.push(current);
  return list;
}

export function modeResolutions(modes: CaptureMode[], format: CaptureFormat): Resolution[] {
  const list: Resolution[] = [];
  for (const item of modes) {
    if (item.format === format && !list.some((hit) => hit.width === item.width && hit.height === item.height)) list.push({ width: item.width, height: item.height });
  }
  return list.sort((left, right) => right.width * right.height - left.width * left.height);
}

export function modeFpsList(modes: CaptureMode[], format: CaptureFormat, width: number, height: number, current?: number): number[] {
  const list = new Set<number>();
  for (const item of modes) {
    if (item.format !== format || item.width !== width || item.height !== height) continue;
    for (const fps of [...fpsOptions, item.minFps, item.maxFps, current ?? 0]) {
      const rounded = Math.round(fps);
      if (rounded >= item.minFps && rounded <= item.maxFps) list.add(rounded);
    }
  }
  return [...list].sort((left, right) => left - right);
}

export function clampModeFps(mode: CaptureMode, fps: number): number {
  return Math.min(mode.maxFps, Math.max(mode.minFps, Math.round(fps)));
}

export function pickMode(modes: CaptureMode[], format: CaptureFormat, width: number, height: number, fps: number): CaptureMode | undefined {
  const candidates = modes.filter((item) => item.format === format);
  if (!candidates.length) return undefined;
  const ranked = candidates.slice().sort((left, right) => modeGap(left, width, height, fps) - modeGap(right, width, height, fps));
  return ranked[0];
}

function modeGap(mode: CaptureMode, width: number, height: number, fps: number): number {
  return Math.abs(mode.width * mode.height - width * height) * 1000 + Math.abs(mode.width - width) + Math.abs(mode.height - height) + Math.max(0, mode.minFps - fps, fps - mode.maxFps) * 100;
}

export interface MimeChoice {
  type: string;
  ext: string;
  codec: string;
}

export const resolutionPresets: Resolution[] = [
  { width: 3840, height: 2160 },
  { width: 2560, height: 1440 },
  { width: 1920, height: 1080 },
  { width: 1280, height: 720 },
  { width: 960, height: 540 },
];

export const fpsOptions = [30, 60];

const mp4Bases = [
  { type: 'video/mp4', ext: 'mp4', video: 'avc1', audio: 'mp4a.40.2' },
  { type: 'video/x-matroska', ext: 'mkv', video: 'avc1', audio: 'opus' },
];

const webmBases = [
  { type: 'video/webm', ext: 'webm', video: 'h264', audio: 'opus' },
  { type: 'video/webm', ext: 'webm', video: 'vp9', audio: 'opus' },
  { type: 'video/webm', ext: 'webm', video: 'vp8', audio: 'opus' },
];

const hevcBases = [
  { type: 'video/mp4', ext: 'mp4', video: 'hvc1.1.6.L150.B0', audio: 'mp4a.40.2' },
];

export type MimeOrder = 'default' | 'webm' | 'hevc';

export function isH264(mime: string, codec: string): boolean {
  const text = `${mime} ${codec}`.toLowerCase();
  return text.includes('avc1') || text.includes('h264');
}

export function resolutionKey(width: number, height: number): string {
  return `${width}x${height}`;
}

export function resolutionText(width: number, height: number): string {
  return `${width} x ${height}`;
}

export function resolutionList(device?: CaptureDevice, current?: Resolution): Resolution[] {
  const maxWidth = device?.maxWidth ?? 0;
  const maxHeight = device?.maxHeight ?? 0;
  const list: Resolution[] = [];
  const pick = (width: number, height: number): void => {
    if (width > 0 && height > 0 && !list.some((item) => item.width === width && item.height === height)) list.push({ width, height });
  };
  const usable = maxWidth && maxHeight ? resolutionPresets.filter((item) => item.width <= maxWidth && item.height <= maxHeight) : resolutionPresets;
  if (!usable.length) pick(maxWidth, maxHeight);
  usable.forEach((item) => pick(item.width, item.height));
  if (current) pick(current.width, current.height);
  return list.sort((left, right) => right.width * right.height - left.width * left.height);
}

export function fpsList(device?: CaptureDevice, current?: number, probed?: number[]): number[] {
  if (probed?.length) {
    const list = probed
      .map((item) => Math.round(item))
      .filter((item) => item > 0)
      .filter((item, index, all) => all.indexOf(item) === index)
      .sort((left, right) => left - right);
    const value = Math.round(current ?? 0);
    if (value > 0 && value <= list[list.length - 1] && !list.includes(value)) list.push(value);
    return list.sort((left, right) => left - right);
  }
  const maxFps = device?.maxFps ?? 0;
  const usable = maxFps ? fpsOptions.filter((item) => item <= maxFps) : fpsOptions;
  const list = usable.length ? usable.slice() : [Math.round(maxFps)];
  for (const value of [current ?? 0]) {
    const fps = Math.round(value);
    if (fps > 0 && (fps <= maxFps || !maxFps) && !list.includes(fps)) list.push(fps);
  }
  return list.sort((left, right) => left - right);
}

export function mimeCandidates(hasAudio: boolean, order: MimeOrder = 'default'): MimeChoice[] {
  const bases = order === 'hevc'
    ? [...hevcBases, ...mp4Bases, ...webmBases]
    : order === 'webm'
      ? [...webmBases, ...mp4Bases]
      : [...mp4Bases, ...webmBases];
  const list: MimeChoice[] = [];
  for (const item of bases) {
    if (hasAudio) list.push({ type: `${item.type};codecs=${item.video},${item.audio}`, ext: item.ext, codec: item.video });
    list.push({ type: `${item.type};codecs=${item.video}`, ext: item.ext, codec: item.video });
  }
  list.push({ type: 'video/webm', ext: 'webm', codec: 'vp8' });
  return list;
}

export function chooseMime(supported: (type: string) => boolean, hasAudio: boolean, order: MimeOrder = 'default'): MimeChoice | undefined {
  return mimeCandidates(hasAudio, order).find((item) => supported(item.type));
}

const chipSuffix = /\s*\([0-9a-f]{4}:[0-9a-f]{4}\)$/i;

export function deviceName(label: string): string {
  return label.replace(chipSuffix, '').trim() || label.trim();
}

export function deviceKey(text: string): string {
  return deviceName(text).toLowerCase();
}

export function cleanNames(devices: CaptureDevice[]): CaptureDevice[] {
  const counts = new Map<string, number>();
  for (const item of devices) {
    const key = `${item.kind}:${deviceKey(item.name)}`;
    counts.set(key, (counts.get(key) ?? 0) + 1);
  }
  return devices.map((item) => ((counts.get(`${item.kind}:${deviceKey(item.name)}`) ?? 1) > 1 ? item : { ...item, name: deviceName(item.name) }));
}

export function matchDevice(devices: CaptureDevice[], kind: 'video' | 'audio', wanted?: string): CaptureDevice | undefined {
  if (!wanted) return undefined;
  const list = devices.filter((item) => item.kind === kind);
  const key = deviceKey(wanted);
  return list.find((item) => item.id === wanted)
    ?? list.find((item) => item.name === wanted)
    ?? list.find((item) => deviceKey(item.name) === key);
}

export function deviceLabel(device: CaptureDevice): string {
  return device.name || `${device.kind === 'video' ? '视频' : '音频'}设备`;
}

export function formatText(format?: string): string {
  if (!format) return '未开始采集';
  return format.replace(/^video\//, '').replace(/;codecs=/, ' · ');
}

import type { CaptureDevice } from './types.js';

export interface Resolution {
  width: number;
  height: number;
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
  if (device) pick(device.nativeWidth ?? 0, device.nativeHeight ?? 0);
  if (current) pick(current.width, current.height);
  return list.sort((left, right) => right.width * right.height - left.width * left.height);
}

export function fpsList(device?: CaptureDevice, current?: number): number[] {
  const maxFps = device?.maxFps ?? 0;
  const usable = maxFps ? fpsOptions.filter((item) => item <= maxFps) : fpsOptions;
  const list = usable.length ? usable.slice() : [Math.round(maxFps)];
  for (const value of [device?.nativeFps ?? 0, current ?? 0]) {
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

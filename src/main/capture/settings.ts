import { defaultSettings, defaultThemeColor } from '../../shared/constants.js';
import { clampQuality } from '../../shared/bitrate.js';
import { backgroundDir, insidePath } from '../store/path.js';
import type { CaptureFormat, RecordSettings } from '../../shared/types.js';

const encoderNames = new Set<RecordSettings['encoder']>(['auto', 'nvidia', 'amd', 'intel', 'software']);
const captureFormats = new Set<CaptureFormat>(['nv12', 'yuy2']);
const textLimit = 300;

function pickNumber(value: unknown, min: number, max: number, fallback: number): number {
  const number = Number(value);
  return Number.isFinite(number) ? Math.min(max, Math.max(min, Math.round(number))) : fallback;
}

function pickText(value: unknown): string {
  if (typeof value !== 'string') return '';
  return value.slice(0, textLimit).replace(/\p{Cc}/gu, '');
}

function pickColor(value: unknown, fallback: string): string {
  const text = typeof value === 'string' ? value.trim().toLowerCase() : '';
  return /^#[0-9a-f]{6}$/.test(text) ? text : fallback;
}

function pickBackground(value: unknown, fallback: string): string {
  const path = pickText(value);
  if (!path) return '';
  return insidePath(backgroundDir, path) ? path : fallback;
}

export function sanitizeSettings(raw: unknown, current: RecordSettings): RecordSettings {
  const input = (raw && typeof raw === 'object' ? raw : {}) as Record<string, unknown>;
  const encoder = String(input.encoder ?? current.encoder) as RecordSettings['encoder'];
  const captureFormat = String(input.captureFormat ?? current.captureFormat) as CaptureFormat;
  return {
    videoDevice: pickText(input.videoDevice ?? current.videoDevice),
    audioDevice: pickText(input.audioDevice ?? current.audioDevice),
    desktopAudio: Boolean(input.desktopAudio ?? current.desktopAudio),
    micAudio: Boolean(input.micAudio ?? current.micAudio),
    micDevice: pickText(input.micDevice ?? current.micDevice),
    captureFormat: captureFormats.has(captureFormat) ? captureFormat : 'nv12',
    width: pickNumber(input.width, 320, 7680, current.width || defaultSettings.width),
    height: pickNumber(input.height, 180, 4320, current.height || defaultSettings.height),
    fps: pickNumber(input.fps, 1, 240, current.fps || defaultSettings.fps),
    flipVertical: Boolean(input.flipVertical ?? current.flipVertical),
    encoder: encoderNames.has(encoder) ? encoder : 'auto',
    quality: clampQuality(input.quality ?? current.quality),
    saveDir: pickText(input.saveDir ?? current.saveDir),
    autoPush: Boolean(input.autoPush ?? current.autoPush),
    autoRecord: Boolean(input.autoRecord ?? current.autoRecord),
    autoLaunch: Boolean(input.autoLaunch ?? current.autoLaunch),
    blurNickname: Boolean(input.blurNickname ?? current.blurNickname),
    monitorAudio: Boolean(input.monitorAudio ?? current.monitorAudio),
    pollSeconds: pickNumber(input.pollSeconds, 10, 600, current.pollSeconds),
    updateProxy: Boolean(input.updateProxy ?? current.updateProxy),
    updateCheck: Boolean(input.updateCheck ?? current.updateCheck),
    themeColor: pickColor(input.themeColor ?? current.themeColor, current.themeColor || defaultThemeColor),
    backgroundPath: pickBackground(input.backgroundPath ?? current.backgroundPath, current.backgroundPath),
    backgroundDim: pickNumber(input.backgroundDim ?? current.backgroundDim, 0, 100, current.backgroundDim ?? 40),
  };
}

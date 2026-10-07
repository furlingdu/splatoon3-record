import { defaultSettings } from '../../shared/constants.js';
import { clampQuality } from '../../shared/bitrate.js';
import type { RecordSettings } from '../../shared/types.js';

const encoderNames = new Set<RecordSettings['encoder']>(['auto', 'nvidia', 'amd', 'intel', 'software']);
const textLimit = 300;

function pickNumber(value: unknown, min: number, max: number, fallback: number): number {
  const number = Number(value);
  return Number.isFinite(number) ? Math.min(max, Math.max(min, Math.round(number))) : fallback;
}

function pickText(value: unknown): string {
  if (typeof value !== 'string') return '';
  return value.slice(0, textLimit).replace(/\p{Cc}/gu, '');
}

export function sanitizeSettings(raw: unknown, current: RecordSettings): RecordSettings {
  const input = (raw && typeof raw === 'object' ? raw : {}) as Record<string, unknown>;
  const encoder = String(input.encoder ?? current.encoder) as RecordSettings['encoder'];
  return {
    videoDevice: pickText(input.videoDevice ?? current.videoDevice),
    audioDevice: pickText(input.audioDevice ?? current.audioDevice),
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
  };
}

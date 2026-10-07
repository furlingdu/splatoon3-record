import { pushBitrateDefault, pushTargetMb, qualityDefault, qualityTiers } from './constants.js';

export const recordAudioBps = 192000;
export const pushAudioBps = 96000;

const fileMargin = 0.95;
const lowestBps = 200000;

export function clampQuality(value: unknown): number {
  const number = Number(value);
  if (!Number.isFinite(number)) return qualityDefault;
  return qualityTiers.reduce((best, tier) => (Math.abs(tier - number) <= Math.abs(best - number) ? tier : best), qualityTiers[0]);
}

export function liveBitrateBps(width: number, height: number): number {
  const short = Math.min(Math.abs(Math.round(width)), Math.abs(Math.round(height)));
  if (short >= 2160) return 80000000;
  if (short >= 1440) return 50000000;
  if (short >= 1080) return 40000000;
  if (short >= 720) return 20000000;
  return 12000000;
}

export function recordFallbackBps(width: number, height: number): number {
  return liveBitrateBps(width, height) * 2;
}

export function pushCapBps(cap: number): number {
  const number = Number(cap);
  return Number.isFinite(number) && number > 0 ? Math.round(number * 1000000) : tierBps(pushBitrateDefault);
}

function tierBps(mbps: number): number {
  return Math.max(1, Math.round(mbps)) * 1000000;
}

export function budgetBps(durationMs: number, targetMb: number = pushTargetMb): number {
  const seconds = Math.max(1, Number(durationMs) / 1000);
  const total = (targetMb * 1024 * 1024 * 8 * fileMargin) / seconds;
  return Math.max(lowestBps, Math.floor(total - pushAudioBps));
}

export function pushBitrate(cap: number, durationMs: number, targetMb: number = pushTargetMb): number {
  return Math.max(lowestBps, Math.min(pushCapBps(cap), budgetBps(durationMs, targetMb)));
}

export function estimateBytes(bitrate: number, seconds: number, audioBps: number = recordAudioBps): number {
  return Math.round(((bitrate + audioBps) * Math.max(1, seconds)) / 8);
}

export function pushSizeText(cap: number, seconds: number, targetMb: number = pushTargetMb): string {
  const bitrate = pushBitrate(cap, seconds * 1000, targetMb);
  return `${Math.round(seconds / 60)} 分钟对局约 ${sizeText(bitrate, seconds, pushAudioBps)}`;
}

export function pushCodecLabel(codec: string): string {
  if (codec === 'hevc' || codec === 'h265') return 'HEVC';
  if (codec === 'h264') return 'H.264';
  return 'AV1';
}

function sizeText(bitrate: number, seconds: number, audioBps: number): string {
  return `${Math.round(estimateBytes(bitrate, seconds, audioBps) / 1024 / 1024)} MB`;
}

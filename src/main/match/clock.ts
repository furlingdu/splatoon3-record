import type { VideoRecord } from '../../shared/types.js';

export const battleDelayMs = 22000;
export const clipLeadMs = 15000;
export const clipTailMs = 30000;

export interface CropPart {
  record: VideoRecord;
  offset: number;
  duration: number;
}

export function matchClock(endAt: number, duration: number): { startAt: number; endAt: number; duration: number } {
  const safeDuration = Math.max(0, Math.min(duration, 360000));
  const safeEnd = (Number.isFinite(endAt) ? endAt : Date.now()) + battleDelayMs;
  return { startAt: safeEnd - safeDuration, endAt: safeEnd, duration: safeDuration };
}

export function clipRange(match: { startAt: number; endAt: number }): { startAt: number; endAt: number } {
  return { startAt: match.startAt - clipLeadMs, endAt: match.endAt + clipTailMs };
}

export function recordOverlap(record: VideoRecord, startAt: number, endAt: number): CropPart | undefined {
  const from = Math.max(startAt, record.startAt);
  const to = Math.min(endAt, record.endAt);
  if (to <= from) return undefined;
  return { record, offset: (from - record.startAt) / 1000, duration: (to - from) / 1000 };
}

export function cropParts(records: VideoRecord[], clip: { startAt: number; endAt: number }): CropPart[] {
  const ordered = records.slice().sort((a, b) => a.startAt - b.startAt);
  const parts: CropPart[] = [];
  let boundary = Number.NEGATIVE_INFINITY;
  for (const record of ordered) {
    const from = Math.max(clip.startAt, record.startAt, boundary);
    const to = Math.min(clip.endAt, record.endAt);
    if (to > from) parts.push({ record, offset: (from - record.startAt) / 1000, duration: (to - from) / 1000 });
    boundary = Math.max(boundary, record.endAt);
  }
  return parts;
}

export function utcText(value: number): string {
  return new Date(value).toISOString();
}

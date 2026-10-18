import type { BattleMatch, VideoRecord } from '../../shared/types.js';
import { cacheMinutesFixed } from '../../shared/constants.js';
import { matchKey } from '../../shared/nso.js';

export function isNewMatch(match: BattleMatch, handledIds: string[]): boolean {
  return !handledIds.includes(matchKey(match));
}

export function freshRecords(records: VideoRecord[], now: number, cacheMinutes: number): { keep: VideoRecord[]; drop: VideoRecord[] } {
  const threshold = now - cacheMinutes * 60000;
  return { keep: records.filter((item) => item.endAt >= threshold), drop: records.filter((item) => item.endAt < threshold) };
}

export function mergeHandled(handledIds: string[], matchId: string, limit = 200): string[] {
  if (handledIds.includes(matchId)) return handledIds;
  return [...handledIds, matchId].slice(-limit);
}

export function dedupeMatches(matches: BattleMatch[], handledIds: string[]): BattleMatch[] {
  const seen = new Set<string>();
  return matches.filter((match) => {
    const key = matchKey(match);
    if (handledIds.includes(key) || seen.has(key)) return false;
    seen.add(key);
    return true;
  });
}

export function afterBaseline(match: BattleMatch, baselineAt?: number): boolean {
  return baselineAt === undefined || match.endAt > baselineAt;
}

export function retryMatch(match: BattleMatch, now = Date.now()): boolean {
  return match.startAt >= now - cacheMinutesFixed * 60000;
}

export function recordableMatch(match: BattleMatch, records: VideoRecord[]): boolean {
  if (match.isDisconnected && !match.endAt) return false;
  return records.some((record) => record.startAt <= match.endAt && record.endAt >= match.startAt);
}

export function coveredMatch(match: BattleMatch, records: VideoRecord[]): boolean {
  const relevant = records
    .filter((record) => record.endAt > match.startAt && record.startAt < match.endAt)
    .sort((a, b) => a.startAt - b.startAt);
  let coveredUntil = match.startAt;
  let started = false;
  for (const record of relevant) {
    if (!started && record.startAt > match.startAt) return false;
    if (started && record.startAt > coveredUntil + 1000) return false;
    started = true;
    coveredUntil = Math.max(coveredUntil, record.endAt);
    if (coveredUntil >= match.endAt) return true;
  }
  return false;
}

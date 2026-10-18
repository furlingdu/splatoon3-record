import { matchKey } from '../../shared/nso.js';
import type { BattleMatch } from '../../shared/types.js';

export interface KnownInterval {
  accountId: string;
  startAt: number;
  endAt: number;
}

export interface ConflictInterval extends KnownInterval {
  key: string;
}

export function coreConflict(match: BattleMatch, intervals: Map<string, KnownInterval>): ConflictInterval | undefined {
  const key = matchKey(match);
  for (const [otherKey, other] of intervals) {
    if (otherKey === key || other.accountId === match.accountId) continue;
    if (Math.min(match.endAt, other.endAt) > Math.max(match.startAt, other.startAt)) return { key: otherKey, ...other };
  }
  return undefined;
}

export function rememberInterval(intervals: Map<string, KnownInterval>, match: BattleMatch, windowMs = 30 * 60000, limit = 120): void {
  intervals.set(matchKey(match), { accountId: match.accountId ?? '', startAt: match.startAt, endAt: match.endAt });
  const cutoff = match.endAt - windowMs;
  for (const [key, item] of intervals) if (item.endAt < cutoff) intervals.delete(key);
  while (intervals.size > limit) {
    const first = intervals.keys().next().value;
    if (!first) break;
    intervals.delete(first);
  }
}

export function trimClip(
  clip: { startAt: number; endAt: number },
  match: BattleMatch,
  intervals: Map<string, KnownInterval>,
): { startAt: number; endAt: number } {
  const key = matchKey(match);
  let { startAt, endAt } = clip;
  for (const [otherKey, other] of intervals) {
    if (otherKey === key || other.accountId === match.accountId) continue;
    if (other.endAt <= match.startAt && other.endAt > startAt) startAt = other.endAt;
    if (other.startAt >= match.endAt && other.startAt < endAt) endAt = other.startAt;
  }
  return { startAt, endAt };
}

import { normalizeBattle, normalizeList } from '../match/battle.js';
import { cacheMinutesFixed } from '../../shared/constants.js';
import { matchKey } from '../../shared/nso.js';
import type { BattleMatch } from '../../shared/types.js';
import { SplatnetClient, queryHash } from './splatnet.js';
import { logApp } from '../store/log.js';

export interface BattleAccount {
  accountId: string;
  nickname: string;
}

export interface BattleQuery {
  getBattles: () => Promise<BattleMatch[]>;
}

const detailLimit = 8;
const detailWorkers = 3;
const detailRetryMs = 60000;

function attach(match: BattleMatch, account?: BattleAccount): BattleMatch {
  if (!account) return match;
  const value = { ...match, accountId: account.accountId, accountNickname: account.nickname };
  return { ...value, key: matchKey(value) };
}

function validDetail(match: BattleMatch, summaryId: string): boolean {
  return match.matchId === summaryId && Boolean(match.timeExact) && match.duration > 0 && match.endAt > match.startAt;
}

export function makeQuery(client: SplatnetClient, account?: BattleAccount, logger: (line: string) => void = logApp): BattleQuery {
  const detailCache = new Map<string, BattleMatch>();
  const failedAt = new Map<string, number>();
  const trimFailures = (): void => {
    if (failedAt.size <= 300) return;
    const first = failedAt.keys().next().value;
    if (first) failedAt.delete(first);
  };
  return {
    async getBattles(): Promise<BattleMatch[]> {
      const battleValue = await client.request(queryHash.latest);
      const seen = new Set<string>();
      const summaries = normalizeList(battleValue)
        .filter((match) => !match.isSalmon && match.kind !== 'salmon')
        .filter((match) => {
          if (seen.has(match.matchId)) return false;
          seen.add(match.matchId);
          return true;
        })
        .sort((a, b) => b.endAt - a.endAt);
      const cutoff = Date.now() - cacheMinutesFixed * 60000;
      const dated = summaries.filter((match) => match.endAt > 0 && match.endAt >= cutoff);
      const candidates = (dated.length ? [...dated, ...summaries.slice(0, 1)] : summaries.slice(0, 3))
        .filter((match, index, list) => list.findIndex((item) => item.matchId === match.matchId) === index)
        .slice(0, detailLimit);
      const resolved: BattleMatch[] = [];
      for (let index = 0; index < candidates.length; index += detailWorkers) {
        const batch = candidates.slice(index, index + detailWorkers);
        const values = await Promise.all(batch.map(async (summary) => {
          const cached = detailCache.get(summary.matchId);
          if (cached) return cached;
          const failed = failedAt.get(summary.matchId) ?? 0;
          if (Date.now() - failed < detailRetryMs) return undefined;
          const startedAt = Date.now();
          try {
            const detail = await client.request(queryHash.detail, { vsResultId: summary.matchId });
            const full = normalizeBattle(detail);
            if (!full || !validDetail(full, summary.matchId)) {
              failedAt.set(summary.matchId, Date.now());
              logger(`match detail rejected id=${summary.matchId} reason=${full ? 'invalid-time' : 'empty'} elapsed=${Date.now() - startedAt}ms`);
              trimFailures();
              return undefined;
            }
            detailCache.set(summary.matchId, full);
            failedAt.delete(summary.matchId);
            if (detailCache.size > 300) {
              const first = detailCache.keys().next().value;
              if (first) detailCache.delete(first);
            }
            return full;
          } catch (error) {
            failedAt.set(summary.matchId, Date.now());
            logger(`match detail failed id=${summary.matchId} elapsed=${Date.now() - startedAt}ms error=${error instanceof Error ? error.message.slice(0, 160) : String(error).slice(0, 160)}`);
            trimFailures();
            return undefined;
          }
        }));
        for (const match of values) if (match) resolved.push(attach(match, account));
      }
      return resolved.sort((a, b) => b.endAt - a.endAt);
    },
  };
}

import { normalizeBattle, normalizeList } from '../match/battle.js';
import { cacheMinutesFixed } from '../../shared/constants.js';
import type { BattleMatch } from '../../shared/types.js';
import { SplatnetClient, queryHash } from './splatnet.js';

export interface BattleQuery {
  getBattles: () => Promise<BattleMatch[]>;
}

export function makeQuery(client: SplatnetClient): BattleQuery {
  const detailCache = new Map<string, BattleMatch>();
  return {
    async getBattles(): Promise<BattleMatch[]> {
      const battleValue = await client.request(queryHash.latest);
      const summaries = normalizeList(battleValue)
        .filter((match) => !match.isSalmon && match.kind !== 'salmon')
        .sort((a, b) => b.endAt - a.endAt);
      const cutoff = Date.now() - cacheMinutesFixed * 60000;
      const recent = summaries.filter((match) => match.endAt >= cutoff);
      const candidates = recent.length ? recent : summaries.slice(0, 1);
      const resolved = await Promise.all(candidates.map(async (match) => {
        const cached = detailCache.get(match.matchId);
        if (cached) return cached;
        try {
          const detail = await client.request(queryHash.detail, { vsResultId: match.matchId });
          const full = normalizeBattle(detail);
          if (full) detailCache.set(match.matchId, full);
          return full ?? match;
        } catch {
          return match;
        }
      }));
      return resolved.sort((a, b) => b.endAt - a.endAt);
    },
  };
}

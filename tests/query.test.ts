import { afterEach, describe, expect, it, vi } from 'vitest';
import { makeQuery } from '../src/main/nso/query.js';
import { battleDelayMs } from '../src/main/match/clock.js';
import { queryHash, SplatnetClient } from '../src/main/nso/splatnet.js';

afterEach(() => {
  vi.useRealTimers();
});

describe('makeQuery', () => {
  it('只补全缓存时间窗内的普通对战', async () => {
    const now = Date.parse('2026-01-01T01:00:00Z');
    vi.setSystemTime(now);
    const times = [now - 11 * 60000, now - 5 * 60000, now - 60000];
    const raw = {
      data: {
        latestBattleHistories: {
          historyGroups: {
            nodes: [{
              historyDetails: {
                nodes: times.map((playedTime, index) => ({
                  vsHistoryDetail: {
                    id: `m${index}`,
                  playedTime: new Date(playedTime - 180000).toISOString(),
                    duration: 180,
                    vsMode: 'REGULAR',
                    rule: 'TURF_WAR',
                    judgement: 'WIN',
                  },
                })),
              },
            }],
          },
        },
        coopResult: {
          nodes: [{ coopHistoryDetail: { id: 'c1', playedTime: new Date(now - 60000).toISOString(), rule: 'COOP_GROUP' } }],
        },
      },
    };
    const client = {
      request: vi.fn(async (hash: string, variable: Record<string, unknown>) => {
        if (hash === queryHash.latest) return raw;
        if (hash === queryHash.coop) return { data: { coopResult: { nodes: [] } } };
        if (hash === queryHash.detail) {
          const id = String(variable.vsResultId ?? '');
          return { data: { vsHistoryDetail: { id, playedTime: new Date(times[Number(id.slice(1))] - 180000).toISOString(), duration: 180, vsMode: 'REGULAR', rule: 'TURF_WAR', judgement: 'WIN' } } };
        }
        return { data: {} };
      }),
    } as unknown as SplatnetClient;
    const list = await makeQuery(client).getBattles();
    expect(list.map((match) => match.matchId)).toEqual(['m2', 'm1']);
    expect(list[0].endAt).toBe(times[2] + battleDelayMs);
    expect(list[0].duration).toBe(180000);
    expect(client.request).toHaveBeenCalledWith(queryHash.detail, { vsResultId: 'm2' });
    expect(client.request).toHaveBeenCalledWith(queryHash.detail, { vsResultId: 'm1' });
    expect(client.request).not.toHaveBeenCalledWith(queryHash.detail, { vsResultId: 'm0' });
    expect(client.request).not.toHaveBeenCalledWith(queryHash.coop);
    expect(client.request).not.toHaveBeenCalledWith(queryHash.coopDetail, expect.anything());
  });

  it('NSO 对战查询失败时向轮询抛出错误', async () => {
    const client = { request: vi.fn().mockRejectedValue(new Error('network down')) } as unknown as SplatnetClient;
    await expect(makeQuery(client).getBattles()).rejects.toThrow('network down');
    expect(client.request).toHaveBeenCalledTimes(1);
  });
});

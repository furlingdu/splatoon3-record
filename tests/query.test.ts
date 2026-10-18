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

  it('历史摘要缺少时间且详情失败时不返回可裁剪对局', async () => {
    const summaries = Array.from({ length: 35 }, (_, index) => ({
      vsHistoryDetail: { id: `history-${index}`, vsMode: 'BANKARA', rule: 'AREA' },
    }));
    const raw = { data: { latestBattleHistories: { historyGroups: { nodes: [{ historyDetails: { nodes: summaries } }] } } } };
    const request = vi.fn(async (hash: string) => {
      if (hash === queryHash.latest) return raw;
      throw new Error('detail timeout');
    });
    const client = { request } as unknown as SplatnetClient;
    const list = await makeQuery(client, { accountId: '1001', nickname: '小号' }, () => undefined).getBattles();
    expect(list).toEqual([]);
    const detailCalls = request.mock.calls.filter(([hash]) => hash === queryHash.detail);
    expect(detailCalls).toHaveLength(3);
  });

  it('详情失败后不退回摘要，详情恢复后可以正常处理', async () => {
    const summary = { vsHistoryDetail: { id: 'recover', vsMode: 'BANKARA', rule: 'AREA' } };
    const raw = { data: { latestBattleHistories: { historyGroups: { nodes: [{ historyDetails: { nodes: [summary] } }] } } } };
    let fail = true;
    const request = vi.fn(async (hash: string) => {
      if (hash === queryHash.latest) return raw;
      if (fail) throw new Error('temporary');
      return { data: { vsHistoryDetail: { id: 'recover', playedTime: '2026-01-01T00:55:00Z', duration: 180, vsMode: 'BANKARA', rule: 'AREA', judgement: 'WIN' } } };
    });
    vi.setSystemTime(Date.parse('2026-01-01T01:00:00Z'));
    const query = makeQuery({ request } as unknown as SplatnetClient, { accountId: '1001', nickname: '小号' }, () => undefined);
    expect(await query.getBattles()).toEqual([]);
    fail = false;
    vi.setSystemTime(Date.parse('2026-01-01T01:01:10Z'));
    const list = await query.getBattles();
    expect(list.map((match) => match.key)).toEqual(['1001:recover']);
    expect(list[0].timeExact).toBe(true);
  });
});

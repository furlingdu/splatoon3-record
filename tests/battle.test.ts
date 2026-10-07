import { describe, expect, it } from 'vitest';
import { battleKind, normalizeBattle, normalizeList } from '../src/main/match/battle.js';
import { battleDelayMs } from '../src/main/match/clock.js';
import { matchFileName, matchTitle } from '../src/shared/nso.js';

describe('battleKind', () => {
  it('识别各比赛类型', () => {
    expect(battleKind('VnNNb2RlLXJlZ3VsYXI=', 'TURF_WAR')).toBe('regular');
    expect(battleKind('mode', 'BANKARA_OPEN')).toBe('anarchyOpen');
    expect(battleKind('mode', 'BANKARA_CHALLENGE')).toBe('anarchySeries');
    expect(battleKind('mode', 'X_MATCH')).toBe('xBattle');
    expect(battleKind('mode', 'LEAGUE_MATCH')).toBe('event');
    expect(battleKind('mode', 'FEST')).toBe('splatfest');
    expect(battleKind('mode', 'PRIVATE_MATCH')).toBe('private');
    expect(battleKind('COOP', '', true)).toBe('salmon');
    expect(battleKind('COOP_GROUP', '')).toBe('salmon');
  });
});

describe('normalizeBattle', () => {
  it('按结束时间与持续时间反推开始时间', () => {
    const raw = { vsHistoryDetail: { id: 'vs-1', playedTime: '2023-11-14T12:00:00Z', duration: 180000, vsMode: 'REGULAR', rule: 'TURF_WAR', judgement: 'WIN' } };
    const match = normalizeBattle(raw);
    expect(match?.matchId).toBe('vs-1');
    expect(match?.startAt).toBe(Date.parse('2023-11-14T12:00:00Z') + battleDelayMs);
    expect(match?.endAt).toBe(Date.parse('2023-11-14T12:03:00Z') + battleDelayMs);
    expect(match?.duration).toBe(180000);
    expect(match?.startAt).toBe(match!.endAt - match!.duration);
    expect(match?.kind).toBe('regular');
    expect(match?.isDisconnected).toBe(false);
    expect(match?.rawData).toEqual(raw);
  });

  it('秒级持续时间转换为毫秒', () => {
    const match = normalizeBattle({ vsHistoryDetail: { id: 'vs-2', playedTime: '2023-11-14T12:00:00Z', duration: 180 } });
    expect(match?.duration).toBe(180000);
  });

  it('解析当前详情数据结构与蛮颓挑战类型', () => {
    const match = normalizeBattle({ data: { vsHistoryDetail: { id: 'vs-detail', playedTime: '2023-11-14T12:00:00Z', duration: 318, vsMode: { mode: 'BANKARA' }, vsRule: { rule: 'AREA' }, bankaraMatch: { mode: 'CHALLENGE' }, judgement: 'WIN' } } });
    expect(match?.startAt).toBe(Date.parse('2023-11-14T12:00:00Z') + battleDelayMs);
    expect(match?.endAt).toBe(Date.parse('2023-11-14T12:05:18Z') + battleDelayMs);
    expect(match?.duration).toBe(318000);
    expect(match?.kind).toBe('anarchySeries');
    expect(match?.rule).toBe('AREA');
  });

  it('playedTime 表示匹配成功时刻，开战时间顺延到加载与开场镜头之后', () => {
    const match = normalizeBattle({ vsHistoryDetail: { id: 'reported', playedTime: '2026-08-30T05:53:28Z', duration: 300 } });
    expect(match?.startAt).toBe(Date.parse('2026-08-30T05:53:28Z') + battleDelayMs);
    expect(match?.endAt).toBe(Date.parse('2026-08-30T05:58:28Z') + battleDelayMs);
  });

  it('解析掉线标记', () => {
    const match = normalizeBattle({ vsHistoryDetail: { id: 'vs-3', playedTime: '2023-11-14T12:00:00Z', judgement: 'DISCONNECTED' } });
    expect(match?.isDisconnected).toBe(true);
  });

  it('鲑鱼跑数据标记 isSalmon', () => {
    const match = normalizeBattle({ coopHistoryDetail: { id: 'coop-1', playedTime: '2023-11-14T12:00:00Z', rule: 'COOP_GROUP' } }, true);
    expect(match?.isSalmon).toBe(true);
    expect(match?.kind).toBe('salmon');
  });

  it('缺少 id 时返回 undefined', () => {
    expect(normalizeBattle({ vsHistoryDetail: {} })).toBeUndefined();
  });
});

describe('normalizeList', () => {
  it('解析 historyGroups 嵌套结构并按时间排序由调用方处理', () => {
    const raw = {
      data: {
        latestBattleHistories: {
          historyGroups: {
            nodes: [
              {
                historyDetails: {
                  nodes: [{ vsHistoryDetail: { id: 'g1', playedTime: '2023-11-14T12:00:00Z' } }],
                },
              },
            ],
          },
        },
        coopResult: {
          nodes: [{ coopHistoryDetail: { id: 'c1', playedTime: '2023-11-14T11:00:00Z' } }],
        },
      },
    };
    const list = normalizeList(raw);
    expect(list.map((item) => item.matchId).sort()).toEqual(['c1', 'g1']);
    expect(list.find((item) => item.matchId === 'c1')?.isSalmon).toBe(true);
  });
});

describe('matchFileName', () => {
  it('按对战格式与结束时间命名，时间用文件名安全写法', () => {
    const endAt = new Date(2026, 8, 16, 22, 15, 30).getTime();
    expect(matchFileName({ kind: 'regular', endAt })).toBe('占地对战-20260916-221530');
    expect(matchFileName({ kind: 'anarchyOpen', endAt })).toBe('蛮颓比赛（开放）-20260916-221530');
  });

  it('不带 base64 的 matchId 片段且与标题同源', () => {
    const match = { kind: 'xBattle' as const, endAt: new Date(2026, 0, 2, 3, 4, 5).getTime() };
    const name = matchFileName(match);
    expect(name).not.toMatch(/[^\u4e00-\u9fa5A-Za-z0-9（）-]/);
    expect(matchTitle(match).startsWith('X对战-')).toBe(true);
    expect(name.startsWith('X对战-')).toBe(true);
    expect(name).not.toContain('/');
  });
});

import { describe, expect, it } from 'vitest';
import { coreConflict, rememberInterval, trimClip, type KnownInterval } from '../src/main/match/conflict.js';
import { clipRange } from '../src/main/match/clock.js';
import { makeMatch } from './helpers.js';

describe('跨账户录像冲突', () => {
  it('不同账户的比赛主体重叠时判定冲突', () => {
    const first = makeMatch({ matchId: 'a', accountId: '1001', startAt: 100000, endAt: 280000 });
    const second = makeMatch({ matchId: 'b', accountId: '1002', startAt: 200000, endAt: 380000 });
    const intervals = new Map<string, KnownInterval>([['1001:a', { accountId: '1001', startAt: 100000, endAt: 280000 }]]);
    expect(coreConflict(first, intervals)).toBeUndefined();
    expect(coreConflict(second, intervals)?.key).toBe('1001:a');
  });

  it('同一账户的对局不会被判为账户冲突', () => {
    const match = makeMatch({ matchId: 'b', accountId: '1001', startAt: 200000, endAt: 380000 });
    const intervals = new Map<string, KnownInterval>([['1001:a', { accountId: '1001', startAt: 100000, endAt: 280000 }]]);
    expect(coreConflict(match, intervals)).toBeUndefined();
  });

  it('只重叠前后留白时收窄裁剪区间', () => {
    const match = makeMatch({ matchId: 'b', accountId: '1002', startAt: 100000, endAt: 280000 });
    const intervals = new Map<string, KnownInterval>([
      ['1001:before', { accountId: '1001', startAt: 70000, endAt: 90000 }],
      ['1001:after', { accountId: '1001', startAt: 300000, endAt: 400000 }],
    ]);
    const clip = trimClip(clipRange(match), match, intervals);
    expect(clip).toEqual({ startAt: 90000, endAt: 300000 });
  });

  it('缓存区间按时间窗口清理', () => {
    const intervals = new Map<string, KnownInterval>();
    rememberInterval(intervals, makeMatch({ matchId: 'old', accountId: '1001', startAt: 0, endAt: 1000 }));
    rememberInterval(intervals, makeMatch({ matchId: 'new', accountId: '1002', startAt: 2000000, endAt: 2001000 }), 60000);
    expect([...intervals.keys()]).toEqual(['1002:new']);
  });
});

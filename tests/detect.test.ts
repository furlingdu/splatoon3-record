import { describe, expect, it } from 'vitest';
import { afterBaseline, coveredMatch, dedupeMatches, freshRecords, isNewMatch, mergeHandled, retryMatch } from '../src/main/match/detect.js';
import { makeMatch, makeRecord } from './helpers.js';

describe('isNewMatch', () => {
  it('按对局 ID 去重', () => {
    expect(isNewMatch(makeMatch({ matchId: 'a' }), [])).toBe(true);
    expect(isNewMatch(makeMatch({ matchId: 'a' }), ['a', 'b'])).toBe(false);
  });
});

describe('mergeHandled', () => {
  it('记录新对局并限制上限', () => {
    const ids = Array.from({ length: 200 }, (_, index) => `old-${index}`);
    const merged = mergeHandled(ids, 'new-one');
    expect(merged).toHaveLength(200);
    expect(merged.at(-1)).toBe('new-one');
    expect(merged).not.toContain('old-0');
  });

  it('重复 ID 不重复记录', () => {
    expect(mergeHandled(['a'], 'a')).toEqual(['a']);
  });
});

describe('dedupeMatches', () => {
  it('同时过滤已处理 ID 与重复项', () => {
    const matches = [{ matchId: 'a' }, { matchId: 'a' }, { matchId: 'b' }] as never[];
    expect(dedupeMatches(matches, ['b'])).toEqual([{ matchId: 'a' }]);
  });
});

describe('afterBaseline', () => {
  it('没有基准时视为新对局', () => {
    expect(afterBaseline(makeMatch({ endAt: 10 }))).toBe(true);
  });

  it('结束时间晚于基准才可处理', () => {
    expect(afterBaseline(makeMatch({ endAt: 11 }), 10)).toBe(true);
    expect(afterBaseline(makeMatch({ endAt: 10 }), 10)).toBe(false);
  });
});

describe('retryMatch', () => {
  it('最早所需分段仍在缓存窗口内时继续重试', () => {
    const now = 1700000000000;
    expect(retryMatch(makeMatch({ startAt: now - 599999 }), now)).toBe(true);
    expect(retryMatch(makeMatch({ startAt: now - 600001 }), now)).toBe(false);
  });
});

describe('freshRecords', () => {
  const now = 1700000000000;

  it('删除超过缓存时长的分段', () => {
    const records = [
      makeRecord({ filePath: 'old.mov', startAt: now - 700000, endAt: now - 660000 }),
      makeRecord({ filePath: 'new.mov', startAt: now - 300000, endAt: now - 270000 }),
    ];
    const { keep, drop } = freshRecords(records, now, 10);
    expect(keep.map((item) => item.filePath)).toEqual(['new.mov']);
    expect(drop.map((item) => item.filePath)).toEqual(['old.mov']);
  });

  it('10 分钟内的分段保留', () => {
    const records = [makeRecord({ filePath: 'edge.mov', startAt: now - 600000, endAt: now - 570000 })];
    expect(freshRecords(records, now, 10).keep).toHaveLength(1);
  });
});

describe('coveredMatch', () => {
  it('结束时间被分段覆盖时返回真', () => {
    const match = makeMatch({ startAt: 1000, endAt: 8000 });
    const records = [makeRecord({ filePath: 'a', startAt: 0, endAt: 10000 })];
    expect(coveredMatch(match, records)).toBe(true);
  });

  it('结束分段仍未完成时返回假', () => {
    const match = makeMatch({ startAt: 1000, endAt: 8000 });
    const records = [makeRecord({ filePath: 'a', startAt: 0, endAt: 7000 })];
    expect(coveredMatch(match, records)).toBe(false);
  });

  it('开始分段缺失时返回假', () => {
    const match = makeMatch({ startAt: 1000, endAt: 8000 });
    const records = [makeRecord({ filePath: 'a', startAt: 2000, endAt: 10000 })];
    expect(coveredMatch(match, records)).toBe(false);
  });

  it('分段中间存在空缺时返回假', () => {
    const match = makeMatch({ startAt: 1000, endAt: 8000 });
    const records = [
      makeRecord({ filePath: 'a', startAt: 0, endAt: 4000 }),
      makeRecord({ filePath: 'b', startAt: 5500, endAt: 10000 }),
    ];
    expect(coveredMatch(match, records)).toBe(false);
  });

  it('容忍自动换段的短暂内部交接间隙', () => {
    const match = makeMatch({ startAt: 1000, endAt: 8000 });
    const records = [
      makeRecord({ filePath: 'a', startAt: 0, endAt: 4000 }),
      makeRecord({ filePath: 'b', startAt: 4500, endAt: 10000 }),
    ];
    expect(coveredMatch(match, records)).toBe(true);
  });

  it('相邻分段完整覆盖时返回真', () => {
    const match = makeMatch({ startAt: 1000, endAt: 8000 });
    const records = [
      makeRecord({ filePath: 'a', startAt: 0, endAt: 4000 }),
      makeRecord({ filePath: 'b', startAt: 4000, endAt: 10000 }),
    ];
    expect(coveredMatch(match, records)).toBe(true);
  });
});

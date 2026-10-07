import { describe, expect, it } from 'vitest';
import { battleDelayMs, clipLeadMs, clipRange, clipTailMs, cropParts, matchClock, recordOverlap, utcText } from '../src/main/match/clock.js';
import { makeMatch, makeRecord } from './helpers.js';

describe('matchClock', () => {
  it('endAt - duration 得到 startAt，并后移到真实开战时刻', () => {
    const clock = matchClock(1700000000000, 180000);
    expect(clock.startAt).toBe(1700000000000 - 180000 + battleDelayMs);
    expect(clock.endAt).toBe(1700000000000 + battleDelayMs);
    expect(clock.duration).toBe(180000);
    expect(clock.endAt - clock.startAt).toBe(180000);
  });

  it('单局最多按 6 分钟处理', () => {
    const clock = matchClock(1700000000000, 900000);
    expect(clock.duration).toBe(360000);
    expect(clock.startAt).toBe(1700000000000 + battleDelayMs - 360000);
  });

  it('非法结束时间回退当前时间', () => {
    const clock = matchClock(Number.NaN, 60000);
    expect(Number.isFinite(clock.endAt)).toBe(true);
  });
});

describe('clipRange', () => {
  it('对局前后各留 15 秒与 30 秒', () => {
    const clip = clipRange({ startAt: 100000, endAt: 280000 });
    expect(clip.startAt).toBe(100000 - clipLeadMs);
    expect(clip.endAt).toBe(280000 + clipTailMs);
    expect(clip.endAt - clip.startAt).toBe(225000);
  });
});

describe('recordOverlap', () => {
  it('计算重叠区间与偏移', () => {
    const record = makeRecord({ filePath: 'a.mov', startAt: 1000, endAt: 61000 });
    const part = recordOverlap(record, 11000, 16000);
    expect(part?.record).toBe(record);
    expect(part?.offset).toBe(10);
    expect(part?.duration).toBe(5);
  });

  it('无重叠返回 undefined', () => {
    expect(recordOverlap(makeRecord({ filePath: 'a.mov', startAt: 1000, endAt: 6000 }), 10000, 20000)).toBeUndefined();
  });
});

describe('cropParts', () => {
  const records = [
    makeRecord({ filePath: 'one.mov', startAt: 0, endAt: 10000 }),
    makeRecord({ filePath: 'two.mov', startAt: 10000, endAt: 20000 }),
  ];

  it('按含前后留白的区间计算裁剪参数', () => {
    const clip = clipRange(makeMatch({ matchId: 'm', startAt: 6000, endAt: 16000 }));
    const parts = cropParts(records, clip);
    expect(parts.map((part) => ({ filePath: part.record.filePath, offset: part.offset, duration: part.duration }))).toEqual([
      { filePath: 'one.mov', offset: 0, duration: 10 },
      { filePath: 'two.mov', offset: 0, duration: 10 },
    ]);
  });

  it('完全未覆盖时分段为空', () => {
    expect(cropParts(records, { startAt: 60000, endAt: 70000 })).toEqual([]);
  });

  it('重叠分段按前一段结束处切分', () => {
    const overlapped = [
      makeRecord({ filePath: 'one.mov', startAt: 0, endAt: 31000 }),
      makeRecord({ filePath: 'two.mov', startAt: 30000, endAt: 61000 }),
    ];
    const parts = cropParts(overlapped, { startAt: 0, endAt: 61000 });
    expect(parts.map((part) => ({ filePath: part.record.filePath, offset: part.offset, duration: part.duration }))).toEqual([
      { filePath: 'one.mov', offset: 0, duration: 31 },
      { filePath: 'two.mov', offset: 1, duration: 30 },
    ]);
  });
});

describe('utcText', () => {
  it('输出 UTC ISO 文本', () => {
    expect(utcText(0)).toBe('1970-01-01T00:00:00.000Z');
  });
});

import { describe, expect, it } from 'vitest';
import { parseRange } from '../src/main/media/range.js';

describe('parseRange', () => {
  it('解析完整区间', () => {
    expect(parseRange('bytes=0-99', 100)).toEqual({ start: 0, end: 99 });
  });

  it('解析开放式区间', () => {
    expect(parseRange('bytes=50-', 100)).toEqual({ start: 50, end: 99 });
  });

  it('解析末尾后缀区间', () => {
    expect(parseRange('bytes=-20', 100)).toEqual({ start: 80, end: 99 });
  });

  it('超长结束位置收敛到文件末尾', () => {
    expect(parseRange('bytes=90-500', 100)).toEqual({ start: 90, end: 99 });
  });

  it('拒绝非法区间', () => {
    expect(parseRange('bytes=50-20', 100)).toBeUndefined();
    expect(parseRange('bytes=abc-', 100)).toBeUndefined();
    expect(parseRange('bytes=200-', 100)).toBeUndefined();
    expect(parseRange(null, 100)).toBeUndefined();
    expect(parseRange('bytes=0-', 0)).toBeUndefined();
  });
});

import { describe, expect, it } from 'vitest';
import { frameWall, seedOrigin } from '../src/renderer/lib/stamp.js';

describe('seedOrigin', () => {
  it('用首帧时间戳建立采集时间与系统时间的锚点', () => {
    expect(seedOrigin(undefined, 1000000, 5000000)).toBe(995000);
  });

  it('已有锚点时保持锚点不变', () => {
    expect(seedOrigin(995000, 2000000, 7000000)).toBe(995000);
  });

  it('没有帧时间戳时保留原值', () => {
    expect(seedOrigin(undefined, 1000000, undefined)).toBeUndefined();
    expect(seedOrigin(995000, 1000000, undefined)).toBe(995000);
  });
});

describe('frameWall', () => {
  it('把首帧时间戳换算成系统 UTC 毫秒', () => {
    expect(frameWall(995000, 6000000, 0)).toBe(1001000);
  });

  it('锚点或时间戳缺失时回退当前时间', () => {
    expect(frameWall(undefined, 6000000, 42)).toBe(42);
    expect(frameWall(995000, undefined, 42)).toBe(42);
  });
});

import { describe, expect, it } from 'vitest';
import { AudioGuard, audioLimits, audioTimestampValid } from '../src/renderer/lib/segment.js';

describe('AudioGuard', () => {
  it('有帧后超过阈值才判定停顿', () => {
    const guard = new AudioGuard();
    expect(guard.stalled(0)).toBe(false);
    guard.noteFrame(1000);
    expect(guard.stalled(1000 + audioLimits.stallMs - 1)).toBe(false);
    expect(guard.stalled(1000 + audioLimits.stallMs)).toBe(true);
  });

  it('60 秒窗口内允许 3 次恢复，第 4 次拒绝，窗口滑过后恢复', () => {
    const guard = new AudioGuard();
    expect(guard.spend(0)).toBe(true);
    expect(guard.spend(1000)).toBe(true);
    expect(guard.spend(2000)).toBe(true);
    expect(guard.health(3000).recoveries).toBe(3);
    expect(guard.spend(3000)).toBe(false);
    expect(guard.spend(audioLimits.recoveryWindowMs)).toBe(true);
    expect(guard.health(audioLimits.recoveryWindowMs).recoveries).toBe(4);
  });

  it('恢复尝试后有 2 秒冷却，避免连续切分', () => {
    const guard = new AudioGuard();
    expect(guard.spend(1000)).toBe(true);
    expect(guard.cooling(2000)).toBe(true);
    expect(guard.cooling(1000 + audioLimits.stallMs)).toBe(false);
  });

  it('统计帧率、最后帧年龄、回退与切分', () => {
    const guard = new AudioGuard();
    guard.noteFrame(1000);
    guard.noteFrame(1400);
    guard.rollback();
    guard.markCut();
    const health = guard.health(2000);
    expect(health.fps).toBe(1);
    expect(health.ageMs).toBe(600);
    expect(health.rollbacks).toBe(1);
    expect(health.recoveries).toBe(0);
    expect(health.cuts).toBe(1);
  });
});

describe('audioTimestampValid', () => {
  it('接受首个时间戳与单调递增时间戳', () => {
    expect(audioTimestampValid(undefined, 0)).toBe(true);
    expect(audioTimestampValid(1000, 1000)).toBe(true);
    expect(audioTimestampValid(1000, 2000)).toBe(true);
  });

  it('拒绝回退、负数与非有限值', () => {
    expect(audioTimestampValid(2000, 1000)).toBe(false);
    expect(audioTimestampValid(undefined, -1)).toBe(false);
    expect(audioTimestampValid(undefined, Number.NaN)).toBe(false);
    expect(audioTimestampValid(undefined, Number.POSITIVE_INFINITY)).toBe(false);
  });
});

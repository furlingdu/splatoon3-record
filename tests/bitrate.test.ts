import { describe, expect, it } from 'vitest';
import { pushBitrateDefault, pushTargetMb, qualityDefault, qualityTiers } from '../src/shared/constants.js';
import { budgetBps, clampQuality, estimateBytes, liveBitrateBps, pushCapBps, pushCodecLabel, pushSizeText, pushBitrate, recordFallbackBps } from '../src/shared/bitrate.js';

const limitBytes = pushTargetMb * 1024 * 1024;
const fiveMinutes = 300;

describe('clampQuality', () => {
  it('合法档位取最近的三档之一', () => {
    expect(clampQuality(18)).toBe(18);
    expect(clampQuality(22)).toBe(22);
    expect(clampQuality(28)).toBe(28);
    expect(clampQuality(20)).toBe(22);
    expect(clampQuality(25)).toBe(28);
    expect(clampQuality(19)).toBe(18);
  });

  it('非法值回退默认档', () => {
    expect(clampQuality(undefined)).toBe(qualityDefault);
    expect(clampQuality('abc')).toBe(qualityDefault);
    expect(clampQuality(NaN)).toBe(qualityDefault);
    expect(clampQuality(0)).toBe(18);
  });

  it('内置档位固定三档且默认 22', () => {
    expect(qualityTiers).toEqual([18, 22, 28]);
    expect(qualityDefault).toBe(22);
  });
});

describe('liveBitrateBps', () => {
  it('按采集画幅取恒定码率', () => {
    expect(liveBitrateBps(3840, 2160)).toBe(80000000);
    expect(liveBitrateBps(2560, 1440)).toBe(50000000);
    expect(liveBitrateBps(1920, 1080)).toBe(40000000);
    expect(liveBitrateBps(1280, 720)).toBe(20000000);
    expect(liveBitrateBps(960, 540)).toBe(12000000);
  });

  it('竖屏与异常尺寸按短边归一', () => {
    expect(liveBitrateBps(1080, 1920)).toBe(40000000);
    expect(liveBitrateBps(0, 0)).toBe(12000000);
  });
});

describe('recordFallbackBps', () => {
  it('无量化档支持时的兜底码率为直播码率的两倍', () => {
    expect(recordFallbackBps(1920, 1080)).toBe(80000000);
    expect(recordFallbackBps(1280, 720)).toBe(40000000);
  });
});

describe('pushCapBps', () => {
  it('允许小数上限', () => {
    expect(pushCapBps(1)).toBe(1000000);
    expect(pushCapBps(0.5)).toBe(500000);
    expect(pushCapBps(0.25)).toBe(250000);
  });

  it('非法值回退默认上限', () => {
    expect(pushCapBps(0)).toBe(pushBitrateDefault * 1000000);
    expect(pushCapBps(Number.NaN)).toBe(pushBitrateDefault * 1000000);
  });
});

describe('pushBitrate', () => {
  it('上限高于目标体积预算时按预算出码并落在目标体积内', () => {
    const used = pushBitrate(5, fiveMinutes * 1000);
    expect(used).toBe(budgetBps(fiveMinutes * 1000));
    expect(used).toBeLessThan(5000000);
    expect(estimateBytes(used, fiveMinutes, 96000)).toBeLessThan(limitBytes);
  });

  it('交付文件含前后留白，长对局改用目标体积预算', () => {
    const used = pushBitrate(5, 345 * 1000);
    expect(used).toBe(2213906);
    expect(used).toBeLessThan(5000000);
    expect(estimateBytes(used, 345, 96000)).toBeLessThan(limitBytes);
  });

  it('时长越长码率越低，长对局压到预算内', () => {
    const short = pushBitrate(3, 60 * 1000);
    const long = pushBitrate(3, 600 * 1000);
    expect(short).toBe(3000000);
    expect(long).toBe(budgetBps(600 * 1000));
    expect(long).toBeLessThan(short);
  });

  it('上限低于预算时以上限为准', () => {
    const used = pushBitrate(0.5, 60 * 1000);
    expect(used).toBe(500000);
  });

  it('预算低于下限时保底不低于 200 kbps', () => {
    const long = pushBitrate(3, 3600 * 1000);
    expect(long).toBe(200000);
  });
});

describe('pushSizeText', () => {
  it('按目标体积估算压制版体积', () => {
    expect(pushSizeText(3, fiveMinutes)).toBe('5 分钟对局约 95 MB');
    expect(pushSizeText(1, fiveMinutes)).toBe('5 分钟对局约 39 MB');
  });

  it('短对局由上限决定体积，长对局由目标体积决定', () => {
    expect(pushSizeText(3, 60)).toBe('1 分钟对局约 22 MB');
    expect(pushSizeText(1, 60)).toBe('1 分钟对局约 8 MB');
    expect(pushSizeText(3, fiveMinutes, 20)).toBe('5 分钟对局约 19 MB');
  });
});

describe('pushCodecLabel', () => {
  it('只输出编解码器名称', () => {
    expect(pushCodecLabel('hevc')).toBe('HEVC');
    expect(pushCodecLabel('h264')).toBe('H.264');
    expect(pushCodecLabel('av1')).toBe('AV1');
  });
});

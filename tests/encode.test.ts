import { describe, expect, it } from 'vitest';
import { avcCodec, hardwareReady, hardwareTiers, hevcCodec, tierList, videoCodecs } from '../src/renderer/lib/encode.js';

describe('hevcCodec', () => {
  it('按画幅帧率取足够的最低等级', () => {
    expect(hevcCodec(1280, 720, 30)).toBe('hvc1.1.6.L150.B0');
    expect(hevcCodec(1920, 1080, 60)).toBe('hvc1.1.6.L153.B0');
    expect(hevcCodec(2560, 1440, 60)).toBe('hvc1.1.6.L153.B0');
    expect(hevcCodec(3840, 2160, 30)).toBe('hvc1.1.6.L153.B0');
    expect(hevcCodec(3840, 2160, 60)).toBe('hvc1.1.6.L156.B0');
  });
});

describe('avcCodec', () => {
  it('4K60 使用 5.2 等级', () => {
    expect(avcCodec(1280, 720, 30)).toBe('avc1.640028');
    expect(avcCodec(1920, 1080, 60)).toBe('avc1.64002A');
    expect(avcCodec(2560, 1440, 60)).toBe('avc1.640033');
    expect(avcCodec(3840, 2160, 30)).toBe('avc1.640033');
    expect(avcCodec(3840, 2160, 60)).toBe('avc1.640034');
  });
});

describe('tierList', () => {
  it('按负载降序且不超出采集卡上限', () => {
    const list = tierList({ id: 'a', name: 'a', kind: 'video', maxWidth: 1920, maxHeight: 1080, maxFps: 60 });
    expect(list[0]).toEqual({ width: 1920, height: 1080, fps: 60 });
    expect(list.every((item) => item.width <= 1920 && item.height <= 1080 && item.fps <= 60)).toBe(true);
  });

  it('并入当前档位且不重复', () => {
    const list = tierList(undefined, { width: 3440, height: 1440, fps: 60 });
    expect(list.some((item) => item.width === 3440 && item.height === 1440 && item.fps === 60)).toBe(true);
    expect(list.filter((item) => item.width === 3440).length).toBe(1);
  });
});

describe('hardwareReady', () => {
  it('探测硬件编码时不下发 framerate', async () => {
    const configs: VideoEncoderConfig[] = [];
    const stub = {
      isConfigSupported: async (config: VideoEncoderConfig) => {
        configs.push(config);
        return { supported: true, config };
      },
    };
    const host = globalThis as { VideoEncoder?: unknown };
    host.VideoEncoder = stub;
    try {
      expect(await hardwareReady(3840, 2160, 60)).toBe(true);
    } finally {
      delete host.VideoEncoder;
    }
    expect(configs.length).toBeGreaterThan(0);
    expect(configs.every((config) => config.framerate === undefined)).toBe(true);
    expect(configs[0]?.hardwareAcceleration).toBe('prefer-hardware');
    expect(configs[0]?.codec).toBe('hvc1.1.6.L156.B0');
  });

  it('没有 WebCodecs 时判定为无硬件编码', async () => {
    const device = { id: 'a', name: 'a', kind: 'video' as const, maxWidth: 1920, maxHeight: 1080, maxFps: 30 };
    expect(await hardwareReady(1920, 1080, 30)).toBe(false);
    expect(await hardwareTiers(device)).toEqual([]);
  });
});

describe('videoCodecs', () => {
  it('列表按硬件候选顺序包含 HEVC 与 H.264', () => {
    const list = videoCodecs(3840, 2160, 60);
    expect(list[0]).toEqual({ codec: 'hvc1.1.6.L156.B0', muxer: 'hevc' });
    expect(list[1]).toEqual({ codec: 'hev1.1.6.L156.B0', muxer: 'hevc' });
    expect(list.some((item) => item.codec === 'avc1.640034')).toBe(true);
    expect(list.some((item) => item.codec === 'avc1.640028')).toBe(true);
  });
});

import { describe, expect, it } from 'vitest';
import { avcCodec, hevcCodec, videoCandidates } from '../src/renderer/lib/segment.js';

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

describe('videoCandidates', () => {
  it('列表按硬件候选顺序包含 HEVC 与 H.264', () => {
    const list = videoCandidates({ width: 3840, height: 2160, fps: 60, hasAudio: true });
    expect(list[0]).toEqual({ codec: 'hvc1.1.6.L156.B0', muxer: 'hevc' });
    expect(list[1]).toEqual({ codec: 'hev1.1.6.L156.B0', muxer: 'hevc' });
    expect(list.some((item) => item.codec === 'avc1.640034')).toBe(true);
    expect(list.some((item) => item.codec === 'avc1.640028')).toBe(true);
  });
});

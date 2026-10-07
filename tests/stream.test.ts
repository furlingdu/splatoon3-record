import { afterEach, describe, expect, it, vi } from 'vitest';
import { closeStream, openStream, splitDue, streamCodec } from '../src/renderer/lib/stream.js';

describe('splitDue', () => {
  it('按到点时间拆出可发送的数据', () => {
    const split = splitDue([{ due: 100 }, { due: 300 }, { due: 200 }], 200);
    expect(split.ready.map((item) => item.due)).toEqual([100, 200]);
    expect(split.rest.map((item) => item.due)).toEqual([300]);
  });

  it('全部到点时一次清空', () => {
    const split = splitDue([{ due: 10 }, { due: 20 }], 50);
    expect(split.ready).toHaveLength(2);
    expect(split.rest).toHaveLength(0);
  });

  it('都未到点时保持队列', () => {
    const split = splitDue([{ due: 500 }], 100);
    expect(split.ready).toHaveLength(0);
    expect(split.rest).toHaveLength(1);
  });
});

afterEach(() => {
  closeStream();
  vi.unstubAllGlobals();
});

describe('openStream codec selection', () => {
  const options = { canvas: {} as HTMLCanvasElement, width: 1920, height: 1080, fps: 60, bitrate: 40000000, onError: vi.fn() };

  function mockCodecs(decodable: (codec: string) => boolean, encodable: (codec: string) => boolean, fail?: (codec: string) => boolean): { configured: VideoEncoderConfig[]; closed: string[] } {
    const configured: VideoEncoderConfig[] = [];
    const closed: string[] = [];
    class MockEncoder {
      static isConfigSupported = vi.fn(async (config: VideoEncoderConfig) => ({ supported: encodable(config.codec) }));
      state = 'configured';
      encodeQueueSize = 0;
      config?: VideoEncoderConfig;
      configure(config: VideoEncoderConfig): void {
        this.config = config;
        if (fail?.(config.codec)) throw new Error('configure failed');
        configured.push(config);
      }
      close(): void { closed.push(this.config?.codec ?? ''); }
    }
    class MockDecoder {
      static isConfigSupported = vi.fn(async (config: VideoDecoderConfig) => ({ supported: decodable(config.codec) }));
    }
    vi.stubGlobal('VideoEncoder', MockEncoder);
    vi.stubGlobal('VideoDecoder', MockDecoder);
    return { configured, closed };
  }

  it('skips encodable HEVC when the viewer cannot decode it', async () => {
    const codecs = mockCodecs((codec) => codec.startsWith('avc1'), () => true);
    await openStream(options);
    expect(codecs.configured[0].codec).toBe('avc1.64002A');
    expect(streamCodec()).toContain('avc1.64002A');
    expect(VideoEncoder.isConfigSupported).not.toHaveBeenCalledWith(expect.objectContaining({ codec: 'hvc1.1.6.L150.B0' }));
  });

  it('prefers decodable HEVC and falls back when its encoder cannot configure', async () => {
    const codecs = mockCodecs(() => true, () => true, (codec) => codec.startsWith('hvc1') || codec.startsWith('hev1'));
    await openStream(options);
    expect(codecs.closed).toContain('hvc1.1.6.L150.B0');
    expect(codecs.configured[0].codec).toBe('avc1.64002A');
  });

  it('uses HEVC when both encoder and decoder support it', async () => {
    const codecs = mockCodecs(() => true, () => true);
    await openStream(options);
    expect(codecs.configured[0]).toMatchObject({ codec: 'hvc1.1.6.L150.B0', hardwareAcceleration: 'prefer-hardware', bitrateMode: 'constant' });
  });

  it('reports unavailable when there is no mutually supported codec', async () => {
    mockCodecs(() => false, () => true);
    await expect(openStream(options)).rejects.toThrow('没有可用的直播编码器');
  });
});

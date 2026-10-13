import { fpsOptions } from '../../shared/capture.js';
import type { CaptureFormat, CaptureMode } from '../../shared/types.js';

export interface CodecChoice {
  codec: string;
  muxer: 'avc' | 'hevc';
}

export interface ModeRate {
  format: CaptureFormat;
  width: number;
  height: number;
  fps: number;
}

const hevcLevels = [
  { name: 'L150', rate: 89128960 },
  { name: 'L153', rate: 267386880 },
  { name: 'L156', rate: 534773760 },
  { name: 'L159', rate: 1069547520 },
];
const avcLevels = [
  { codec: 'avc1.640028', mbps: 245760 },
  { codec: 'avc1.64002A', mbps: 522240 },
  { codec: 'avc1.640032', mbps: 589824 },
  { codec: 'avc1.640033', mbps: 983040 },
  { codec: 'avc1.640034', mbps: 2073600 },
];
const readyCache = new Map<string, boolean>();

// 按画幅与帧率取能装下码流的最低等级，避免 4K60 用 5.0、5.1 挡掉硬件编码
export function hevcCodec(width: number, height: number, fps: number): string {
  const rate = Math.max(1, Math.round(width)) * Math.max(1, Math.round(height)) * Math.max(1, Math.round(fps));
  const tier = hevcLevels.find((item) => rate <= item.rate) ?? hevcLevels[hevcLevels.length - 1];
  return `hvc1.1.6.${tier.name}.B0`;
}

export function avcCodec(width: number, height: number, fps: number): string {
  const blocks = Math.ceil(Math.max(1, Math.round(width)) / 16) * Math.ceil(Math.max(1, Math.round(height)) / 16);
  const mbps = blocks * Math.max(1, Math.round(fps));
  return (avcLevels.find((item) => mbps <= item.mbps) ?? avcLevels[avcLevels.length - 1]).codec;
}

export function videoCodecs(width: number, height: number, fps: number): CodecChoice[] {
  const hevc = hevcCodec(width, height, fps);
  const list: CodecChoice[] = [
    { codec: hevc, muxer: 'hevc' },
    { codec: hevc.replace(/^hvc1/, 'hev1'), muxer: 'hevc' },
    { codec: avcCodec(width, height, fps), muxer: 'avc' },
  ];
  for (const codec of ['avc1.640033', 'avc1.640028']) {
    if (!list.some((item) => item.codec === codec)) list.push({ codec, muxer: 'avc' });
  }
  return list;
}

// 探测本机浏览器是否为该档位提供硬件编码，用于状态页与设备报告提示
export async function hardwareReady(width: number, height: number, fps: number): Promise<boolean> {
  if (typeof VideoEncoder === 'undefined' || width < 2 || height < 2) return false;
  const key = `${width}x${height}@${fps}`;
  const cached = readyCache.get(key);
  if (cached !== undefined) return cached;
  let ready = false;
  for (const item of videoCodecs(width, height, fps)) {
    for (const bitrateMode of ['quantizer', 'variable'] as VideoEncoderBitrateMode[]) {
      const config: VideoEncoderConfig = {
        codec: item.codec,
        width,
        height,
        framerate: Math.max(1, Math.round(fps)),
        latencyMode: 'quality',
        bitrateMode,
        hardwareAcceleration: 'prefer-hardware',
      };
      if (bitrateMode === 'quantizer') config.quantizer = 22;
      else config.bitrate = 8000000;
      if (item.muxer === 'avc') config.avc = { format: 'avc' };
      const support = await VideoEncoder.isConfigSupported(config).catch(() => undefined);
      if (support?.supported) {
        ready = true;
        break;
      }
    }
    if (ready) break;
  }
  readyCache.set(key, ready);
  return ready;
}

// 从采集卡档位里逐个探测硬编可用性，返回按负载从高到低的档位列表
export async function hardwareModes(modes: CaptureMode[], limit = 12): Promise<ModeRate[]> {
  const groups = new Map<string, { format: CaptureFormat; width: number; height: number; rates: number[] }>();
  for (const mode of modes) {
    const rates = [...fpsOptions, mode.minFps, mode.maxFps].map((item) => Math.round(item)).filter((item) => item >= mode.minFps && item <= mode.maxFps);
    const key = `${mode.format}:${mode.width}x${mode.height}`;
    const group = groups.get(key) ?? { format: mode.format, width: mode.width, height: mode.height, rates: [] };
    for (const fps of rates) if (fps > 0 && !group.rates.includes(fps)) group.rates.push(fps);
    groups.set(key, group);
  }
  const list = [...groups.values()].map((group) => ({ ...group, rates: group.rates.sort((left, right) => right - left) }));
  list.sort((left, right) => right.width * right.height - left.width * left.height);
  const ready: ModeRate[] = [];
  for (const group of list.slice(0, limit)) {
    for (const fps of group.rates) {
      if (await hardwareReady(group.width, group.height, fps)) {
        ready.push({ format: group.format, width: group.width, height: group.height, fps });
        break;
      }
    }
  }
  return ready;
}

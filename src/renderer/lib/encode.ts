import { fpsOptions, resolutionPresets } from '../../shared/capture.js';
import type { CaptureDevice } from '../../shared/types.js';

export interface CodecChoice {
  codec: string;
  muxer: 'avc' | 'hevc';
}

export interface ModeRate {
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

export function tierList(device?: CaptureDevice, current?: ModeRate): ModeRate[] {
  const list: ModeRate[] = [];
  const push = (item: ModeRate): void => {
    if (item.width < 2 || item.height < 2 || item.fps < 1) return;
    if (list.some((hit) => hit.width === item.width && hit.height === item.height && hit.fps === item.fps)) return;
    list.push(item);
  };
  if (current) push(current);
  for (const preset of resolutionPresets) {
    if (device?.maxWidth && preset.width > device.maxWidth) continue;
    if (device?.maxHeight && preset.height > device.maxHeight) continue;
    for (const fps of fpsOptions) {
      if (device?.maxFps && fps > device.maxFps) continue;
      push({ width: preset.width, height: preset.height, fps });
    }
  }
  return list.sort((left, right) => right.width * right.height * right.fps - left.width * left.height * left.fps);
}

export async function hardwareTiers(device?: CaptureDevice, current?: ModeRate, limit = 12): Promise<ModeRate[]> {
  const ready: ModeRate[] = [];
  for (const item of tierList(device, current).slice(0, limit)) {
    if (await hardwareReady(item.width, item.height, item.fps)) ready.push(item);
  }
  return ready;
}

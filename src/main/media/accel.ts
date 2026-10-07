import { existsSync } from 'node:fs';
import { join } from 'node:path';
import { runCommand, runFFmpeg } from './ffmpeg.js';
import { tempPath } from '../store/path.js';
import { logApp } from '../store/log.js';
import type { PushCodec, RecordSettings } from '../../shared/types.js';

export interface AccelRung {
  decode?: string;
  encode: string;
  decodeArgs: string[];
  encodeArgs: string[];
  label: string;
}

const decodeOrder = ['cuda', 'd3d11va', 'd3d12va', 'dxva2', 'qsv', 'amf', 'vulkan', 'videotoolbox'];
const probeInput = 'color=black:s=256x144:r=30:d=0.2';
const decodeProbeFile = join(tempPath, 'decodeprobe.mp4');

export type EncodeCodec = 'h264' | 'hevc' | PushCodec;

const softwareEncodes: Record<EncodeCodec, string> = { h264: 'libx264', hevc: 'libx265', av1: 'libaom-av1' };

const hardwareEncodes: Record<EncodeCodec, Record<RecordSettings['encoder'], string[]>> = {
  h264: {
    auto: ['h264_nvenc', 'h264_amf', 'h264_qsv', 'h264_videotoolbox', 'h264_vulkan'],
    nvidia: ['h264_nvenc'],
    amd: ['h264_amf'],
    intel: ['h264_qsv'],
    software: [],
  },
  hevc: {
    auto: ['hevc_nvenc', 'hevc_amf', 'hevc_qsv', 'hevc_videotoolbox', 'hevc_vulkan'],
    nvidia: ['hevc_nvenc'],
    amd: ['hevc_amf'],
    intel: ['hevc_qsv'],
    software: [],
  },
  av1: {
    auto: ['av1_nvenc', 'av1_amf', 'av1_qsv', 'av1_vulkan'],
    nvidia: ['av1_nvenc'],
    amd: ['av1_amf'],
    intel: ['av1_qsv'],
    software: [],
  },
};

const decodeNames: Record<string, string> = {
  vulkan: 'Vulkan',
  d3d12va: 'D3D12',
  d3d11va: 'D3D11',
  dxva2: 'DXVA2',
  cuda: 'CUDA',
  qsv: 'QSV',
  amf: 'AMF',
  videotoolbox: 'VideoToolbox',
};

const hwUploads: Record<string, string[]> = {
  h264_vulkan: ['-init_hw_device', 'vulkan=vk', '-filter_hw_device', 'vk'],
  hevc_vulkan: ['-init_hw_device', 'vulkan=vk', '-filter_hw_device', 'vk'],
  av1_vulkan: ['-init_hw_device', 'vulkan=vk', '-filter_hw_device', 'vk'],
};

export type RateMode = { kind: 'quality'; quality: number } | { kind: 'rate'; bitrate: number };

interface ProbeCaps {
  decodes: string[];
  encodes: string[];
}

let ladder: AccelRung[] = [];
let activeIndex = 0;
let decodeCaps: string[] | undefined;
const probes = new Map<string, ProbeCaps>();

export function uploadArgs(encode: string): string[] {
  return hwUploads[encode] ?? [];
}

export function uploadFilter(encode: string): string {
  return hwUploads[encode] ? 'format=nv12,hwupload' : '';
}

export function rateArgs(encode: string, bitrate: number): string[] {
  const rate = String(Math.max(100000, Math.round(bitrate)));
  const buffer = String(Math.max(200000, Math.round(bitrate) * 2));
  if (encode === 'h264_nvenc') return ['-preset', 'p5', '-rc', 'vbr', '-b:v', rate, '-maxrate', rate, '-bufsize', buffer, '-profile:v', 'high'];
  if (encode === 'hevc_nvenc') return ['-preset', 'p5', '-rc', 'vbr', '-b:v', rate, '-maxrate', rate, '-bufsize', buffer, '-profile:v', 'main'];
  if (encode === 'h264_amf') return ['-quality', 'quality', '-rc', 'vbr_latency', '-b:v', rate, '-maxrate', rate, '-bufsize', buffer];
  if (encode === 'hevc_amf') return ['-quality', 'quality', '-rc', 'vbr_latency', '-b:v', rate, '-maxrate', rate, '-bufsize', buffer];
  if (encode === 'h264_qsv') return ['-preset', 'medium', '-b:v', rate, '-maxrate', rate, '-bufsize', buffer];
  if (encode === 'hevc_qsv') return ['-preset', 'medium', '-b:v', rate, '-maxrate', rate, '-bufsize', buffer];
  if (encode === 'h264_videotoolbox' || encode === 'hevc_videotoolbox') return ['-b:v', rate, '-maxrate', rate, '-bufsize', buffer];
  if (encode === 'h264_vulkan') return ['-rc_mode', 'vbr', '-b:v', rate, '-maxrate', rate, '-bufsize', buffer];
  if (encode === 'hevc_vulkan') return ['-rc_mode', 'vbr', '-b:v', rate, '-maxrate', rate, '-bufsize', buffer];
  if (encode === 'libx264') return ['-preset', 'veryfast', '-b:v', rate, '-maxrate', rate, '-bufsize', buffer, '-profile:v', 'high'];
  if (encode === 'libx265') return ['-preset', 'veryfast', '-b:v', rate, '-maxrate', rate, '-bufsize', buffer];
  if (encode === 'av1_nvenc') return ['-preset', 'p5', '-rc', 'vbr', '-b:v', rate, '-maxrate', rate, '-bufsize', buffer];
  if (encode === 'av1_amf') return ['-quality', 'quality', '-rc', 'vbr_latency', '-b:v', rate, '-maxrate', rate, '-bufsize', buffer];
  if (encode === 'av1_qsv') return ['-preset', 'medium', '-b:v', rate, '-maxrate', rate, '-bufsize', buffer];
  if (encode === 'libaom-av1') return ['-usage', 'realtime', '-cpu-used', '8', '-row-mt', '1', '-b:v', rate, '-maxrate', rate, '-bufsize', buffer];
  return ['-b:v', rate, '-maxrate', rate, '-bufsize', buffer];
}

export function qualityArgs(encode: string, quality: number): string[] {
  const level = Math.max(0, Math.round(quality));
  const q = String(level);
  if (encode === 'h264_nvenc') return ['-preset', 'p5', '-rc', 'constqp', '-qp', q, '-profile:v', 'high'];
  if (encode === 'hevc_nvenc') return ['-preset', 'p5', '-rc', 'constqp', '-qp', q, '-profile:v', 'main'];
  if (encode === 'av1_nvenc') return ['-preset', 'p5', '-rc', 'constqp', '-qp', q];
  if (encode === 'h264_amf' || encode === 'hevc_amf' || encode === 'av1_amf') return ['-quality', 'quality', '-rc', 'cqp', '-qp_i', q, '-qp_p', q, '-qp_b', q];
  if (encode === 'h264_qsv' || encode === 'hevc_qsv' || encode === 'av1_qsv') return ['-preset', 'medium', '-global_quality', q];
  if (encode === 'h264_videotoolbox' || encode === 'hevc_videotoolbox') return ['-q:v', String(Math.min(100, Math.max(1, Math.round(80 - (level - 18) * 3.5))))];
  if (encode === 'h264_vulkan' || encode === 'hevc_vulkan' || encode === 'av1_vulkan') return ['-rc_mode', 'cqp', '-qp', q];
  if (encode === 'libx264') return ['-preset', 'veryfast', '-crf', q, '-profile:v', 'high'];
  if (encode === 'libx265') return ['-preset', 'veryfast', '-crf', q];
  if (encode === 'libaom-av1') return ['-crf', q, '-b:v', '0', '-cpu-used', '8', '-row-mt', '1'];
  return ['-crf', q];
}

export function buildLadder(decodes: string[], encodes: string[], mode: RateMode, codec: EncodeCodec = 'hevc'): AccelRung[] {
  const software = softwareEncodes[codec];
  const hwList = encodes.filter((name) => !uploadArgs(name).length);
  const vkList = encodes.filter((name) => uploadArgs(name).length);
  const rungs: AccelRung[] = [];
  const makeRung = (decode?: string, encode: string = software): AccelRung => ({
    decode,
    encode,
    decodeArgs: decode ? ['-hwaccel', decode] : [],
    encodeArgs: ['-c:v', encode, ...(mode.kind === 'quality' ? qualityArgs(encode, mode.quality) : rateArgs(encode, mode.bitrate)), ...uploadArgs(encode)],
    label: decode ? `${decodeNames[decode] || decode.toUpperCase()} + ${encode}` : `软件解码 + ${encode}`,
  });
  for (const decode of decodes) {
    for (const encode of hwList) rungs.push(makeRung(decode, encode));
  }
  for (const encode of hwList) rungs.push(makeRung(undefined, encode));
  for (const encode of vkList) rungs.push(makeRung(undefined, encode));
  for (const decode of decodes) rungs.push(makeRung(decode, software));
  rungs.push(makeRung(undefined, software));
  return rungs;
}

async function probeDecodes(): Promise<string[]> {
  const result = await runCommand(['-hide_banner', '-hwaccels']);
  const listed = new Set(result.output.split(/\r?\n/).map((line) => line.trim().toLowerCase()));
  const names = decodeOrder.filter((name) => listed.has(name));
  const input = await decodeProbeInput();
  if (!input) return names;
  const working: string[] = [];
  for (const name of names) {
    const probe = await runCommand(['-hide_banner', '-v', 'error', '-y', '-hwaccel', name, '-i', input, '-frames:v', '1', '-f', 'null', '-'], 20000);
    if (probe.code === 0) working.push(name);
  }
  return working.length ? working : names;
}

async function decodeProbeInput(): Promise<string | undefined> {
  if (existsSync(decodeProbeFile)) return decodeProbeFile;
  const ok = await runFFmpeg(['-hide_banner', '-v', 'error', '-y', '-f', 'lavfi', '-i', 'testsrc2=size=320x180:rate=15:d=1', '-c:v', 'libx264', '-preset', 'ultrafast', '-pix_fmt', 'yuv420p', decodeProbeFile]).then(() => true).catch(() => false);
  return ok ? decodeProbeFile : undefined;
}

export async function probeEncode(candidates: string[], mode: RateMode): Promise<string | undefined> {
  for (const name of candidates) {
    const filter = uploadFilter(name);
    const result = await runCommand(['-hide_banner', '-y', '-f', 'lavfi', '-i', probeInput, '-frames:v', '1', ...(filter ? ['-vf', filter] : []), '-c:v', name, ...(mode.kind === 'quality' ? qualityArgs(name, mode.quality) : rateArgs(name, mode.bitrate)), ...uploadArgs(name), '-f', 'null', '-'], 30000);
    if (result.code === 0) return name;
  }
  return undefined;
}

async function probeCaps(encoder: RecordSettings['encoder'], mode: RateMode, codec: EncodeCodec): Promise<ProbeCaps> {
  const key = `${encoder}|${codec}|${mode.kind}`;
  const cached = probes.get(key);
  if (cached) return cached;
  if (!decodeCaps) decodeCaps = await probeDecodes();
  const wanted = hardwareEncodes[codec][encoder] ?? hardwareEncodes[codec].auto;
  const ready = wanted.length ? await probeEncode(wanted, mode) : undefined;
  const caps: ProbeCaps = { decodes: decodeCaps, encodes: ready ? [ready, ...wanted.filter((name) => name !== ready)] : wanted };
  probes.set(key, caps);
  return caps;
}

export async function ladderRungs(encoder: RecordSettings['encoder'], mode: RateMode, codec: EncodeCodec = 'hevc'): Promise<AccelRung[]> {
  const caps = await probeCaps(encoder, mode, codec);
  return buildLadder(caps.decodes, caps.encodes, mode, codec);
}

export async function runLadder<T>(encoder: RecordSettings['encoder'], mode: RateMode, codec: EncodeCodec, job: (rung: AccelRung) => Promise<T | undefined>): Promise<T | undefined> {
  const rungs = await ladderRungs(encoder, mode, codec);
  for (const rung of rungs) {
    try {
      const done = await job(rung);
      if (done !== undefined) {
        setActive(rung);
        return done;
      }
      logApp(`编码档位失败 ${rung.label}`);
    } catch (cause) {
      logApp(`编码档位失败 ${rung.label} ${errorText(cause)}`);
    }
  }
  return undefined;
}

function setActive(rung: AccelRung): void {
  const key = `${rung.decode ?? ''}|${rung.encode}`;
  const index = ladder.findIndex((item) => `${item.decode ?? ''}|${item.encode}` === key);
  if (index >= 0) activeIndex = index;
  else {
    ladder = [rung];
    activeIndex = 0;
  }
}

function errorText(cause: unknown): string {
  return cause instanceof Error ? cause.message : String(cause ?? '');
}

export async function prepareAccel(encoder: RecordSettings['encoder'], mode: RateMode, codec: EncodeCodec = 'hevc'): Promise<AccelRung[]> {
  const current = ladder[activeIndex];
  const key = current ? `${current.decode ?? ''}|${current.encode}` : '';
  ladder = await ladderRungs(encoder, mode, codec);
  const kept = key ? ladder.findIndex((rung) => `${rung.decode ?? ''}|${rung.encode}` === key) : -1;
  activeIndex = kept >= 0 ? kept : 0;
  return ladder;
}

export function accelRungs(): AccelRung[] {
  return ladder;
}

export function accelActive(): AccelRung | undefined {
  return ladder[activeIndex];
}

export function accelFallback(): AccelRung | undefined {
  activeIndex = Math.min(activeIndex + 1, Math.max(0, ladder.length - 1));
  return accelActive();
}

export function accelSummary(): { hwAccel?: string; encoder?: string } {
  const rung = accelActive();
  if (!rung) return {};
  return { hwAccel: rung.decode ? decodeNames[rung.decode] || rung.decode.toUpperCase() : '软件', encoder: rung.encode };
}

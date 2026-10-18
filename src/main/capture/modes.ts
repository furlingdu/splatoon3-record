import { runCommand } from '../media/ffmpeg.js';
import type { CaptureFormat, CaptureMode } from '../../shared/types.js';

const modesCache = new Map<string, CaptureMode[]>();
const listTimeoutMs = 12000;

export async function listModes(device: string): Promise<CaptureMode[]> {
  if (process.platform !== 'win32') return [];
  const name = device.trim();
  if (!name) return [];
  const cached = modesCache.get(name);
  if (cached) return cached;
  const result = await runCommand(['-hide_banner', '-list_options', 'true', '-f', 'dshow', '-i', `video=${name}`], listTimeoutMs);
  const modes = parseModes(result.output);
  if (modes.length) modesCache.set(name, modes);
  return modes;
}

export function parseModes(output: string): CaptureMode[] {
  const list: CaptureMode[] = [];
  const seen = new Set<string>();
  for (const line of output.split(/\r?\n/)) {
    const match = line.match(/pixel_format=(\S+)\s+min s=(\d+)x(\d+) fps=([\d.]+)\s+max s=(\d+)x(\d+) fps=([\d.]+)/);
    if (!match) continue;
    const format = normalizeFormat(match[1]);
    if (!format) continue;
    const width = Number(match[2]);
    const height = Number(match[3]);
    const first = Math.round(Number(match[4]));
    const second = Math.round(Number(match[7]));
    if (!width || !height || !first || !second) continue;
    const minFps = Math.min(first, second);
    const maxFps = Math.max(first, second);
    const key = `${format}:${width}x${height}:${minFps}-${maxFps}`;
    if (seen.has(key)) continue;
    seen.add(key);
    list.push({ format, width, height, minFps, maxFps });
  }
  return list;
}

function normalizeFormat(value: string): CaptureFormat | undefined {
  const text = value.toLowerCase();
  if (text.includes('nv12')) return 'nv12';
  if (text.includes('yuy2') || text.includes('yuyv')) return 'yuy2';
  return undefined;
}

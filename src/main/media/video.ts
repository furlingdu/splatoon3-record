import { runCommand } from './ffmpeg.js';

const audioProbeTimeoutMs = 5000;

export async function probeAudio(filePath: string): Promise<boolean> {
  const result = await runCommand([
    '-hide_banner',
    '-v',
    'error',
    '-i',
    filePath,
    '-map',
    '0:a:0',
    '-frames:a',
    '1',
    '-c:a',
    'copy',
    '-f',
    'null',
    '-',
  ], audioProbeTimeoutMs);
  if (result.code === 0) return true;
  if (/stream map .*matches no streams/i.test(result.output)) return false;
  throw new Error(result.code === -1 ? '音轨探测失败或超时' : '无法读取分段音轨');
}

export function makeVideoUrl(matchKey: string): string {
  return `s3r-video://match/${encodeURIComponent(matchKey)}`;
}

export function parseVideoUrl(url: string): string | undefined {
  try {
    const parsed = new URL(url);
    if (parsed.protocol !== 's3r-video:' || parsed.hostname !== 'match' || parsed.search || parsed.hash) return undefined;
    const matchId = decodeURIComponent(parsed.pathname.slice(1));
    return /^[a-zA-Z0-9_:=+.-]+$/.test(matchId) ? matchId : undefined;
  } catch {
    return undefined;
  }
}

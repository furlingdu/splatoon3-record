import { runCommand } from './ffmpeg.js';

export async function probeAudio(filePath: string): Promise<boolean> {
  const result = await runCommand(['-hide_banner', '-v', 'error', '-i', filePath, '-map', '0:a:0', '-f', 'null', '-']);
  return result.code === 0;
}

export function makeVideoUrl(matchId: string): string {
  return `s3r-video://match/${encodeURIComponent(matchId)}`;
}

export function parseVideoUrl(url: string): string | undefined {
  try {
    const parsed = new URL(url);
    if (parsed.protocol !== 's3r-video:' || parsed.hostname !== 'match' || parsed.search || parsed.hash) return undefined;
    const matchId = decodeURIComponent(parsed.pathname.slice(1));
    return /^[a-zA-Z0-9_-]+[=+]{0,2}$/.test(matchId) ? matchId : undefined;
  } catch {
    return undefined;
  }
}

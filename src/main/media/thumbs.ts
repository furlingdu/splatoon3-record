import { readFile, rm } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import { join } from 'node:path';
import { runFFmpeg } from './ffmpeg.js';
import { thumbPath } from '../store/path.js';
import { legacyName, safeName } from './file.js';
import type { BattleMatch } from '../../shared/types.js';

const cache = new Map<string, string>();
let queue: Promise<unknown> = Promise.resolve();

export async function getThumb(matches: BattleMatch[], matchId: string): Promise<string> {
  const cached = cache.get(matchId);
  if (cached !== undefined) return cached;
  const task = queue.then(() => buildThumb(matches, matchId));
  queue = task.catch(() => undefined);
  return task;
}

export function dropThumb(matchId: string): void {
  cache.delete(matchId);
  const names = new Set([safeName(matchId), legacyName(matchId)]);
  void Promise.all([...names].map((name) => rm(join(thumbPath, `${name}.jpg`), { force: true }))).catch(() => undefined);
}

async function buildThumb(matches: BattleMatch[], matchId: string): Promise<string> {
  const match = matches.find((item) => item.matchId === matchId);
  if (!match?.videoPath) {
    cache.set(matchId, '');
    return '';
  }
  const file = join(thumbPath, `${safeName(matchId)}.jpg`);
  try {
    if (!existsSync(file)) {
      const offset = Math.max(0, Math.min(3, match.duration / 4000)).toFixed(2);
      await runFFmpeg(['-ss', offset, '-i', match.videoPath, '-frames:v', '1', '-vf', 'scale=560:-2', '-q:v', '5', file]);
    }
    const url = `data:image/jpeg;base64,${(await readFile(file)).toString('base64')}`;
    cache.set(matchId, url);
    return url;
  } catch {
    cache.set(matchId, '');
    return '';
  }
}

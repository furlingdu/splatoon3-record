import { existsSync } from 'node:fs';
import { basename, dirname, join } from 'node:path';
import { readdir, readFile, stat, unlink, writeFile } from 'node:fs/promises';
import { legacyName, safeName } from '../media/file.js';
import type { BattleMatch } from '../../shared/types.js';

const blurFolderName = 'blur';
const blurSuffix = '-昵称打码.mp4';

export async function saveMatch(match: BattleMatch, folder: string): Promise<void> {
  await writeFile(join(folder, `${safeName(match.matchId)}.json`), JSON.stringify(match, null, 2), 'utf8');
}

export async function listMatches(folder: string): Promise<BattleMatch[]> {
  const names = await readdir(folder).catch(() => []);
  const matches: BattleMatch[] = [];
  for (const name of names.filter((item) => item.endsWith('.json'))) {
    try {
      const match = JSON.parse(await readFile(join(folder, name), 'utf8')) as BattleMatch;
      if (match.videoPath && !existsSync(match.videoPath)) match.videoPath = undefined;
      matches.push(match);
    } catch { continue; }
  }
  return matches.sort((a, b) => b.endAt - a.endAt);
}

export async function removeMatch(match: BattleMatch, folder: string): Promise<void> {
  const names = new Set([safeName(match.matchId), legacyName(match.matchId)]);
  await Promise.all([...names].map((name) => unlink(join(folder, `${name}.json`)).catch(() => undefined)));
  if (match.videoPath) await unlink(match.videoPath).catch(() => undefined);
}

export async function purgeArchivedVideos(folder: string): Promise<number> {
  const matches = await listMatches(folder);
  let freed = 0;
  for (const match of matches) {
    if (!match.videoPath) continue;
    const size = (await stat(match.videoPath).catch(() => undefined))?.size ?? 0;
    await unlink(match.videoPath).catch(() => undefined);
    await unlink(blurCopyPath(match.videoPath)).catch(() => undefined);
    await saveMatch({ ...match, videoPath: undefined }, folder);
    freed += size;
  }
  return freed;
}

function blurCopyPath(video: string): string {
  const name = basename(video);
  const dot = name.lastIndexOf('.');
  return join(dirname(video), blurFolderName, `${dot > 0 ? name.slice(0, dot) : name}${blurSuffix}`);
}

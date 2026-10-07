import { homedir } from 'node:os';
import { join, relative, isAbsolute } from 'node:path';
import { mkdir } from 'node:fs/promises';

export const dataPath = join(homedir(), '.splatoon3record');
export const cachePath = join(dataPath, 'cache');
export const tempPath = join(cachePath, 'tmp');
export const blurPath = join(dataPath, 'blur');
export const videoPath = join(dataPath, 'videos');
export const matchPath = join(dataPath, 'matches');
export const thumbPath = join(dataPath, 'thumbs');
export const nsoPath = join(dataPath, 'nso');
export const qqPath = join(dataPath, 'qq');
export const logPath = join(dataPath, 'logs');

export function insidePath(parent: string, child: string): boolean {
  if (!child || !isAbsolute(child)) return false;
  const rest = relative(parent, child);
  return rest === '' || (!rest.startsWith('..') && !isAbsolute(rest));
}

export function saveFolder(saveDir: string): string {
  return saveDir && !insidePath(cachePath, saveDir) ? saveDir : videoPath;
}

export async function initPath(): Promise<void> {
  await Promise.all([dataPath, cachePath, videoPath, matchPath, thumbPath, nsoPath, qqPath, logPath, blurPath].map((path) => mkdir(path, { recursive: true })));
}

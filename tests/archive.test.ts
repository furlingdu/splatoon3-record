import { describe, expect, it } from 'vitest';
import { access, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { listMatches, removeMatch, saveMatch } from '../src/main/match/archive.js';
import { safeName } from '../src/main/media/file.js';
import { makeMatch, withTempDir } from './helpers.js';

async function missing(path: string): Promise<boolean> {
  return access(path).then(() => false).catch(() => true);
}

describe('对局归档', () => {
  it('保存时使用安全文件名并可删除旧格式归档', async () => {
    await withTempDir('s3rArchive', async (folder) => {
      const match = makeMatch({ matchId: 'vs-100' });
      await writeFile(join(folder, 'vs-100.json'), JSON.stringify(match), 'utf8');
      await saveMatch(match, folder);
      const names = await listMatches(folder);
      expect(names).toHaveLength(2);
      await removeMatch(match, folder);
      expect(await missing(join(folder, 'vs-100.json'))).toBe(true);
      const safe = safeName(match.matchId);
      expect(await missing(join(folder, `${safe}.json`))).toBe(true);
    });
  });

  it('视频文件缺失的对局视为未录制', async () => {
    await withTempDir('s3rArchive', async (folder) => {
      const match = makeMatch({ matchId: 'vs-missing', videoPath: join(folder, 'nope.mp4') });
      await writeFile(join(folder, 'vs-missing.json'), JSON.stringify(match), 'utf8');
      const names = await listMatches(folder);
      expect(names.find((item) => item.matchId === 'vs-missing')?.videoPath).toBeUndefined();
    });
  });

  it('视频文件存在的对局保留录像路径', async () => {
    await withTempDir('s3rArchive', async (folder) => {
      const file = join(folder, 'real.mp4');
      await writeFile(file, 'video', 'utf8');
      const match = makeMatch({ matchId: 'vs-keep', videoPath: file });
      await writeFile(join(folder, 'vs-keep.json'), JSON.stringify(match), 'utf8');
      const names = await listMatches(folder);
      expect(names.find((item) => item.matchId === 'vs-keep')?.videoPath).toBe(file);
    });
  });
});

import { mkdir, mkdtemp, readFile, readdir, rm, utimes, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';
import { SegmentStore } from '../src/main/capture/segment.js';
import { cacheMinutesFixed } from '../src/shared/constants.js';
import type { VideoRecord } from '../src/shared/types.js';

const minute = 60000;

interface Layout {
  folder: string;
  temp: string;
}

async function withLayout<T>(task: (layout: Layout) => Promise<T>): Promise<T> {
  const root = await mkdtemp(join(tmpdir(), 's3rSegment'));
  const folder = join(root, 'cache');
  const temp = join(folder, 'tmp');
  await mkdir(temp, { recursive: true });
  try {
    return await task({ folder, temp });
  } finally {
    await rm(root, { recursive: true, force: true });
  }
}

async function writeSegments(folder: string, items: VideoRecord[]): Promise<void> {
  for (const item of items) await writeFile(item.filePath, 'video', 'utf8');
  await writeFile(join(folder, 'segments.json'), JSON.stringify(items), 'utf8');
}

function makeItem(folder: string, name: string, startAt: number, endAt: number): VideoRecord {
  return { filePath: join(folder, name), startAt, endAt, width: 1280, height: 720, fps: 30, encoder: 'libx264', hasAudio: true, flip: false };
}

async function names(folder: string): Promise<string[]> {
  return (await readdir(folder).catch(() => [] as string[])).sort();
}

async function age(target: string, ms: number): Promise<void> {
  const stamp = new Date(Date.now() - ms);
  await utimes(target, stamp, stamp);
}

describe('sweepCache', () => {
  it('回收超出缓存窗口的分段并同步清单', async () => {
    await withLayout(async ({ folder, temp }) => {
      const now = Date.now();
      const old = makeItem(folder, 'segment1000p0.mp4', now - minute, now);
      const fresh = makeItem(folder, 'segment2000p1.mp4', now + 20 * minute, now + 21 * minute);
      await writeSegments(folder, [old, fresh]);
      const store = new SegmentStore({ folder, tempFolder: temp });
      await store.openStore();
      expect(store.records().length).toBe(2);
      expect(await store.sweepCache([], now + 25 * minute)).toBe(1);
      expect(store.records().map((item) => item.endAt)).toEqual([now + 21 * minute]);
      expect((await names(folder)).includes('segment1000p0.mp4')).toBe(false);
      const manifest = JSON.parse(await readFile(join(folder, 'segments.json'), 'utf8')) as VideoRecord[];
      expect(manifest.length).toBe(1);
    });
  });

  it('清理无主分段与遗留分片但保留在写和在裁的文件', async () => {
    await withLayout(async ({ folder, temp }) => {
      const now = Date.now();
      const held = makeItem(folder, 'segment9999p9.mp4', now - minute, now + minute);
      await writeSegments(folder, [held]);
      const store = new SegmentStore({ folder, tempFolder: temp });
      await store.openStore();
      await writeFile(join(folder, `segment${now - 30 * minute}p4.mp4`), 'orphan', 'utf8');
      await writeFile(join(folder, `segment${now}p5.mp4`), 'young', 'utf8');
      await writeFile(join(folder, 'active.part'), 'writing', 'utf8');
      await writeFile(join(folder, 'stale.part'), 'stale', 'utf8');
      await age(join(folder, 'active.part'), 30 * minute);
      await age(join(folder, 'stale.part'), 30 * minute);
      await mkdir(join(temp, 'job1'), { recursive: true });
      await mkdir(join(temp, 'job2'), { recursive: true });
      await age(join(temp, 'job1'), 60 * minute);
      await store.sweepCache([join(folder, 'active.part')]);
      const list = await names(folder);
      expect(list).toContain('active.part');
      expect(list).not.toContain('stale.part');
      expect(list).not.toContain(`segment${now - 30 * minute}p4.mp4`);
      expect(list).toContain(`segment${now}p5.mp4`);
      expect(store.records().length).toBe(1);
      expect((await names(temp)).includes('job1')).toBe(false);
      expect((await names(temp)).includes('job2')).toBe(true);
    });
  });

  it('缓存窗口内的分段不受清理影响', async () => {
    await withLayout(async ({ folder, temp }) => {
      const now = Date.now();
      const keep = makeItem(folder, 'segment3000p0.mp4', now - cacheMinutesFixed * minute + 1000, now - cacheMinutesFixed * minute + 2000);
      await writeSegments(folder, [keep]);
      const store = new SegmentStore({ folder, tempFolder: temp });
      await store.openStore();
      expect(await store.sweepCache()).toBe(0);
      expect((await names(folder)).includes('segment3000p0.mp4')).toBe(true);
    });
  });

  it('被持有的分段即使过期也不删除', async () => {
    await withLayout(async ({ folder, temp }) => {
      const now = Date.now();
      const item = makeItem(folder, 'segment4000p0.mp4', now - minute, now);
      await writeSegments(folder, [item]);
      const store = new SegmentStore({ folder, tempFolder: temp });
      await store.openStore();
      const release = store.holdRecords(store.records());
      expect(await store.sweepCache([], now + 30 * minute)).toBe(0);
      expect((await names(folder)).includes('segment4000p0.mp4')).toBe(true);
      release();
      expect(await store.sweepCache([], now + 30 * minute)).toBe(1);
    });
  });
});

describe('clearCache', () => {
  it('退出时清空分段、分片与临时目录', async () => {
    await withLayout(async ({ folder, temp }) => {
      const now = Date.now();
      const item = makeItem(folder, 'segment5000p0.mp4', now - minute, now);
      await writeSegments(folder, [item]);
      const store = new SegmentStore({ folder, tempFolder: temp });
      await store.openStore();
      await writeFile(join(folder, 'fresh.part'), 'fresh', 'utf8');
      await mkdir(join(temp, 'job9'), { recursive: true });
      await store.clearCache();
      const list = await names(folder);
      expect(list).toEqual(['segments.json']);
      expect(store.records()).toEqual([]);
      expect(await readdir(temp).catch(() => [] as string[])).toEqual([]);
    });
  });
});

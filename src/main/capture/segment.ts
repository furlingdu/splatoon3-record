import { readdir, readFile, rm, stat, writeFile } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import { join, basename } from 'node:path';
import { cachePath, tempPath } from '../store/path.js';
import { cacheMinutesFixed } from '../../shared/constants.js';
import type { VideoRecord } from '../../shared/types.js';

const partMinutes = 10;
const tempMinutes = 30;

interface HoldRange {
  startAt: number;
  endAt: number;
}

export interface StoreSummary {
  count: number;
  start?: number;
  end?: number;
}

export interface StoreOptions {
  folder?: string;
  tempFolder?: string;
}

export class SegmentStore {
  private items: VideoRecord[] = [];
  private ranges: HoldRange[] = [];
  private refs = new Map<string, number>();
  private folder: string;
  private tempFolder: string;
  private cacheMinutes = cacheMinutesFixed;

  constructor(options: StoreOptions = {}) {
    this.folder = options.folder ?? cachePath;
    this.tempFolder = options.tempFolder ?? tempPath;
  }

  async openStore(): Promise<void> {
    const manifest = await readManifest(this.manifestPath());
    const names = await readdir(this.folder).catch(() => [] as string[]);
    const files = new Set(names.filter((name) => name.startsWith('segment')));
    const kept: VideoRecord[] = [];
    for (const record of manifest) {
      const name = basename(record.filePath);
      if (!files.has(name)) continue;
      kept.push(record);
      files.delete(name);
    }
    this.items = kept.sort((a, b) => a.startAt - b.startAt);
    await Promise.all([...files].map((name) => rm(join(this.folder, name), { force: true }).catch(() => undefined)));
    await this.cleanCache();
  }

  records(): VideoRecord[] {
    return this.items;
  }

  summary(): StoreSummary {
    if (!this.items.length) return { count: 0 };
    return {
      count: this.items.length,
      start: Math.min(...this.items.map((item) => item.startAt)),
      end: Math.max(...this.items.map((item) => item.endAt)),
    };
  }

  async register(record: VideoRecord): Promise<void> {
    this.items = [...this.items.filter((item) => item.filePath !== record.filePath), record].sort((a, b) => a.startAt - b.startAt);
    await this.saveManifest();
    await this.cleanCache();
  }

  holdRange(startAt: number, endAt: number): () => void {
    const hold: HoldRange = { startAt, endAt };
    this.ranges.push(hold);
    return () => {
      this.ranges = this.ranges.filter((item) => item !== hold);
    };
  }

  holdRecords(records: VideoRecord[]): () => void {
    const names = records.map((item) => item.filePath);
    names.forEach((name) => this.refs.set(name, (this.refs.get(name) ?? 0) + 1));
    return () => {
      names.forEach((name) => {
        const count = (this.refs.get(name) ?? 0) - 1;
        if (count > 0) this.refs.set(name, count);
        else this.refs.delete(name);
      });
    };
  }

  async cleanCache(now = Date.now()): Promise<number> {
    const threshold = now - this.cacheMinutes * 60000;
    const kept = this.items.filter((item) => item.endAt >= threshold || this.isHeld(item));
    const dropped = this.items.filter((item) => !kept.includes(item));
    this.items = kept;
    for (const record of dropped) {
      await rm(record.filePath, { force: true }).catch(() => undefined);
    }
    if (dropped.length) await this.saveManifest();
    return dropped.length;
  }

  private isHeld(record: VideoRecord): boolean {
    if ((this.refs.get(record.filePath) ?? 0) > 0) return true;
    return this.ranges.some((hold) => hold.startAt < record.endAt && hold.endAt > record.startAt);
  }

  async sweepCache(keep: string[] = [], now = Date.now()): Promise<number> {
    const held = new Set(keep);
    let freed = await this.cleanCache(now);
    freed += await this.dropSegments(now);
    freed += await this.dropParts(now, held);
    freed += await this.dropTemps(now);
    return freed;
  }

  async clearCache(): Promise<void> {
    this.items = [];
    await this.saveManifest();
    const names = await readdir(this.folder).catch(() => [] as string[]);
    for (const name of names) {
      if (name === basename(this.manifestPath()) || (!name.startsWith('segment') && !name.endsWith('.part'))) continue;
      await rm(join(this.folder, name), { force: true }).catch(() => undefined);
    }
    await rm(this.tempFolder, { recursive: true, force: true }).catch(() => undefined);
  }

  private async dropSegments(now: number): Promise<number> {
    const oldest = now - this.cacheMinutes * 60000;
    const known = new Set(this.items.map((item) => basename(item.filePath)));
    const names = await readdir(this.folder).catch(() => [] as string[]);
    const files = names.filter((name) => segmentStamp(name) !== undefined && !known.has(name));
    return this.dropOld(files, (name, stamp) => stamp < oldest);
  }

  private async dropParts(now: number, held: Set<string>): Promise<number> {
    const oldest = now - partMinutes * 60000;
    const names = await readdir(this.folder).catch(() => [] as string[]);
    const files = names.filter((name) => name.endsWith('.part') && !held.has(join(this.folder, name)));
    return this.dropOld(files, (_name, stamp) => stamp < oldest);
  }

  private async dropTemps(now: number): Promise<number> {
    const oldest = now - tempMinutes * 60000;
    const names = await readdir(this.tempFolder).catch(() => [] as string[]);
    let freed = 0;
    for (const name of names) {
      const target = join(this.tempFolder, name);
      const info = await stat(target).catch(() => undefined);
      if (!info || info.mtimeMs >= oldest) continue;
      await rm(target, { recursive: true, force: true }).catch(() => undefined);
      freed += 1;
    }
    return freed;
  }

  private async dropOld(names: string[], expired: (name: string, stamp: number) => boolean): Promise<number> {
    let freed = 0;
    for (const name of names) {
      const target = join(this.folder, name);
      const stamp = segmentStamp(name) ?? (await stat(target).catch(() => undefined))?.mtimeMs;
      if (stamp === undefined || !expired(name, stamp)) continue;
      await rm(target, { force: true }).catch(() => undefined);
      freed += 1;
    }
    return freed;
  }

  private manifestPath(): string {
    return join(this.folder, 'segments.json');
  }

  private async saveManifest(): Promise<void> {
    await writeFile(this.manifestPath(), JSON.stringify(this.items), 'utf8').catch(() => undefined);
  }
}

function segmentStamp(name: string): number | undefined {
  const match = /^segment(\d{6,16})p\d+\./.exec(name);
  return match ? Number(match[1]) : undefined;
}

async function readManifest(file: string): Promise<VideoRecord[]> {
  if (!existsSync(file)) return [];
  try {
    const data = JSON.parse(await readFile(file, 'utf8')) as unknown;
    if (!Array.isArray(data)) return [];
    return data.filter((item): item is VideoRecord => Boolean(item) && typeof item === 'object' && typeof (item as VideoRecord).filePath === 'string' && Number.isFinite((item as VideoRecord).startAt) && Number.isFinite((item as VideoRecord).endAt));
  } catch {
    return [];
  }
}

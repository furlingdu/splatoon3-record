import { mkdir, open, rename, rm, stat, type FileHandle } from 'node:fs/promises';
import { join } from 'node:path';
import { cachePath } from '../store/path.js';
import type { SegmentDraft, VideoRecord } from '../../shared/types.js';

const idPattern = /^[a-z0-9]{6,40}$/;
const extNames = new Set(['mp4', 'mkv', 'webm']);
const chunkLimit = 24 * 1024 * 1024;
const partLimit = 4 * 1024 * 1024 * 1024;

export class SegmentWriter {
  private handles = new Map<string, FileHandle>();
  private sizes = new Map<string, number>();
  private seq = 0;
  private folder: string;

  constructor(folder = cachePath) {
    this.folder = folder;
  }

  async writeChunk(id: string, chunk: Uint8Array, offset: number): Promise<boolean> {
    if (!idPattern.test(id)) return false;
    if (chunk.byteLength === 0 || chunk.byteLength > chunkLimit) return false;
    if (!Number.isFinite(offset) || offset < 0) return false;
    const end = offset + chunk.byteLength;
    if (end > partLimit) return false;
    const handle = await this.openPart(id);
    if (!handle) return false;
    await handle.write(chunk, 0, chunk.byteLength, offset);
    this.sizes.set(id, Math.max(this.sizes.get(id) ?? 0, end));
    return true;
  }

  async sealSegment(draft: SegmentDraft, flip: boolean): Promise<VideoRecord | undefined> {
    const id = draft.id;
    if (!idPattern.test(id)) return undefined;
    await this.closePart(id);
    const startAt = Math.round(Number(draft.startAt));
    const endAt = Math.max(Math.round(Number(draft.endAt)), startAt + 1);
    if (!Number.isFinite(startAt) || !Number.isFinite(endAt) || startAt <= 0) {
      await this.dropSegment(id);
      return undefined;
    }
    const ext = extNames.has(draft.ext) ? draft.ext : 'mp4';
    const filePath = join(this.folder, `segment${startAt}p${this.seq++}.${ext}`);
    this.sizes.delete(id);
    try {
      await rename(this.partPath(id), filePath);
    } catch {
      return undefined;
    }
    return {
      filePath,
      startAt,
      endAt,
      width: Math.max(0, Math.round(Number(draft.width) || 0)),
      height: Math.max(0, Math.round(Number(draft.height) || 0)),
      fps: Math.max(0, Math.round(Number(draft.fps) || 0)),
      encoder: String(draft.encoder ?? '').slice(0, 40),
      hasAudio: Boolean(draft.hasAudio),
      flip,
    };
  }

  async dropSegment(id: string): Promise<void> {
    await this.closePart(id);
    this.sizes.delete(id);
    if (!idPattern.test(id)) return;
    await rm(this.partPath(id), { force: true }).catch(() => undefined);
  }

  async closeAll(): Promise<void> {
    await Promise.all([...this.handles.keys()].map((id) => this.closePart(id)));
  }

  activeParts(): string[] {
    return [...this.handles.keys()].map((id) => this.partPath(id));
  }

  private partPath(id: string): string {
    return join(this.folder, `${id}.part`);
  }

  private async openPart(id: string): Promise<FileHandle | undefined> {
    const running = this.handles.get(id);
    if (running) return running;
    await mkdir(this.folder, { recursive: true });
    const path = this.partPath(id);
    const exists = await stat(path).then(() => true).catch(() => false);
    const handle = await open(path, exists ? 'r+' : 'w').catch(() => undefined);
    if (!handle) return undefined;
    const info = exists ? await handle.stat().catch(() => undefined) : undefined;
    this.handles.set(id, handle);
    this.sizes.set(id, info?.size ?? 0);
    return handle;
  }

  private async closePart(id: string): Promise<void> {
    const handle = this.handles.get(id);
    if (!handle) return;
    this.handles.delete(id);
    await handle.close().catch(() => undefined);
  }
}

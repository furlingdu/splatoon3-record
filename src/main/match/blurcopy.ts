import { createWriteStream, type WriteStream } from 'node:fs';
import { mkdir, readdir, rm } from 'node:fs/promises';
import { randomUUID } from 'node:crypto';
import { basename, dirname, extname, join } from 'node:path';
import { shell } from 'electron';
import { blurPath } from '../store/path.js';
import { getConfig } from '../store/config.js';
import { runFFmpeg } from '../media/ffmpeg.js';
import { runLadder, uploadFilter } from '../media/accel.js';
import { isH264 } from '../../shared/capture.js';
import type { BlurJob } from '../../shared/types.js';

interface BlurSession {
  id: string;
  part: string;
  source: string;
  output: string;
  mime: string;
  stream: WriteStream;
  bytes: number;
  failure?: string;
}

const sessions = new Map<string, BlurSession>();

export async function startBlur(source: string, mime: string): Promise<BlurJob | undefined> {
  if (!source) return undefined;
  const id = randomUUID();
  const part = join(blurPath, `${id}.part`);
  const targetDir = join(dirname(source), 'blur');
  await mkdir(targetDir, { recursive: true }).catch(() => undefined);
  const output = join(targetDir, `${stripExt(basename(source))}-昵称打码.mp4`);
  const stream = createWriteStream(part);
  stream.on('error', (cause) => {
    const session = sessions.get(id);
    if (session) session.failure = cause instanceof Error ? cause.message : String(cause);
  });
  sessions.set(id, { id, part, source, output, mime, stream, bytes: 0 });
  return { jobId: id, output };
}

export async function writeBlur(id: string, chunk: Uint8Array): Promise<boolean> {
  const current = sessions.get(id);
  if (!current) return false;
  if (current.failure) return false;
  current.bytes += chunk.length;
  current.stream.write(Buffer.from(chunk));
  return true;
}

export async function endBlur(id: string, reveal = true): Promise<string | undefined> {
  const current = sessions.get(id);
  if (!current) return undefined;
  sessions.delete(id);
  await closeStream(current.stream);
  if (current.failure) {
    await rm(current.part, { force: true }).catch(() => undefined);
    return undefined;
  }
  const output = current.bytes > 0 ? await muxBlur(current) : undefined;
  await rm(current.part, { force: true }).catch(() => undefined);
  if (output && reveal) shell.showItemInFolder(output);
  return output;
}

export async function cancelBlur(id?: string): Promise<void> {
  const list = id ? [sessions.get(id)].filter((item): item is BlurSession => Boolean(item)) : [...sessions.values()];
  for (const current of list) sessions.delete(current.id);
  await Promise.all(list.map(async (current) => {
    await closeStream(current.stream);
    await rm(current.part, { force: true }).catch(() => undefined);
  }));
}

export async function clearBlur(): Promise<void> {
  await cancelBlur();
  const names = await readdir(blurPath).catch(() => [] as string[]);
  await Promise.all(names.filter((name) => name.endsWith('.part')).map((name) => rm(join(blurPath, name), { force: true }).catch(() => undefined)));
}

async function muxBlur(current: BlurSession): Promise<string | undefined> {
  const settings = getConfig().settings;
  const maps = ['-map', '0:v:0', '-map', '1:a?', '-c:a', 'copy'];
  const tail = ['-movflags', '+faststart', current.output];
  if (isH264(current.mime, '')) {
    const args = ['-i', current.part, '-i', current.source, ...maps, '-c:v', 'copy', ...tail];
    const copied = await runFFmpeg(args).then(() => true).catch(() => false);
    if (copied) return current.output;
  }
  const output = await runLadder(settings.encoder, { kind: 'quality', quality: settings.quality }, 'hevc', async (rung) => {
    const upload = uploadFilter(rung.encode);
    const args = [
      ...rung.decodeArgs,
      '-i', current.part,
      '-i', current.source,
      ...maps,
      ...rung.encodeArgs,
      ...(upload ? ['-vf', upload] : ['-pix_fmt', 'yuv420p']),
      '-tag:v', 'hvc1',
      ...tail,
    ];
    const ok = await runFFmpeg(args).then(() => true).catch(() => false);
    return ok ? current.output : undefined;
  });
  if (!output) await rm(current.output, { force: true }).catch(() => undefined);
  return output;
}

function stripExt(name: string): string {
  const ext = extname(name);
  return ext ? name.slice(0, -ext.length) : name;
}

function closeStream(stream: WriteStream): Promise<void> {
  return new Promise((resolve) => {
    stream.end(() => resolve());
    stream.on('error', () => resolve());
  });
}

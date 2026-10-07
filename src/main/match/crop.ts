import { mkdir, rm, writeFile } from 'node:fs/promises';
import { basename, join } from 'node:path';
import { runLadder, uploadFilter, type AccelRung } from '../media/accel.js';
import { runFFmpeg } from '../media/ffmpeg.js';
import { probeAudio } from '../media/video.js';
import { matchFileName } from '../../shared/nso.js';
import { tempPath, videoPath } from '../store/path.js';
import { cropParts, type CropPart } from './clock.js';
import type { BattleMatch, RecordSettings, VideoRecord } from '../../shared/types.js';

export interface CropClip {
  startAt: number;
  endAt: number;
}

interface TargetSize {
  width: number;
  height: number;
  fps: number;
}

let jobSeq = 0;
const audioProbe = new Map<string, boolean>();

export async function cropVideo(records: VideoRecord[], match: BattleMatch, folder: string, settings: RecordSettings, clip: CropClip): Promise<string | undefined> {
  const parts = cropParts(records, clip);
  if (!parts.length) return undefined;
  const target = targetSize(parts[0].record, settings);
  const output = join(folder || videoPath, `${matchFileName(match)}.mp4`);
  await mkdir(folder || videoPath, { recursive: true }).catch(() => undefined);
  const done = await runLadder(settings.encoder, { kind: 'quality', quality: settings.quality }, 'hevc', (rung) => renderParts(parts, rung, target, output));
  if (!done) await rm(output, { force: true }).catch(() => undefined);
  return done;
}

async function renderParts(parts: CropPart[], rung: AccelRung, target: TargetSize, output: string): Promise<string> {
  const audible = await Promise.all(parts.map((part) => partAudible(part.record)));
  const wantAudio = audible.some(Boolean);
  if (parts.length === 1) {
    const silent = wantAudio && !audible[0];
    try {
      await renderPiece(parts[0], rung, target, output, wantAudio, silent, true);
      return output;
    } catch (cause) {
      await rm(output, { force: true }).catch(() => undefined);
      throw cause;
    }
  }
  const work = join(tempPath, `job${Date.now()}${jobSeq++}`);
  await mkdir(work, { recursive: true }).catch(() => undefined);
  try {
    const pieces: string[] = [];
    for (const [index, part] of parts.entries()) {
      const piece = join(work, `piece${index}.ts`);
      await renderPiece(part, rung, target, piece, wantAudio, wantAudio && !audible[index], false);
      pieces.push(basename(piece));
    }
    const list = join(work, 'list.txt');
    await writeFile(list, pieces.map((name) => `file '${name}'`).join('\n'), 'utf8');
    await runFFmpeg(['-f', 'concat', '-safe', '0', '-i', list, '-c', 'copy', '-tag:v', 'hvc1', '-movflags', '+faststart', output]);
    return output;
  } catch (cause) {
    await rm(output, { force: true }).catch(() => undefined);
    throw cause;
  } finally {
    await rm(work, { recursive: true, force: true }).catch(() => undefined);
  }
}

async function partAudible(record: VideoRecord): Promise<boolean> {
  if (!record.hasAudio) return false;
  const cached = audioProbe.get(record.filePath);
  if (cached !== undefined) return cached;
  const audible = await probeAudio(record.filePath);
  if (audioProbe.size > 512) audioProbe.clear();
  audioProbe.set(record.filePath, audible);
  return audible;
}

function renderPiece(part: CropPart, rung: AccelRung, target: TargetSize, output: string, wantAudio: boolean, silent: boolean, mp4: boolean): Promise<void> {
  return runFFmpeg(pieceArgs(part, rung, target, output, wantAudio, silent, mp4));
}

function pieceArgs(part: CropPart, rung: AccelRung, target: TargetSize, output: string, wantAudio: boolean, silent: boolean, mp4: boolean): string[] {
  const span = part.duration.toFixed(3);
  const args = [...rung.decodeArgs, '-ss', part.offset.toFixed(3), '-t', span, '-i', part.record.filePath];
  if (silent) args.push('-f', 'lavfi', '-t', span, '-i', 'anullsrc=r=48000:cl=stereo');
  args.push('-map', '0:v:0');
  if (wantAudio) args.push('-map', silent ? '1:a:0' : '0:a:0', '-c:a', 'aac', '-b:a', '128k', '-ar', '48000', '-ac', '2');
  const filters = filterChain(part.record, target);
  const upload = uploadFilter(rung.encode);
  if (upload) filters.push(upload);
  if (filters.length) args.push('-vf', filters.join(','));
  if (!upload) args.push('-pix_fmt', 'yuv420p');
  args.push(...rung.encodeArgs, '-fps_mode', 'cfr', '-r', String(target.fps));
  if (mp4) args.push('-movflags', '+faststart', '-tag:v', 'hvc1');
  args.push(output);
  return args;
}

function filterChain(record: VideoRecord, target: TargetSize): string[] {
  const filters: string[] = [];
  if (record.width && record.height && (record.width !== target.width || record.height !== target.height)) {
    filters.push(`scale=${target.width}:${target.height}:force_original_aspect_ratio=decrease`, `pad=${target.width}:${target.height}:(ow-iw)/2:(oh-ih)/2`, 'setsar=1');
  }
  if (record.flip) filters.push('vflip');
  return filters;
}

function targetSize(record: VideoRecord, settings: RecordSettings): TargetSize {
  return {
    width: evenNumber(record.width || settings.width),
    height: evenNumber(record.height || settings.height),
    fps: Math.max(1, Math.round(record.fps || settings.fps)),
  };
}

function evenNumber(value: number): number {
  return Math.max(2, Math.round(value / 2) * 2);
}

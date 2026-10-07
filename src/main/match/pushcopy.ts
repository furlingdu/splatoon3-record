import { mkdir, rm, stat } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import { runLadder, uploadFilter, type AccelRung } from '../media/accel.js';
import { pushAudioBps, pushBitrate } from '../../shared/bitrate.js';
import { runFFmpeg } from '../media/ffmpeg.js';
import { matchFileName } from '../../shared/nso.js';
import { pushEnv } from '../store/env.js';
import { tempPath } from '../store/path.js';
import { clipRange } from './clock.js';
import type { BattleMatch, PushCodec, RecordSettings } from '../../shared/types.js';

const lowestBitrate = 200000;
const pushFps = 60;

let jobSeq = 0;

export async function pushCopy(match: BattleMatch, settings: RecordSettings): Promise<string | undefined> {
  const source = match.videoPath;
  if (!source) return undefined;
  const env = pushEnv();
  const sizeLimit = env.targetMb * 1024 * 1024;
  const clip = clipRange(match);
  const folder = join(tempPath, `push${Date.now()}${jobSeq++}`);
  const output = join(folder, `${matchFileName(match)}.mp4`);
  await mkdir(folder, { recursive: true }).catch(() => undefined);
  let bitrate = pushBitrate(env.cap, clip.endAt - clip.startAt, env.targetMb);
  for (let pass = 0; pass < 4; pass++) {
    const size = await renderCopy(source, output, settings.encoder, bitrate, env.codec);
    if (!size) break;
    if (size <= sizeLimit) return output;
    bitrate = Math.max(lowestBitrate, Math.floor(((bitrate * sizeLimit) / size) * 0.8));
  }
  await dropCopy(output);
  return undefined;
}

export async function dropCopy(file?: string): Promise<void> {
  if (!file) return;
  await rm(dirname(file), { recursive: true, force: true }).catch(() => undefined);
}

async function renderCopy(source: string, output: string, encoder: RecordSettings['encoder'], bitrate: number, codec: PushCodec): Promise<number> {
  const size = await runLadder(encoder, { kind: 'rate', bitrate }, codec, async (rung) => {
    await runFFmpeg(copyArgs(source, output, rung, codec));
    const bytes = (await stat(output).catch(() => undefined))?.size ?? 0;
    return bytes > 0 ? bytes : undefined;
  });
  if (!size) await rm(output, { force: true }).catch(() => undefined);
  return size ?? 0;
}

function copyArgs(source: string, output: string, rung: AccelRung, codec: PushCodec): string[] {
  const scale = "scale=w='min(1920,iw)':h='min(1080,ih)':force_original_aspect_ratio=decrease:force_divisible_by=2";
  const upload = uploadFilter(rung.encode);
  const tagArgs = codec === 'hevc' || rung.encode.includes('hevc') || rung.encode.includes('265') ? ['-tag:v', 'hvc1'] : [];
  return [
    ...rung.decodeArgs,
    '-i', source,
    '-vf', upload ? `${scale},setsar=1,${upload}` : `${scale},setsar=1`,
    ...rung.encodeArgs,
    ...(upload ? [] : ['-pix_fmt', 'yuv420p']),
    '-fps_mode', 'cfr',
    '-r', String(pushFps),
    '-c:a', 'aac', '-b:a', `${Math.round(pushAudioBps / 1000)}k`, '-ar', '48000', '-ac', '2',
    '-movflags', '+faststart',
    ...tagArgs,
    output,
  ];
}

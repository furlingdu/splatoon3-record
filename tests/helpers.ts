import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { runFFmpeg } from '../src/main/media/ffmpeg.js';
import type { BattleMatch, RecordSettings, VideoRecord } from '../src/shared/types.js';

export function makeSettings(overrides: Partial<RecordSettings> = {}): RecordSettings {
  return {
    videoDevice: 'test-camera',
    audioDevice: 'test-audio',
    width: 3840,
    height: 2160,
    fps: 60,
    flipVertical: false,
    encoder: 'auto',
    quality: 22,
    saveDir: 'D:/videos',
    autoPush: true,
    autoRecord: true,
    autoLaunch: false,
    pollSeconds: 10,
    blurNickname: false,
    monitorAudio: false,
    ...overrides,
  };
}

export function makeRecord(overrides: Partial<VideoRecord> = {}): VideoRecord {
  return {
    filePath: 'segment.mp4',
    startAt: 0,
    endAt: 30000,
    width: 1920,
    height: 1080,
    fps: 60,
    encoder: 'libx264',
    hasAudio: true,
    flip: false,
    ...overrides,
  };
}

export function makeMatch(overrides: Partial<BattleMatch> = {}): BattleMatch {
  return {
    matchId: 'match-1',
    kind: 'regular',
    mode: 'REGULAR',
    rule: 'TURF_WAR',
    startAt: 0,
    endAt: 1000,
    duration: 1000,
    result: 'WIN',
    isDisconnected: false,
    isSalmon: false,
    rawData: {},
    ...overrides,
  };
}

export async function withTempDir<T>(prefix: string, task: (folder: string) => Promise<T>): Promise<T> {
  const folder = await mkdtemp(join(tmpdir(), prefix));
  try {
    return await task(folder);
  } finally {
    await rm(folder, { recursive: true, force: true });
  }
}

export async function createMedia(file: string, options: { duration?: number; width?: number; height?: number; fps?: number; audio?: boolean } = {}): Promise<void> {
  const duration = options.duration ?? 5;
  const width = options.width ?? 320;
  const height = options.height ?? 180;
  const fps = options.fps ?? 25;
  const args = ['-f', 'lavfi', '-i', `testsrc2=duration=${duration}:size=${width}x${height}:rate=${fps}`];
  if (options.audio) args.push('-f', 'lavfi', '-i', `sine=frequency=440:duration=${duration}`);
  args.push('-t', String(duration), '-c:v', 'libx264', '-preset', 'ultrafast', '-pix_fmt', 'yuv420p');
  if (options.audio) args.push('-c:a', 'aac');
  args.push(file);
  await runFFmpeg(args);
}

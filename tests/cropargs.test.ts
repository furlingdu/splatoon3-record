import { afterEach, describe, expect, it, vi } from 'vitest';
import type { AccelRung } from '../src/main/media/accel.js';
import { makeMatch, makeRecord, makeSettings, withTempDir } from './helpers.js';

const state = vi.hoisted(() => ({ calls: [] as string[][], rung: undefined as AccelRung | undefined }));

vi.mock('../src/main/media/ffmpeg.js', () => ({
  runFFmpeg: async (args: string[]) => { state.calls.push(args); },
}));
vi.mock('../src/main/media/video.js', () => ({ probeAudio: async () => true }));
vi.mock('../src/main/store/log.js', () => ({ logApp: () => undefined }));
vi.mock('../src/main/media/accel.js', () => ({
  runLadder: async (_encoder: unknown, _mode: unknown, _codec: unknown, job: (rung: AccelRung) => Promise<string>) => job(state.rung!),
  uploadFilter: () => '',
}));

import { cropVideo } from '../src/main/match/crop.js';

afterEach(() => { state.calls = []; });

function rung(encode = 'hevc_nvenc', preset = 'p5'): AccelRung {
  return { encode, encodeArgs: ['-c:v', encode, '-preset', preset, '-rc', 'constqp', '-qp', '28'], decodeArgs: [], label: encode };
}

describe('archive encoding preset', () => {
  it('归档单独使用快速 NVENC 预设并保留质量、画幅、帧率与音轨', async () => {
    state.rung = rung();
    await withTempDir('s3rCropArgs', async (folder) => {
      await cropVideo([makeRecord()], makeMatch(), folder, makeSettings({ quality: 28 }), { startAt: 1000, endAt: 4000 });
    });
    const args = state.calls[0];
    expect(args[args.indexOf('-preset') + 1]).toBe('p3');
    expect(args[args.indexOf('-qp') + 1]).toBe('28');
    expect(args).toContain('0:a:0');
    expect(args[args.indexOf('-r') + 1]).toBe('60');
    expect(args[args.indexOf('-ss') + 1]).toBe('1.000000');
    expect(args[args.indexOf('-t') + 1]).toBe('3.000000');
    expect(state.rung.encodeArgs[state.rung.encodeArgs.indexOf('-preset') + 1]).toBe('p5');
  });

  it('软件编码器维持原预设', async () => {
    state.rung = rung('libx265', 'veryfast');
    await withTempDir('s3rCropSoftwareArgs', async (folder) => {
      await cropVideo([makeRecord({ hasAudio: false })], makeMatch(), folder, makeSettings(), { startAt: 0, endAt: 1000 });
    });
    expect(state.calls[0][state.calls[0].indexOf('-preset') + 1]).toBe('veryfast');
    expect(state.calls[0]).not.toContain('0:a:0');
  });
});

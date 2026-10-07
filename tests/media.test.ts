import { mkdir, readFile, stat } from 'node:fs/promises';
import { join } from 'node:path';
import { describe, expect, it, vi } from 'vitest';
import { accelActive, accelSummary, accelFallback, prepareAccel, qualityArgs, uploadFilter } from '../src/main/media/accel.js';
import { runCommand, runFFmpeg } from '../src/main/media/ffmpeg.js';
import { probeAudio } from '../src/main/media/video.js';
import { cropVideo } from '../src/main/match/crop.js';
import { clipRange } from '../src/main/match/clock.js';
import { dropCopy, pushCopy } from '../src/main/match/pushcopy.js';
import { cancelBlur, endBlur, startBlur, writeBlur } from '../src/main/match/blurcopy.js';
import { blurPath } from '../src/main/store/path.js';
import { pushTargetMb } from '../src/shared/constants.js';
import { matchFileName } from '../src/shared/nso.js';
import { createMedia, makeMatch, makeRecord, makeSettings, withTempDir } from './helpers.js';
import type { BlurJob } from '../src/shared/types.js';

vi.mock('electron', () => ({ shell: { showItemInFolder: () => undefined } }));

async function probeText(file: string): Promise<string> {
  const result = await runCommand(['-hide_banner', '-i', file]);
  return result.output;
}

async function probeDuration(file: string): Promise<number> {
  const text = await probeText(file);
  const match = /Duration:\s*(\d+):(\d+):(\d+(?:\.\d+)?)/.exec(text);
  if (!match) return Number.NaN;
  return Number(match[1]) * 3600 + Number(match[2]) * 60 + Number(match[3]);
}

async function decodeCheck(file: string): Promise<string> {
  const result = await runCommand(['-hide_banner', '-v', 'error', '-i', file, '-f', 'null', '-']);
  return result.code === 0 ? '' : result.output.trim();
}

async function pixelAt(file: string, folder: string, x: number, y: number): Promise<number[]> {
  const raw = join(folder, `pixel-${x}-${y}.rgb`);
  const result = await runCommand(['-hide_banner', '-v', 'error', '-y', '-ss', '1', '-i', file, '-frames:v', '1', '-vf', `crop=2:2:${x}:${y}`, '-f', 'rawvideo', '-pix_fmt', 'rgb24', raw]);
  if (result.code !== 0) throw new Error(result.output.trim() || `像素采样失败 ${x},${y}`);
  const bytes = await readFile(raw);
  return [bytes[0], bytes[1], bytes[2]];
}

describe('cropVideo', () => {
  it('单段裁剪输出可解码的 HEVC MP4', async () => {
    await withTempDir('s3rCropOne', async (folder) => {
      const source = join(folder, 'one.mp4');
      await createMedia(source, { duration: 6, width: 320, height: 180, fps: 25, audio: true });
      const record = makeRecord({ filePath: source, startAt: 0, endAt: 6000, width: 320, height: 180, fps: 25 });
      const match = makeMatch({ matchId: 'single', kind: 'regular', endAt: 1000 });
      const output = await cropVideo([record], match, folder, makeSettings({ encoder: 'software' }), { startAt: 1000, endAt: 4000 });
      expect(output).toBe(join(folder, `${matchFileName(match)}.mp4`));
      expect(output).toMatch(/占地对战-\d{8}-\d{6}\.mp4$/);
      expect(await probeText(output as string)).toContain('Video: hevc');
      expect(await decodeCheck(output as string)).toBe('');
      const duration = await probeDuration(output as string);
      expect(duration).toBeGreaterThan(2.6);
      expect(duration).toBeLessThan(3.4);
    });
  });

  it('跨分段裁剪先分片再拼接并统一画幅', async () => {
    await withTempDir('s3rCropMany', async (folder) => {
      const first = join(folder, 'a.mp4');
      const second = join(folder, 'b.mp4');
      await createMedia(first, { duration: 4, width: 320, height: 180, fps: 25, audio: true });
      await createMedia(second, { duration: 4, width: 640, height: 360, fps: 25, audio: true });
      const records = [
        makeRecord({ filePath: first, startAt: 0, endAt: 4000, width: 320, height: 180, fps: 25 }),
        makeRecord({ filePath: second, startAt: 4000, endAt: 8000, width: 640, height: 360, fps: 25 }),
      ];
      const output = await cropVideo(records, makeMatch({ matchId: 'many' }), folder, makeSettings({ encoder: 'software' }), { startAt: 2000, endAt: 6000 });
      expect(output).toBeDefined();
      expect(await decodeCheck(output as string)).toBe('');
      expect(await probeText(output as string)).toContain('Video: hevc');
      expect(await probeText(output as string)).toContain('320x180');
      const duration = await probeDuration(output as string);
      expect(duration).toBeGreaterThan(3.6);
      expect(duration).toBeLessThan(4.4);
    });
  });

  it('垂直翻转按分段标记生效', async () => {
    await withTempDir('s3rCropFlip', async (folder) => {
      const source = join(folder, 'source.mp4');
      await runCommand(['-hide_banner', '-v', 'error', '-y', '-f', 'lavfi', '-i', 'color=c=red:s=160x90:d=3', '-f', 'lavfi', '-i', 'color=c=blue:s=160x90:d=3', '-filter_complex', '[0:v][1:v]vstack=inputs=2[out]', '-map', '[out]', '-c:v', 'libx264', '-preset', 'ultrafast', '-pix_fmt', 'yuv420p', '-r', '25', source]);
      const record = makeRecord({ filePath: source, startAt: 0, endAt: 3000, width: 160, height: 180, fps: 25, hasAudio: false, flip: true });
      const output = await cropVideo([record], makeMatch({ matchId: 'flip' }), folder, makeSettings({ encoder: 'software' }), { startAt: 500, endAt: 2500 });
      expect(output).toBeDefined();
      const top = await pixelAt(output as string, folder, 80, 5);
      const bottom = await pixelAt(output as string, folder, 80, 175);
      expect(top[2]).toBeGreaterThan(150);
      expect(bottom[0]).toBeGreaterThan(150);
    });
  });

  it('没有重叠分段时不产出文件', async () => {
    await withTempDir('s3rCropEmpty', async (folder) => {
      const source = join(folder, 'gap.mp4');
      await createMedia(source, { duration: 2 });
      const record = makeRecord({ filePath: source, startAt: 0, endAt: 2000, hasAudio: false });
      const output = await cropVideo([record], makeMatch({ matchId: 'gap' }), folder, makeSettings({ encoder: 'software' }), { startAt: 30000, endAt: 40000 });
      expect(output).toBeUndefined();
    });
  });
  it('HEVC 源分段可裁剪并输出归档', async () => {
    await withTempDir('s3rCropHevc', async (folder) => {
      const source = join(folder, 'hevc.mp4');
      await runCommand(['-hide_banner', '-v', 'error', '-y', '-f', 'lavfi', '-i', 'testsrc2=duration=4:size=320x180:rate=25', '-c:v', 'libx265', '-preset', 'ultrafast', '-pix_fmt', 'yuv420p', '-tag:v', 'hvc1', source]);
      const record = makeRecord({ filePath: source, startAt: 0, endAt: 4000, width: 320, height: 180, fps: 25, hasAudio: false });
      const output = await cropVideo([record], makeMatch({ matchId: 'hevcsrc' }), folder, makeSettings({ encoder: 'software' }), { startAt: 500, endAt: 2500 });
      expect(output).toBeDefined();
      expect(await decodeCheck(output as string)).toBe('');
      expect(await probeText(output as string)).toContain('Video: hevc');
      const duration = await probeDuration(output as string);
      expect(duration).toBeGreaterThan(1.6);
      expect(duration).toBeLessThan(2.4);
    });
  });
  it('清单标记有音频但分段实际只有视频轨时仍能裁剪', async () => {
    await withTempDir('s3rCropSilent', async (folder) => {
      const first = join(folder, 'silent-a.mp4');
      const second = join(folder, 'silent-b.mp4');
      for (const file of [first, second]) {
        await runCommand(['-hide_banner', '-v', 'error', '-y', '-f', 'lavfi', '-i', 'testsrc2=duration=3:size=320x180:rate=25', '-c:v', 'libx265', '-preset', 'ultrafast', '-pix_fmt', 'yuv420p', '-tag:v', 'hvc1', file]);
      }
      const records = [
        makeRecord({ filePath: first, startAt: 0, endAt: 3000, width: 320, height: 180, fps: 25, hasAudio: true }),
        makeRecord({ filePath: second, startAt: 3000, endAt: 6000, width: 320, height: 180, fps: 25, hasAudio: true }),
      ];
      const output = await cropVideo(records, makeMatch({ matchId: 'silent' }), folder, makeSettings({ encoder: 'software' }), { startAt: 500, endAt: 5500 });
      expect(output).toBeDefined();
      expect(await decodeCheck(output as string)).toBe('');
      const text = await probeText(output as string);
      expect(text).toContain('Video: hevc');
      expect(text).not.toContain('Audio:');
    });
  });
  it('音频分段与静音分段拼接时统一补静音', async () => {
    await withTempDir('s3rCropMixed', async (folder) => {
      const voiced = join(folder, 'voiced.mp4');
      const silent = join(folder, 'silent.mp4');
      await createMedia(voiced, { duration: 3, width: 320, height: 180, fps: 25, audio: true });
      await runCommand(['-hide_banner', '-v', 'error', '-y', '-f', 'lavfi', '-i', 'testsrc2=duration=3:size=320x180:rate=25', '-c:v', 'libx265', '-preset', 'ultrafast', '-pix_fmt', 'yuv420p', '-tag:v', 'hvc1', silent]);
      const records = [
        makeRecord({ filePath: voiced, startAt: 0, endAt: 3000, width: 320, height: 180, fps: 25, hasAudio: true }),
        makeRecord({ filePath: silent, startAt: 3000, endAt: 6000, width: 320, height: 180, fps: 25, hasAudio: true }),
      ];
      const output = await cropVideo(records, makeMatch({ matchId: 'mixed' }), folder, makeSettings({ encoder: 'software' }), { startAt: 500, endAt: 5500 });
      expect(output).toBeDefined();
      expect(await decodeCheck(output as string)).toBe('');
      expect(await probeText(output as string)).toContain('Audio: aac');
    });
  });
});

describe('probeAudio', () => {
  it('区分有音轨与只有视频轨的文件', async () => {
    await withTempDir('s3rProbeAudio', async (folder) => {
      const voiced = join(folder, 'voiced.mp4');
      const silent = join(folder, 'silent.mp4');
      await createMedia(voiced, { duration: 2, audio: true });
      await createMedia(silent, { duration: 2 });
      expect(await probeAudio(voiced)).toBe(true);
      expect(await probeAudio(silent)).toBe(false);
    });
  });
});

describe('prepareAccel', () => {
  it('生成硬件解码阶梯并带上启用档位摘要', async () => {
    const ladder = await prepareAccel('auto', { kind: 'rate', bitrate: 20000000 });
    expect(ladder.length).toBeGreaterThan(0);
    const summary = accelSummary();
    expect(summary.encoder).toBeTruthy();
    expect(typeof summary.hwAccel).toBe('string');
    expect(accelActive()?.encode).toBeTruthy();
  });

  it('请求硬件编码时首选硬编档位，耗尽后回退软件编码', async () => {
    const ladder = await prepareAccel('nvidia', { kind: 'rate', bitrate: 20000000 }, 'h264');
    expect(ladder[0].encode).toBe('h264_nvenc');
    while (accelFallback() && accelActive()?.encode !== 'libx264') continue;
    expect(accelActive()?.encode).toBe('libx264');
  });

  it('软件编码档位只排列软件编码器', async () => {
    const ladder = await prepareAccel('software', { kind: 'rate', bitrate: 5000000 }, 'h264');
    expect(ladder.every((rung) => rung.encode === 'libx264' || Boolean(rung.decode))).toBe(true);
    expect(ladder.some((rung) => rung.encode === 'libx264')).toBe(true);
  });

  it('不指定编码器时默认走 HEVC', async () => {
    const ladder = await prepareAccel('auto', { kind: 'rate', bitrate: 8000000 });
    expect(ladder.every((rung) => rung.encode.includes('hevc') || rung.encode === 'libx265')).toBe(true);
    expect(ladder.some((rung) => rung.encode === 'libx265')).toBe(true);
  });

  it('自动阶梯把 Vulkan 编码排在厂商编码之后', async () => {
    const ladder = await prepareAccel('auto', { kind: 'rate', bitrate: 8000000 }, 'h264');
    const labels = ladder.map((rung) => `${rung.decode ?? ''}|${rung.encode}`);
    expect(labels.indexOf('|h264_vulkan')).toBeGreaterThan(labels.findIndex((item) => item.endsWith('|h264_nvenc')));
    const vulkan = ladder.find((rung) => rung.encode === 'h264_vulkan');
    expect(vulkan?.decodeArgs).toEqual([]);
    expect(vulkan?.encodeArgs.join(' ')).toContain('vulkan=vk');
    expect(uploadFilter('h264_vulkan')).toBe('format=nv12,hwupload');
    expect(uploadFilter('h264_nvenc')).toBe('');
  });

  it('HEVC 阶梯把 Vulkan 编码排在厂商编码之后', async () => {
    const ladder = await prepareAccel('auto', { kind: 'rate', bitrate: 8000000 }, 'hevc');
    const labels = ladder.map((rung) => `${rung.decode ?? ''}|${rung.encode}`);
    expect(labels.indexOf('|hevc_vulkan')).toBeGreaterThan(labels.findIndex((item) => item.endsWith('|hevc_nvenc')));
    const vulkan = ladder.find((rung) => rung.encode === 'hevc_vulkan');
    expect(vulkan?.decodeArgs).toEqual([]);
    expect(vulkan?.encodeArgs.join(' ')).toContain('vulkan=vk');
    expect(uploadFilter('hevc_vulkan')).toBe('format=nv12,hwupload');
    expect(vulkan?.encodeArgs.join(' ')).toContain('-b:v');
    expect(vulkan?.encodeArgs.join(' ')).not.toContain('-crf');
    expect(vulkan?.encodeArgs.join(' ')).not.toContain('-qp');
  });

  it('推送版阶梯按指定编码器排列并保留硬件优先', async () => {
    const hevc = await prepareAccel('auto', { kind: 'rate', bitrate: 2000000 }, 'hevc');
    expect(hevc.some((rung) => rung.encode === 'libx265')).toBe(true);
    expect(hevc.every((rung) => !rung.encodeArgs.includes('-minrate') && !rung.encodeArgs.includes('cbr'))).toBe(true);
    const av1 = await prepareAccel('nvidia', { kind: 'rate', bitrate: 5000000 }, 'av1');
    expect(av1[0].encode).toBe('av1_nvenc');
    expect(av1[0].encodeArgs.join(' ')).toContain('-rc vbr');
    while (accelFallback() && accelActive()?.encode !== 'libaom-av1') continue;
    expect(accelActive()?.encode).toBe('libaom-av1');
  });

  it('码率控制参数带上限与缓冲', async () => {
    const ladder = await prepareAccel('software', { kind: 'rate', bitrate: 2500000 });
    const args = ladder[0].encodeArgs.join(' ');
    expect(args).toContain('-b:v 2500000');
    expect(args).toContain('-maxrate 2500000');
    expect(args).toContain('-bufsize 5000000');
  });

  it('归档质量档走 CQP 不再限制码率', async () => {
    const ladder = await prepareAccel('software', { kind: 'quality', quality: 22 });
    const args = ladder[0].encodeArgs.join(' ');
    expect(args).toContain('-crf 22');
    expect(args).not.toContain('-b:v');
    expect(qualityArgs('hevc_nvenc', 18).join(' ')).toContain('-rc constqp -qp 18');
  });

  it('vulkan 质量档使用合法的 cqp 档位名', async () => {
    const args = qualityArgs('hevc_vulkan', 22).join(' ');
    expect(args).toContain('-rc_mode cqp');
    expect(args).not.toContain('constqp');
    expect(args).toContain('-qp 22');
  });

  it('按新码率重建阶梯时保留已经降级到的档位', async () => {
    await prepareAccel('software', { kind: 'rate', bitrate: 20000000 });
    accelFallback();
    const kept = accelActive()?.encode;
    await prepareAccel('software', { kind: 'rate', bitrate: 1500000 });
    expect(accelActive()?.encode).toBe(kept);
    expect(accelActive()?.encodeArgs.join(' ')).toContain('1500000');
  });
});

describe('pushCopy', () => {
  it('把高于 1080p 的归档转成 HEVC MP4 1080p60 且落在整段上传上限内', async () => {
    await withTempDir('s3rPushCopy', async (folder) => {
      const source = join(folder, 'archive.mp4');
      await createMedia(source, { duration: 4, width: 2560, height: 1440, fps: 30, audio: true });
      const match = makeMatch({ matchId: 'pushcopy', videoPath: source, startAt: 0, endAt: 4000, duration: 4000 });
      const output = await pushCopy(match, makeSettings({ encoder: 'software' }));
      try {
        expect(output).toBeDefined();
        expect(output).toMatch(/占地对战-\d{8}-\d{6}\.mp4$/);
        const text = await probeText(output as string);
        expect(text).toContain('hevc');
        expect(text).toContain('Audio: aac');
        expect(text).toContain('1920x1080');
        expect(text).toContain('60 fps');
        expect(await decodeCheck(output as string)).toBe('');
        expect((await stat(output as string)).size).toBeLessThan(pushTargetMb * 1024 * 1024);
      } finally {
        await dropCopy(output);
      }
    });
  });

  it('低于 1080p 的归档不放大', async () => {
    await withTempDir('s3rPushSmall', async (folder) => {
      const source = join(folder, 'small.mp4');
      await createMedia(source, { duration: 3, width: 640, height: 360, fps: 30, audio: true });
      const match = makeMatch({ matchId: 'pushsmall', videoPath: source, startAt: 0, endAt: 3000, duration: 3000 });
      const output = await pushCopy(match, makeSettings({ encoder: 'software' }));
      try {
        expect(output).toBeDefined();
        expect(await probeText(output as string)).toContain('640x360');
      } finally {
        await dropCopy(output);
      }
    });
  });

  it('按对局时长与目标体积算出的码率能把归档压到目标附近', async () => {
    await withTempDir('s3rPushBudget', async (folder) => {
      const previous = process.env.PUSH_FILE_LIMIT_MB;
      process.env.PUSH_FILE_LIMIT_MB = '5';
      try {
        const source = join(folder, 'archive.mp4');
        await runCommand(['-hide_banner', '-v', 'error', '-y', '-f', 'lavfi', '-i', 'testsrc2=duration=65:size=1280x720:rate=60', '-f', 'lavfi', '-i', 'sine=frequency=440:duration=65', '-t', '65', '-c:v', 'libx264', '-preset', 'ultrafast', '-crf', '10', '-pix_fmt', 'yuv420p', '-c:a', 'aac', source]);
        const match = makeMatch({ matchId: 'pushbudget', videoPath: source, startAt: 0, endAt: 20000, duration: 20000 });
        expect(clipRange(match).endAt - clipRange(match).startAt).toBe(65000);
        const output = await pushCopy(match, makeSettings({ encoder: 'software' }));
        try {
          expect(output).toBeDefined();
          expect(await decodeCheck(output as string)).toBe('');
          const size = (await stat(output as string)).size;
          expect(size).toBeLessThanOrEqual(5 * 1024 * 1024);
          expect(size).toBeGreaterThan(3.5 * 1024 * 1024);
        } finally {
          await dropCopy(output);
        }
      } finally {
        if (previous === undefined) delete process.env.PUSH_FILE_LIMIT_MB;
        else process.env.PUSH_FILE_LIMIT_MB = previous;
      }
    });
  });
});

describe('blurCopy', () => {
  it('打码画面与原音轨合成为可解码的 MP4', async () => {
    await withTempDir('s3rBlurCopy', async (folder) => {
      await mkdir(blurPath, { recursive: true });
      const source = join(folder, 'archive.mp4');
      await createMedia(source, { duration: 4, width: 320, height: 180, fps: 25, audio: true });
      const part = join(folder, 'part.mp4');
      await runFFmpeg(['-v', 'error', '-f', 'lavfi', '-i', 'color=c=green:s=320x180:r=25:d=4', '-c:v', 'libx264', '-preset', 'ultrafast', '-pix_fmt', 'yuv420p', '-an', part]);
      const job = await startBlur(source, 'video/mp4;codecs=avc1.42E01E') as BlurJob;
      expect(job.output).toBe(join(folder, 'blur', 'archive-昵称打码.mp4'));
      expect(await writeBlur(job.jobId, await readFile(part))).toBe(true);
      const output = await endBlur(job.jobId);
      expect(output).toBe(job.output);
      expect(await decodeCheck(output as string)).toBe('');
      const probe = await probeText(output as string);
      expect(probe).toContain('Video: h264');
      expect(probe).toContain('Audio: aac');
      expect(await probeDuration(output as string)).toBeCloseTo(4, 0);
      const pixel = await pixelAt(output as string, folder, 10, 10);
      expect(pixel[1]).toBeGreaterThan(100);
      expect(pixel[0]).toBeLessThan(80);
    });
  });

  it('取消后不产出文件', async () => {
    await withTempDir('s3rBlurCancel', async (folder) => {
      await mkdir(blurPath, { recursive: true });
      const source = join(folder, 'archive.mp4');
      await createMedia(source, { duration: 2, width: 320, height: 180, fps: 25, audio: true });
      const job = await startBlur(source, 'video/mp4;codecs=avc1') as BlurJob;
      await writeBlur(job.jobId, Buffer.from([0, 0, 0, 1]));
      await cancelBlur(job.jobId);
      expect(await endBlur(job.jobId)).toBeUndefined();
      await expect(stat(job.output)).rejects.toThrow();
    });
  });

  it('多路打码任务各写各的分片互不干扰', async () => {
    await withTempDir('s3rBlurMulti', async (folder) => {
      await mkdir(blurPath, { recursive: true });
      const first = join(folder, 'first.mp4');
      const second = join(folder, 'second.mp4');
      await createMedia(first, { duration: 2, width: 320, height: 180, fps: 25, audio: true });
      await createMedia(second, { duration: 2, width: 320, height: 180, fps: 25, audio: true });
      const part = join(folder, 'part.mp4');
      await runFFmpeg(['-v', 'error', '-f', 'lavfi', '-i', 'color=c=green:s=320x180:r=25:d=2', '-c:v', 'libx264', '-preset', 'ultrafast', '-pix_fmt', 'yuv420p', '-an', part]);
      const one = await startBlur(first, 'video/mp4;codecs=avc1.42E01E') as BlurJob;
      const two = await startBlur(second, 'video/mp4;codecs=avc1.42E01E') as BlurJob;
      expect(one.jobId).not.toBe(two.jobId);
      const chunk = await readFile(part);
      expect(await Promise.all([writeBlur(one.jobId, chunk), writeBlur(two.jobId, chunk)])).toEqual([true, true]);
      const [outOne, outTwo] = await Promise.all([endBlur(one.jobId, false), endBlur(two.jobId, false)]);
      expect(outOne).toBe(one.output);
      expect(outTwo).toBe(two.output);
      expect(await decodeCheck(outOne as string)).toBe('');
      expect(await decodeCheck(outTwo as string)).toBe('');
    });
  });
});

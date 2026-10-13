import { describe, expect, it } from 'vitest';
import { parseModes } from '../src/main/capture/modes.js';

const sample = [
  '[in#0 @ 0000] DirectShow video device options (from video devices)',
  '[in#0 @ 0000]  Pin "捕获" (alternative pin name "0")',
  '[in#0 @ 0000]   pixel_format=nv12  min s=1920x1080 fps=24 max s=1920x1080 fps=60.0002',
  '[in#0 @ 0000]   pixel_format=nv12  min s=1920x1080 fps=24 max s=1920x1080 fps=60.0002 (tv, bt709/bt709/unknown, topleft)',
  '[in#0 @ 0000]   pixel_format=nv12  min s=3840x2160 fps=24 max s=3840x2160 fps=30',
  '[in#0 @ 0000]   pixel_format=yuyv422  min s=1280x720 fps=50 max s=1280x720 fps=60.0002',
  '[in#0 @ 0000]   pixel_format=mjpeg  min s=1920x1080 fps=30 max s=1920x1080 fps=30',
  'Error opening input file video=test.',
].join('\n');

describe('parseModes', () => {
  it('解析 NV12 与 YUY2 档位并去重', () => {
    expect(parseModes(sample)).toEqual([
      { format: 'nv12', width: 1920, height: 1080, minFps: 24, maxFps: 60 },
      { format: 'nv12', width: 3840, height: 2160, minFps: 24, maxFps: 30 },
      { format: 'yuy2', width: 1280, height: 720, minFps: 50, maxFps: 60 },
    ]);
  });

  it('忽略无关格式与错误输出', () => {
    expect(parseModes('Error opening input file video=test.')).toEqual([]);
    expect(parseModes('')).toEqual([]);
  });
});

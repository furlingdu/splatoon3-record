import { describe, expect, it } from 'vitest';
import { buildLadder, qualityArgs, rateArgs } from '../src/main/media/accel.js';

describe('videotoolbox 编码参数', () => {
  it('质量档按 18 到 28 反向映射到 80 到 45', () => {
    expect(qualityArgs('hevc_videotoolbox', 18).join(' ')).toContain('-q:v 80');
    expect(qualityArgs('hevc_videotoolbox', 22).join(' ')).toContain('-q:v 66');
    expect(qualityArgs('hevc_videotoolbox', 28).join(' ')).toContain('-q:v 45');
    expect(qualityArgs('h264_videotoolbox', 22).join(' ')).toContain('-q:v 66');
  });

  it('质量档不使用 CQP 参数并夹在 1 到 100', () => {
    const args = qualityArgs('hevc_videotoolbox', 22).join(' ');
    expect(args).not.toContain('-qp');
    expect(args).not.toContain('crf');
    expect(qualityArgs('hevc_videotoolbox', 0).join(' ')).toContain('-q:v 100');
    expect(qualityArgs('hevc_videotoolbox', 60).join(' ')).toContain('-q:v 1');
  });

  it('码率档带上限与缓冲', () => {
    const args = rateArgs('hevc_videotoolbox', 8000000).join(' ');
    expect(args).toContain('-b:v 8000000');
    expect(args).toContain('-maxrate 8000000');
    expect(args).toContain('-bufsize 16000000');
  });
});

describe('videotoolbox 进入硬件阶梯', () => {
  it('自动档把 videotoolbox 排在厂商编码之后、Vulkan 之前', () => {
    const ladder = buildLadder([], ['h264_nvenc', 'h264_videotoolbox', 'h264_vulkan'], { kind: 'quality', quality: 22 }, 'h264');
    const labels = ladder.map((rung) => rung.encode);
    expect(labels.indexOf('h264_videotoolbox')).toBeGreaterThan(labels.indexOf('h264_nvenc'));
    expect(labels.indexOf('h264_vulkan')).toBeGreaterThan(labels.indexOf('h264_videotoolbox'));
  });

  it('videotoolbox 编码档不带 Vulkan 上传参数', () => {
    const ladder = buildLadder([], ['hevc_videotoolbox'], { kind: 'quality', quality: 22 }, 'hevc');
    const rung = ladder.find((item) => item.encode === 'hevc_videotoolbox');
    expect(rung?.encodeArgs.join(' ')).not.toContain('hwupload');
    expect(rung?.encodeArgs.join(' ')).toContain('-q:v');
  });

  it('videotoolbox 解码档能参与阶梯并保留软件兜底', () => {
    const ladder = buildLadder(['videotoolbox'], [], { kind: 'quality', quality: 22 }, 'hevc');
    expect(ladder.some((rung) => rung.decode === 'videotoolbox')).toBe(true);
    expect(ladder.at(-1)?.encode).toBe('libx265');
  });
});

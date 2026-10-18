import { describe, expect, it, vi } from 'vitest';

const probeState = vi.hoisted(() => ({
  calls: [] as { args: string[]; timeoutMs?: number }[],
  result: { code: 0, output: '' },
}));

vi.mock('../src/main/media/ffmpeg.js', () => ({
  runCommand: async (args: string[], timeoutMs?: number) => {
    probeState.calls.push({ args, timeoutMs });
    return probeState.result;
  },
}));

import { makeVideoUrl, parseVideoUrl, probeAudio } from '../src/main/media/video.js';

describe('makeVideoUrl', () => {
  it('生成受限协议地址', () => {
    expect(makeVideoUrl('vs-100')).toBe('s3r-video://match/vs-100');
  });
});

describe('parseVideoUrl', () => {
  it('解析合法对局地址', () => {
    expect(parseVideoUrl('s3r-video://match/vs-100')).toBe('vs-100');
  });

  it('支持真实对局 ID 的等号填充', () => {
    expect(parseVideoUrl(makeVideoUrl('abc==' ))).toBe('abc==');
  });

  it('支持账户级复合键', () => {
    expect(parseVideoUrl(makeVideoUrl('1001:abc=='))).toBe('1001:abc==');
  });

  it('拒绝其他协议与外部主机', () => {
    expect(parseVideoUrl('file:///vs100.mp4')).toBeUndefined();
    expect(parseVideoUrl('s3r-video://other/vs-100')).toBeUndefined();
  });

  it('拒绝路径穿越', () => {
    expect(parseVideoUrl('s3r-video://match/..%2Fsecret')).toBeUndefined();
  });

  it('拒绝损坏的地址', () => {
    expect(parseVideoUrl('not a url')).toBeUndefined();
    expect(parseVideoUrl('s3r-video://match/vs-100?x=1')).toBeUndefined();
  });
});

describe('probeAudio', () => {
  it('只读取首个音频包并使用短超时，不解码整段音轨', async () => {
    probeState.calls.length = 0;
    probeState.result = { code: 0, output: '' };
    expect(await probeAudio('long-segment.mp4')).toBe(true);
    expect(probeState.calls).toHaveLength(1);
    expect(probeState.calls[0].args).toContain('-frames:a');
    expect(probeState.calls[0].args).toContain('1');
    expect(probeState.calls[0].args).toContain('-c:a');
    expect(probeState.calls[0].args).toContain('copy');
    expect(probeState.calls[0].args.slice(-3)).toEqual(['-f', 'null', '-']);
    expect(probeState.calls[0].timeoutMs).toBe(5000);
  });

  it('只有明确不存在音轨才返回无声', async () => {
    probeState.result = { code: 1, output: "Stream map '0:a:0' matches no streams." };
    expect(await probeAudio('silent.mp4')).toBe(false);
  });

  it('超时和读取错误不能误判为无声', async () => {
    probeState.result = { code: -1, output: '' };
    await expect(probeAudio('busy.mp4')).rejects.toThrow('音轨探测失败或超时');
    probeState.result = { code: 1, output: 'Invalid data found when processing input' };
    await expect(probeAudio('broken.mp4')).rejects.toThrow('无法读取分段音轨');
  });
});

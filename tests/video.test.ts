import { describe, expect, it } from 'vitest';
import { makeVideoUrl, parseVideoUrl } from '../src/main/media/video.js';

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

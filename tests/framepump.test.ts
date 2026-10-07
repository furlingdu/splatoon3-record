import { afterEach, describe, expect, it, vi } from 'vitest';
import { createFramePump } from '../src/renderer/lib/framepump.js';

const stops: (() => void)[] = [];

afterEach(() => {
  for (const stop of stops.splice(0)) stop();
  vi.unstubAllGlobals();
});

describe('createFramePump', () => {
  it('每个采集帧恰好出画一次，不受显示器刷新率影响', async () => {
    const frames: { close: ReturnType<typeof vi.fn> }[] = [];
    const queue: { value: { close: ReturnType<typeof vi.fn> }; done: false }[] = [];
    let wake: ((value: ReadableStreamReadResult<VideoFrame>) => void) | undefined;
    const reader = {
      read: vi.fn(() => new Promise<ReadableStreamReadResult<VideoFrame>>((resolve) => {
        const item = queue.shift();
        if (item) resolve(item as unknown as ReadableStreamReadResult<VideoFrame>);
        else wake = resolve;
      })),
      cancel: vi.fn(async () => { wake?.({ done: true, value: undefined }); }),
    };
    const clone = { stop: vi.fn() };
    const track = { readyState: 'live', clone: vi.fn(() => clone) } as unknown as MediaStreamTrack;
    class MockProcessor {
      readable = { getReader: () => reader };
    }
    const output = vi.fn();
    vi.stubGlobal('MediaStreamTrackProcessor', MockProcessor);
    vi.stubGlobal('requestAnimationFrame', vi.fn(() => { throw new Error('直播不得依赖显示器刷新'); }));
    const stop = createFramePump(() => track, () => undefined, () => 60, output);
    stops.push(stop);
    for (let index = 0; index < 60; index += 1) {
      const frame = { close: vi.fn() };
      frames.push(frame);
      const item = { done: false as const, value: frame };
      if (wake) {
        const resolve = wake;
        wake = undefined;
        resolve(item as unknown as ReadableStreamReadResult<VideoFrame>);
      } else queue.push(item);
      await vi.waitFor(() => expect(output).toHaveBeenCalledTimes(index + 1));
    }
    expect(frames.every((frame) => frame.close.mock.calls.length === 1)).toBe(true);
    stop();
    expect(reader.cancel).toHaveBeenCalledOnce();
    expect(clone.stop).toHaveBeenCalledOnce();
  });

  it('缺少轨道处理器时用实际视频帧回调，不由显示刷新驱动', () => {
    vi.stubGlobal('MediaStreamTrackProcessor', undefined);
    const callbacks: (() => void)[] = [];
    const cancel = vi.fn();
    const video = {
      readyState: 4,
      requestVideoFrameCallback: vi.fn((callback: () => void) => callbacks.push(callback)),
      cancelVideoFrameCallback: cancel,
    } as unknown as HTMLVideoElement;
    const track = { readyState: 'live' } as MediaStreamTrack;
    const output = vi.fn();
    const stop = createFramePump(() => track, () => video, () => 60, output);
    stops.push(stop);
    for (let index = 0; index < 60; index += 1) callbacks[index]();
    expect(output).toHaveBeenCalledTimes(60);
    stop();
    expect(cancel).toHaveBeenCalled();
  });
});

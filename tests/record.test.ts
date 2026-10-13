import { afterEach, describe, expect, it, vi } from 'vitest';
import type { SegmentDraft } from '../src/shared/types.js';

const state = vi.hoisted(() => ({
  queue: [] as number[],
  created: [] as { at: number; firstUs: number }[],
  drafts: [] as SegmentDraft[],
}));

vi.mock('../src/renderer/lib/segment.js', () => ({
  SegmentEncoder: {
    open: async () => {
      const at = Date.now();
      const firstUs = state.queue.shift() ?? 0;
      state.created.push({ at, firstUs });
      return {
        info: () => ({ codec: 'hevc', ext: 'mp4', mime: 'video/mp4;codecs=hvc1', hardware: true }),
        close: async () => undefined,
        firstTimestamp: () => firstUs,
      };
    },
  },
}));

vi.stubGlobal('window', {
  setTimeout: (callback: () => void, ms: number) => globalThis.setTimeout(callback, ms),
  clearTimeout: (handle: number) => globalThis.clearTimeout(handle),
  recordApi: {
    writeChunk: async () => true,
    writeSegment: async (draft: SegmentDraft) => {
      state.drafts.push(draft);
      return undefined;
    },
  },
});

import { startRecord, stopRecord } from '../src/renderer/lib/record.js';

afterEach(async () => {
  await stopRecord().catch(() => undefined);
  vi.useRealTimers();
});

describe('recordSegment', () => {
  it('每段起点用首帧时间戳锚定，轮转边界沿用同一采集时间轴', async () => {
    vi.useFakeTimers();
    vi.setSystemTime(1000000);
    state.queue.push(5000000);
    state.queue.push(35011000);
    const track = {
      readyState: 'live',
      getSettings: () => ({ width: 1280, height: 720, frameRate: 60 }),
    } as unknown as MediaStreamTrack;
    const stream = { getVideoTracks: () => [track], getAudioTracks: () => [] } as unknown as MediaStream;

    await startRecord(stream);
    expect(state.created[0].at).toBe(1000000);
    expect(state.drafts.length).toBe(0);

    await vi.advanceTimersByTimeAsync(30000);
    expect(state.created[1].at).toBe(1030000);

    await vi.advanceTimersByTimeAsync(10000);
    await stopRecord();

    const drafts = [...state.drafts].sort((a, b) => a.startAt - b.startAt);
    expect(drafts.length).toBe(2);
    expect(drafts[0].startAt).toBe(1000000);
    expect(drafts[1].startAt).toBe(1030011);
    expect(drafts[0].endAt).toBe(drafts[1].startAt + 1000);
    expect(drafts[1].startAt - drafts[0].startAt).toBe(30011);
  });
});

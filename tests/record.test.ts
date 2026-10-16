import { afterEach, describe, expect, it, vi } from 'vitest';
import type { SegmentSeal, SegmentSink, SegmentSpec } from '../src/renderer/lib/segment.js';
import type { SegmentDraft } from '../src/shared/types.js';

const state = vi.hoisted(() => ({
  opened: 0,
  rotated: 0,
  drafts: [] as SegmentDraft[],
}));

vi.mock('../src/renderer/lib/segment.js', () => ({
  SegmentRecorder: {
    open: async (_video: unknown, _audio: unknown, _quality: number, spec: SegmentSpec, sink: SegmentSink) => {
      state.opened += 1;
      const info = { codec: 'hevc', ext: 'mp4', mime: 'video/mp4;codecs=hvc1', hardware: true };
      return {
        info: () => info,
        firstTimestamp: () => 5000000,
        rotate: () => {
          state.rotated += 1;
          sink.onSeal({ id: 'sega', firstUs: 5000000, endUs: 35011000, spec, info } as SegmentSeal);
        },
        close: async () => {
          sink.onSeal({ id: 'segb', firstUs: 35011000, spec, info } as SegmentSeal);
        },
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

vi.stubGlobal('MediaStreamTrackProcessor', class {
  readable = { getReader: () => ({ read: () => new Promise<never>(() => undefined), cancel: async () => undefined }) };
});

import { startRecord, stopRecord } from '../src/renderer/lib/record.js';

function trackStub(): MediaStreamTrack {
  const track = {
    readyState: 'live',
    clone: () => trackStub(),
    stop: () => undefined,
    getSettings: () => ({ width: 1280, height: 720, frameRate: 60 }),
  };
  return track as unknown as MediaStreamTrack;
}

function streamStub(track: MediaStreamTrack): MediaStream {
  return { getVideoTracks: () => [track], getAudioTracks: () => [] } as unknown as MediaStream;
}

afterEach(async () => {
  await stopRecord().catch(() => undefined);
  state.opened = 0;
  state.rotated = 0;
  state.drafts = [];
  vi.useRealTimers();
});

describe('recordSegment', () => {
  it('整场只建一个编码器，按时长增量封存且分段首尾相接', async () => {
    vi.useFakeTimers();
    vi.setSystemTime(1000000);
    await startRecord(streamStub(trackStub()));
    expect(state.opened).toBe(1);
    expect(state.drafts.length).toBe(0);

    await vi.advanceTimersByTimeAsync(600000);
    await vi.advanceTimersByTimeAsync(0);
    expect(state.rotated).toBe(1);
    expect(state.opened).toBe(1);
    expect(state.drafts.length).toBe(1);
    expect(state.drafts[0].id).toBe('sega');
    expect(state.drafts[0].startAt).toBe(1000000);
    expect(state.drafts[0].endAt).toBe(1030011);

    await vi.advanceTimersByTimeAsync(10000);
    await stopRecord();
    expect(state.opened).toBe(1);
    expect(state.drafts.length).toBe(2);
    expect(state.drafts[1].id).toBe('segb');
    expect(state.drafts[1].startAt).toBe(state.drafts[0].endAt);
    expect(state.drafts[1].endAt).toBe(1610000);
  });
});

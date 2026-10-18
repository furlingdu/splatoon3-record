import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { SegmentSeal, SegmentSink, SegmentSpec } from '../src/renderer/lib/segment.js';

interface MuxRecord {
  options: unknown;
  video: Array<{ chunk: unknown; metadata: unknown }>;
  audio: Array<{ chunk: unknown; metadata: unknown }>;
  finalized: number;
}

const muxState = vi.hoisted(() => ({
  records: [] as MuxRecord[],
}));

vi.mock('mp4-muxer', () => {
  class MockStreamTarget {
    constructor(readonly options: unknown) {}
  }

  class MockMuxer {
    private readonly record: MuxRecord;

    constructor(options: unknown) {
      this.record = { options, video: [], audio: [], finalized: 0 };
      muxState.records.push(this.record);
    }

    addVideoChunk(chunk: unknown, metadata: unknown): void {
      this.record.video.push({ chunk, metadata });
    }

    addAudioChunk(chunk: unknown, metadata: unknown): void {
      this.record.audio.push({ chunk, metadata });
    }

    finalize(): void {
      this.record.finalized += 1;
    }
  }

  return { Muxer: MockMuxer, StreamTarget: MockStreamTarget };
});

import { SegmentRecorder as Recorder } from '../src/renderer/lib/segment.js';

interface EncodedChunkStub {
  timestamp: number;
  duration?: number;
  type?: string;
}

class ControlledReader<T> {
  private queue: T[] = [];
  private waiters: Array<(result: ReadableStreamReadResult<T>) => void> = [];
  private ended = false;

  read(): Promise<ReadableStreamReadResult<T>> {
    const value = this.queue.shift();
    if (value !== undefined) return Promise.resolve({ done: false, value });
    if (this.ended) return Promise.resolve({ done: true, value: undefined });
    return new Promise((resolve) => this.waiters.push(resolve));
  }

  push(value: T): void {
    const waiter = this.waiters.shift();
    if (waiter) waiter({ done: false, value });
    else this.queue.push(value);
  }

  cancel(): Promise<void> {
    this.ended = true;
    for (const waiter of this.waiters.splice(0)) waiter({ done: true, value: undefined });
    return Promise.resolve();
  }
}

const codecState = {
  video: [] as MockVideoEncoder[],
  audio: [] as MockAudioEncoder[],
  videoConfigs: [] as VideoEncoderConfig[],
  audioConfigs: [] as AudioEncoderConfig[],
  readers: [] as ControlledReader<AudioData>[],
};

class MockVideoEncoder {
  static async isConfigSupported(config: VideoEncoderConfig): Promise<{ supported: boolean; config: VideoEncoderConfig }> {
    codecState.videoConfigs.push({ ...config });
    return { supported: true, config };
  }

  readonly output: VideoEncoderInit['output'];
  readonly error: VideoEncoderInit['error'];
  state = 'unconfigured';
  encodeQueueSize = 0;
  config?: VideoEncoderConfig;
  encodeCount = 0;

  constructor(init: VideoEncoderInit) {
    this.output = init.output;
    this.error = init.error;
    codecState.video.push(this);
  }

  configure(config: VideoEncoderConfig): void {
    this.config = { ...config };
    this.state = 'configured';
  }

  encode(_frame: VideoFrame, _options?: VideoEncoderEncodeOptions): void {
    this.encodeCount += 1;
  }

  emit(chunk: EncodedChunkStub, metadata?: EncodedVideoChunkMetadata): void {
    this.output(chunk as unknown as EncodedVideoChunk, metadata);
  }

  flush(): Promise<void> {
    return Promise.resolve();
  }

  close(): void {
    this.state = 'closed';
  }
}

class MockAudioEncoder {
  static async isConfigSupported(config: AudioEncoderConfig): Promise<{ supported: boolean; config: AudioEncoderConfig }> {
    codecState.audioConfigs.push({ ...config });
    return { supported: true, config };
  }

  readonly output: AudioEncoderInit['output'];
  readonly error: AudioEncoderInit['error'];
  state = 'unconfigured';
  config?: AudioEncoderConfig;
  encodeCount = 0;

  constructor(init: AudioEncoderInit) {
    this.output = init.output;
    this.error = init.error;
    codecState.audio.push(this);
  }

  configure(config: AudioEncoderConfig): void {
    this.config = { ...config };
    this.state = 'configured';
  }

  encode(_data: AudioData): void {
    this.encodeCount += 1;
  }

  emit(chunk: EncodedChunkStub, metadata?: EncodedAudioChunkMetadata): void {
    this.output(chunk as unknown as EncodedAudioChunk, metadata);
  }

  flush(): Promise<void> {
    return Promise.resolve();
  }

  close(): void {
    this.state = 'closed';
  }
}

class MockProcessor<T> {
  readonly readable: { getReader: () => ControlledReader<T> };

  constructor(_init: { track: MediaStreamTrack }) {
    const reader = codecState.readers.shift();
    if (!reader) throw new Error('没有准备可控的媒体 reader');
    this.readable = { getReader: () => reader as unknown as ControlledReader<T> };
  }
}

class TestFeed {
  private callback?: (frame: VideoFrame) => void;
  private resolveSubscribed!: () => void;
  readonly subscribed = new Promise<void>((resolve) => {
    this.resolveSubscribed = resolve;
  });

  subscribe(callback: (frame: VideoFrame) => void): () => void {
    this.callback = callback;
    this.resolveSubscribed();
    return (): void => {
      this.callback = undefined;
    };
  }

  push(timestamp: number): void {
    const callback = this.callback;
    if (!callback) throw new Error('视频 feed 尚未订阅');
    callback({ timestamp, close: () => undefined } as unknown as VideoFrame);
  }

  stop(): void {
    this.callback = undefined;
  }
}

interface Harness {
  recorder: Recorder;
  feed: TestFeed;
  audioReader?: ControlledReader<AudioData>;
  videoEncoder: MockVideoEncoder;
  audioEncoder?: MockAudioEncoder;
  seals: SegmentSeal[];
}

const spec: SegmentSpec = { width: 1280, height: 720, fps: 60, hasAudio: true };

function installGlobals(): void {
  vi.stubGlobal('window', {
    setTimeout: globalThis.setTimeout,
    clearTimeout: globalThis.clearTimeout,
    setInterval: globalThis.setInterval,
    clearInterval: globalThis.clearInterval,
  });
  vi.stubGlobal('VideoEncoder', MockVideoEncoder);
  vi.stubGlobal('AudioEncoder', MockAudioEncoder);
  vi.stubGlobal('MediaStreamTrackProcessor', MockProcessor);
}

function audioTrack(): MediaStreamTrack {
  return { readyState: 'live' } as unknown as MediaStreamTrack;
}

function videoTrack(): MediaStreamTrack {
  return { readyState: 'live' } as unknown as MediaStreamTrack;
}

function audioData(timestamp: number): AudioData {
  return {
    timestamp,
    duration: 10000,
    numberOfFrames: 480,
    numberOfChannels: 2,
    sampleRate: 48000,
    close: () => undefined,
  } as unknown as AudioData;
}

function encodedChunk(timestamp: number): EncodedChunkStub {
  return { timestamp, duration: 21333, type: 'key' };
}

async function flushMicrotasks(count = 12): Promise<void> {
  for (let index = 0; index < count; index += 1) await Promise.resolve();
}

async function openHarness(withAudio = true): Promise<Harness> {
  const feed = new TestFeed();
  const seals: SegmentSeal[] = [];
  const sink: SegmentSink = {
    onError: vi.fn(),
    onData: vi.fn(),
    onSeal: (seal) => seals.push(seal),
    onRotate: vi.fn(),
    onAudio: vi.fn(),
    onFatal: vi.fn(),
  };
  let audioReader: ControlledReader<AudioData> | undefined;
  if (withAudio) {
    const probeReader = new ControlledReader<AudioData>();
    probeReader.push(audioData(0));
    audioReader = new ControlledReader<AudioData>();
    codecState.readers.push(probeReader, audioReader);
  }
  const opened = Recorder.open(videoTrack(), withAudio ? audioTrack() : undefined, 22, spec, sink, feed);
  await feed.subscribed;
  feed.push(0);
  const recorder = await opened;
  await flushMicrotasks();
  const videoEncoder = codecState.video[codecState.video.length - 1];
  if (!videoEncoder) throw new Error('视频 encoder 未建立');
  const audioEncoder = withAudio ? codecState.audio[codecState.audio.length - 1] : undefined;
  if (withAudio && !audioEncoder) throw new Error('音频 encoder 未建立');
  return { recorder, feed, audioReader, videoEncoder, audioEncoder, seals };
}

async function pushAudio(reader: ControlledReader<AudioData>, timestamp: number): Promise<void> {
  reader.push(audioData(timestamp));
  await flushMicrotasks();
}

function emitVideo(harness: Harness, timestamp: number): void {
  harness.videoEncoder.emit({ timestamp, type: 'key' });
}

function emitAudio(harness: Harness, timestamp: number): void {
  const encoder = harness.audioEncoder;
  if (!encoder) throw new Error('音频 encoder 未建立');
  encoder.emit(encodedChunk(timestamp));
}

beforeEach(() => {
  vi.useFakeTimers();
  vi.setSystemTime(1000000);
  muxState.records.length = 0;
  codecState.video.length = 0;
  codecState.audio.length = 0;
  codecState.videoConfigs.length = 0;
  codecState.audioConfigs.length = 0;
  codecState.readers.length = 0;
  installGlobals();
});

afterEach(() => {
  vi.unstubAllGlobals();
  vi.useRealTimers();
});

describe('SegmentRecorder WebCodecs 分段协调', () => {
  it('视频 encoder 配置使用目标帧率与 realtime 延迟模式', async () => {
    const harness = await openHarness(false);
    try {
      expect(harness.videoEncoder.config).toMatchObject({ framerate: 60, latencyMode: 'realtime' });
      emitVideo(harness, 0);
    } finally {
      await harness.recorder.close();
    }
  });

  it('音频按 chunk timestamp 路由，480 样本输入对应的多个 AAC 输出全部保留', async () => {
    const harness = await openHarness(true);
    try {
      emitVideo(harness, 0);
      const reader = harness.audioReader;
      if (!reader) throw new Error('音频 reader 未建立');
      await pushAudio(reader, 0);
      await pushAudio(reader, 10000);
      await pushAudio(reader, 20000);
      emitAudio(harness, 0);
      emitAudio(harness, 21333);
      expect(codecState.audio[0]?.encodeCount).toBe(3);
      expect(muxState.records[0]?.audio).toHaveLength(2);
      expect(muxState.records[0]?.audio.map((item) => (item.chunk as EncodedChunkStub).timestamp)).toEqual([0, 21333]);
    } finally {
      await harness.recorder.close();
    }
  });

  it('多次 rotate 且超过 sealWaitMs 后，新段仍持续接收延迟 AAC 音频', async () => {
    const harness = await openHarness(true);
    try {
      emitVideo(harness, 0);
      const reader = harness.audioReader;
      if (!reader) throw new Error('音频 reader 未建立');
      await pushAudio(reader, 0);
      emitAudio(harness, 0);

      for (let round = 1; round <= 4; round += 1) {
        harness.recorder.rotate();
        const videoTs = round * 100000;
        harness.feed.push(videoTs);
        emitVideo(harness, videoTs);
        const base = (round - 1) * 100000;
        await pushAudio(reader, base + 20000);
        emitAudio(harness, base + 20000);
        await vi.advanceTimersByTimeAsync(1000);
        await pushAudio(reader, base + 40000);
        emitAudio(harness, base + 40000);
        await vi.advanceTimersByTimeAsync(1100);
        await pushAudio(reader, base + 60000);
        emitAudio(harness, base + 60000);
      }

      await vi.advanceTimersByTimeAsync(2100);
      expect(muxState.records.length).toBeGreaterThanOrEqual(5);
      expect(muxState.records.slice(0, -1).every((record) => record.finalized === 1)).toBe(true);
      expect(muxState.records.slice(0, -1).every((record) => record.audio.length > 0)).toBe(true);
      expect(harness.seals.filter((seal) => seal.spec.hasAudio).length).toBeGreaterThanOrEqual(4);
    } finally {
      await harness.recorder.close();
    }
  });

  it('视频输出仍 pending 时，超时不会提前封存该段', async () => {
    const harness = await openHarness(false);
    try {
      emitVideo(harness, 0);
      harness.recorder.rotate();
      harness.feed.push(100000);
      emitVideo(harness, 100000);
      harness.feed.push(150000);
      harness.recorder.rotate();
      harness.feed.push(200000);

      await vi.advanceTimersByTimeAsync(2100);
      expect(muxState.records[1]?.finalized).toBe(0);
      expect(harness.seals.some((seal) => seal.endUs === 200000)).toBe(false);

      emitVideo(harness, 150000);
      emitVideo(harness, 200000);
      expect(muxState.records[1]?.finalized).toBe(1);
      expect(harness.seals.some((seal) => seal.endUs === 200000)).toBe(true);
    } finally {
      await harness.recorder.close();
    }
  });

  it('videoHealth 统计输入、编码、丢弃与队列峰值', async () => {
    const harness = await openHarness(false);
    try {
      emitVideo(harness, 0);
      harness.videoEncoder.encodeQueueSize = 9;
      harness.feed.push(33333);
      harness.videoEncoder.encodeQueueSize = 0;
      harness.feed.push(66666);
      emitVideo(harness, 66666);
      expect(harness.recorder.videoHealth()).toEqual({ inputFrames: 3, encodedFrames: 2, droppedFrames: 1, queuePeak: 9 });
    } finally {
      await harness.recorder.close();
    }
  });
});

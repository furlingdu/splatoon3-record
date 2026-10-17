import { Muxer, StreamTarget } from 'mp4-muxer';
import { recordAudioBps, recordFallbackBps } from '../../shared/bitrate.js';
import { videoCodecs } from './encode.js';
import type { VideoFeed } from './videofeed.js';

export interface SegmentSpec {
  width: number;
  height: number;
  fps: number;
  hasAudio: boolean;
}

export interface SegmentInfo {
  codec: string;
  ext: string;
  mime: string;
  hardware: boolean;
}

export interface SegmentSeal {
  id: string;
  firstUs: number;
  endUs?: number;
  spec: SegmentSpec;
  info: SegmentInfo;
}

export type AudioState = 'ok' | 'probe-failed' | 'lost' | 'recovered';

export interface SegmentSink {
  onError: (message: string) => void;
  onData: (id: string, data: Uint8Array, position: number) => void;
  onSeal: (seal: SegmentSeal) => void;
  onRotate: () => void;
  onAudio?: (state: AudioState, detail?: string) => void;
}

interface VideoChoice {
  codec: string;
  muxer: 'avc' | 'hevc';
  config: VideoEncoderConfig;
}

interface AudioChoice {
  codec: 'aac' | 'opus';
  channels: number;
  sampleRate: number;
}

interface FileRun {
  id: string;
  muxer: Muxer<StreamTarget>;
  firstUs?: number;
  endUs?: number;
  pendingVideo: number;
  pendingAudio: number;
  chunks: number;
  audioChunks: number;
  bytes: number;
  retired: boolean;
  sealed: boolean;
  timer?: number;
}

const keyframeGapUs = 2000000;
const queueLimit = 8;
const audioWaitMs = 1000;
const audioProbeAttempts = 3;
const audioProbeWaitMs = 2000;
const audioRetryMs = 500;
const firstFrameWaitMs = 1000;
const sealWaitMs = 2000;
const nominalBps = 8000000;
const partChunkSize = 1 << 20;
const fileByteLimit = 3 * 1024 * 1024 * 1024;

export class SegmentRecorder {
  private files = new Map<string, FileRun>();
  private current!: FileRun;
  private boundary?: FileRun;
  private audioChoice?: AudioChoice;
  private audioTrack?: MediaStreamTrack;
  private audioRuns = new Map<AudioEncoder, string[]>();
  private audioLost = false;
  private videoQueue: string[] = [];
  private videoEncoder?: VideoEncoder;
  private audioEncoder?: AudioEncoder;
  private videoConfig?: VideoDecoderConfig;
  private audioConfig?: AudioDecoderConfig;
  private audioReader?: ReadableStreamDefaultReader<AudioData>;
  private release?: () => void;
  private pumping = true;
  private closed = false;
  private dropped = false;
  private pendingKey = true;
  private lastKeyAt = 0;
  private chunks = 0;
  private counter = 0;
  private firstUs?: number;
  private firstWaiter?: () => void;
  private firstTimer?: number;

  private constructor(private choice: VideoChoice, private spec: SegmentSpec, private sink: SegmentSink) {}

  static async open(video: MediaStreamTrack, audio: MediaStreamTrack | undefined, quality: number, spec: SegmentSpec, sink: SegmentSink, feed?: VideoFeed): Promise<SegmentRecorder> {
    const choice = await chooseVideo(spec, quality);
    if (!choice) throw new Error('当前系统不支持可用的录制编码格式');
    const probe = audio ? await probeAudio(audio) : undefined;
    const recorder = new SegmentRecorder(choice, spec, sink);
    recorder.audioChoice = probe;
    recorder.openFile();
    recorder.startVideo();
    if (feed) recorder.release = feed.subscribe((frame) => recorder.pushFrame(frame));
    if (audio && probe) {
      sink.onAudio?.('ok');
      recorder.startAudio(audio, probe);
    } else if (audio) {
      sink.onAudio?.('probe-failed', '音频探测超时');
      recorder.startProbeRetry(audio);
    }
    await recorder.waitFirstFrame();
    return recorder;
  }

  firstTimestamp(): number | undefined {
    return this.firstUs;
  }

  waitFirstFrame(): Promise<void> {
    if (this.firstUs !== undefined) return Promise.resolve();
    return new Promise((resolve) => {
      const done = (): void => {
        if (this.firstTimer !== undefined) window.clearTimeout(this.firstTimer);
        this.firstTimer = undefined;
        this.firstWaiter = undefined;
        resolve();
      };
      this.firstTimer = window.setTimeout(done, firstFrameWaitMs);
      this.firstWaiter = done;
    });
  }

  info(): SegmentInfo {
    return { codec: this.choice.codec.split('.')[0] || this.choice.codec, ext: 'mp4', mime: `video/mp4;codecs=${this.choice.codec}`, hardware: this.choice.config.hardwareAcceleration === 'prefer-hardware' };
  }

  rotate(): void {
    if (this.closed || !this.pumping) return;
    const previous = this.current;
    if (previous.retired) return;
    previous.retired = true;
    this.boundary = previous;
    previous.timer = window.setTimeout(() => this.finish(previous), sealWaitMs);
    this.openFile();
    this.pendingKey = true;
    this.settle(previous);
    this.sink.onRotate();
  }

  pushFrame(frame: VideoFrame): void {
    if (this.closed || !this.pumping) return;
    if (this.current.bytes >= fileByteLimit) this.rotate();
    const file = this.current;
    if (this.firstUs === undefined) {
      this.firstUs = frame.timestamp;
      this.firstWaiter?.();
    }
    if (file.firstUs === undefined) file.firstUs = frame.timestamp;
    const encoder = this.videoEncoder;
    if (!encoder || encoder.state !== 'configured') return;
    if (encoder.encodeQueueSize > queueLimit) {
      this.dropped = true;
      return;
    }
    const key = this.pendingKey || this.dropped || this.lastKeyAt === 0 || frame.timestamp - this.lastKeyAt >= keyframeGapUs;
    if (this.pendingKey) {
      this.pendingKey = false;
      if (this.boundary) {
        this.boundary.endUs = frame.timestamp;
        this.boundary = undefined;
      }
    }
    if (key) {
      this.dropped = false;
      this.lastKeyAt = frame.timestamp;
    }
    try {
      encoder.encode(frame, { keyFrame: key });
    } catch (cause) {
      this.fail(cause);
      return;
    }
    file.pendingVideo += 1;
    this.videoQueue.push(file.id);
  }

  async close(): Promise<void> {
    if (this.closed) throw new Error('录制已经关闭');
    this.closed = true;
    this.release?.();
    this.release = undefined;
    this.firstWaiter?.();
    const reader = this.audioReader;
    this.audioReader = undefined;
    if (reader) void reader.cancel().catch(() => undefined);
    try {
      if (this.videoEncoder?.state === 'configured') await this.videoEncoder.flush();
      if (this.audioEncoder?.state === 'configured') await this.audioEncoder.flush();
    } catch (cause) {
      this.fail(cause);
    }
    this.pumping = false;
    this.audioTrack = undefined;
    this.audioRuns.clear();
    this.videoEncoder?.close();
    try {
      this.audioEncoder?.close();
    } catch {
      void 0;
    }
    for (const file of [...this.files.values()]) {
      file.retired = true;
      this.finish(file);
    }
    if (!this.chunks) throw new Error('录制没有画面数据');
  }

  private openFile(): FileRun {
    this.counter += 1;
    const id = `seg${Date.now().toString(36)}${this.counter.toString(36)}`.toLowerCase();
    const audio = this.audioChoice;
    const sink = this.sink;
    const run: FileRun = {
      id,
      muxer: new Muxer({
        target: new StreamTarget({ onData: (data, position) => {
          run.bytes = Math.max(run.bytes, position + data.byteLength);
          sink.onData(id, data, position);
        }, chunked: true, chunkSize: partChunkSize }),
        video: { codec: this.choice.muxer, width: Math.max(2, this.spec.width), height: Math.max(2, this.spec.height), frameRate: Math.max(1, this.spec.fps) },
        audio: audio ? { codec: audio.codec, numberOfChannels: audio.channels, sampleRate: audio.sampleRate } : undefined,
        fastStart: 'fragmented',
        firstTimestampBehavior: 'offset',
      }),
      pendingVideo: 0,
      pendingAudio: 0,
      chunks: 0,
      audioChunks: 0,
      bytes: 0,
      retired: false,
      sealed: false,
    };
    this.files.set(id, run);
    this.current = run;
    return run;
  }

  private settle(file: FileRun): void {
    if (!file.retired || file.pendingVideo > 0 || file.pendingAudio > 0) return;
    this.finish(file);
  }

  private finish(file: FileRun): void {
    if (file.sealed) return;
    file.sealed = true;
    if (file.timer !== undefined) {
      window.clearTimeout(file.timer);
      file.timer = undefined;
    }
    this.files.delete(file.id);
    if (!file.chunks) return;
    file.muxer.finalize();
    this.sink.onSeal({ id: file.id, firstUs: file.firstUs ?? this.firstUs ?? 0, endUs: file.endUs, spec: { ...this.spec, hasAudio: file.audioChunks > 0 }, info: this.info() });
  }

  private startVideo(): void {
    const encoder = new VideoEncoder({
      output: (chunk, meta) => {
        if (!this.pumping) return;
        const id = this.videoQueue.shift();
        const file = id ? this.files.get(id) : undefined;
        if (!file) return;
        if (meta?.decoderConfig) this.videoConfig = meta.decoderConfig;
        file.pendingVideo -= 1;
        file.chunks += 1;
        this.chunks += 1;
        const info = file.chunks === 1 && !meta?.decoderConfig && this.videoConfig ? { ...meta, decoderConfig: this.videoConfig } : meta;
        file.muxer.addVideoChunk(chunk, info);
        this.settle(file);
      },
      error: (cause) => {
        resetVideoChoice();
        this.fail(cause);
      },
    });
    encoder.configure(this.choice.config);
    this.videoEncoder = encoder;
  }

  private startAudio(track: MediaStreamTrack, choice: AudioChoice): void {
    this.audioTrack = track;
    this.audioChoice = choice;
    this.audioEncoderFor(choice);
    void this.pumpAudio(choice);
  }

  private startProbeRetry(track: MediaStreamTrack): void {
    void this.retryProbe(track);
  }

  private async retryProbe(track: MediaStreamTrack): Promise<void> {
    while (!this.closed && this.pumping && !this.audioChoice) {
      await sleepMs(audioProbeWaitMs);
      if (this.closed || !this.pumping || track.readyState !== 'live') return;
      const choice = await probeAudio(track, 1);
      if (!choice) continue;
      this.audioChoice = choice;
      this.audioTrack = track;
      this.rotate();
      this.audioEncoderFor(choice);
      void this.pumpAudio(choice);
      this.sink.onAudio?.('recovered');
      return;
    }
  }

  private audioEncoderFor(choice: AudioChoice): AudioEncoder | undefined {
    const running = this.audioEncoder;
    if (running && running.state === 'configured') return running;
    if (running && running.state !== 'closed') {
      try {
        running.close();
      } catch {
        void 0;
      }
    }
    const queue: string[] = [];
    const encoder = new AudioEncoder({
      output: (chunk, meta) => {
        if (!this.pumping) return;
        const id = queue.shift();
        const file = id ? this.files.get(id) : undefined;
        if (!file) return;
        if (meta?.decoderConfig) this.audioConfig = meta.decoderConfig;
        file.pendingAudio -= 1;
        file.audioChunks += 1;
        const info = file.chunks === 0 && !meta?.decoderConfig && this.audioConfig ? { ...meta, decoderConfig: this.audioConfig } : meta;
        file.muxer.addAudioChunk(chunk, info);
        this.settle(file);
      },
      error: (cause) => {
        this.audioRuns.delete(encoder);
        this.noteAudioLost(errorText(cause));
      },
    });
    try {
      encoder.configure({ codec: choice.codec === 'aac' ? 'mp4a.40.2' : 'opus', sampleRate: choice.sampleRate, numberOfChannels: choice.channels, bitrate: recordAudioBps });
    } catch (cause) {
      this.noteAudioLost(errorText(cause));
      return undefined;
    }
    this.audioEncoder = encoder;
    this.audioRuns.set(encoder, queue);
    return encoder;
  }

  private async pumpAudio(choice: AudioChoice): Promise<void> {
    for (;;) {
      if (!this.pumping || this.closed) return;
      const track = this.audioTrack;
      if (!track || track.readyState !== 'live') {
        this.noteAudioLost('音频轨道已结束');
        return;
      }
      const reader = new MediaStreamTrackProcessor<AudioData>({ track }).readable.getReader();
      this.audioReader = reader;
      for (;;) {
        const step = await reader.read().catch(() => ({ done: true, value: undefined }) as ReadableStreamReadResult<AudioData>);
        if (!this.pumping || this.closed) {
          step.value?.close();
          return;
        }
        if (step.done || !step.value) break;
        const data = step.value;
        try {
          if (this.audioLost) this.reopenAudioFile();
          const encoder = this.audioEncoderFor(choice);
          const file = this.current;
          if (encoder && encoder.state === 'configured') {
            encoder.encode(data);
            file.pendingAudio += 1;
            this.audioRuns.get(encoder)?.push(file.id);
          }
        } catch (cause) {
          this.noteAudioLost(errorText(cause));
        } finally {
          data.close();
        }
      }
      this.audioReader = undefined;
      void reader.cancel().catch(() => undefined);
      if (!this.pumping || this.closed) return;
      this.noteAudioLost('音频数据流中断');
      await sleepMs(audioRetryMs);
    }
  }

  private reopenAudioFile(): void {
    this.audioLost = false;
    this.sink.onAudio?.('recovered');
    if (this.current.chunks > 0) this.rotate();
  }

  private noteAudioLost(detail: string): void {
    if (this.audioLost || this.closed || !this.pumping) return;
    this.audioLost = true;
    this.sink.onAudio?.('lost', detail);
  }

  private fail(cause: unknown): void {
    if (!this.pumping) return;
    this.sink.onError(errorText(cause));
  }
}

const choiceCache = new Map<string, VideoChoice>();

function choiceKey(spec: SegmentSpec, quality: number): string {
  return `${spec.width}x${spec.height}@${spec.fps}:${quality}`;
}

export function resetVideoChoice(): void {
  choiceCache.clear();
}

async function chooseVideo(spec: SegmentSpec, quality: number): Promise<VideoChoice | undefined> {
  const key = choiceKey(spec, quality);
  const cached = choiceCache.get(key);
  if (cached) return cached;
  for (const acceleration of ['prefer-hardware', 'no-preference'] as HardwareAcceleration[]) {
    for (const candidate of videoCodecs(spec.width, spec.height, spec.fps)) {
      for (const quantizer of [true, false]) {
        const config = videoConfig(candidate.codec, spec, quality, quantizer);
        const support = await VideoEncoder.isConfigSupported({ ...config, hardwareAcceleration: acceleration }).catch(() => undefined);
        if (support?.supported) {
          const choice: VideoChoice = { codec: candidate.codec, muxer: candidate.muxer, config: { ...config, hardwareAcceleration: acceleration } };
          choiceCache.set(key, choice);
          return choice;
        }
      }
    }
  }
  return undefined;
}

function videoConfig(codec: string, spec: SegmentSpec, quality: number, quantizer: boolean): VideoEncoderConfig {
  const base: VideoEncoderConfig = {
    codec,
    width: Math.max(2, spec.width),
    height: Math.max(2, spec.height),
    bitrate: nominalBps,
    latencyMode: 'quality',
  };
  if (codec.startsWith('avc')) base.avc = { format: 'avc' };
  if (quantizer) {
    base.bitrateMode = 'quantizer';
    base.quantizer = quality;
  } else {
    base.bitrateMode = 'variable';
    base.bitrate = recordFallbackBps(spec.width, spec.height);
  }
  return base;
}

async function probeAudio(track: MediaStreamTrack, attempts = audioProbeAttempts): Promise<AudioChoice | undefined> {
  if (typeof MediaStreamTrackProcessor === 'undefined' || typeof AudioEncoder === 'undefined') return undefined;
  for (let attempt = 0; attempt < attempts; attempt += 1) {
    if (track.readyState !== 'live') return undefined;
    const reader = new MediaStreamTrackProcessor<AudioData>({ track }).readable.getReader();
    const step = await Promise.race([
      reader.read().catch(() => ({ done: true, value: undefined }) as ReadableStreamReadResult<AudioData>),
      sleepMs(audioWaitMs).then(() => ({ done: true, value: undefined }) as ReadableStreamReadResult<AudioData>),
    ]);
    if (step.done || !step.value) {
      void reader.cancel().catch(() => undefined);
      continue;
    }
    const data = step.value;
    const channels = Math.max(1, Math.min(2, data.numberOfChannels));
    const sampleRate = data.sampleRate || 48000;
    data.close();
    void reader.cancel().catch(() => undefined);
    const codec = await pickAudioCodec(channels, sampleRate);
    if (codec) return { codec, channels, sampleRate };
  }
  return undefined;
}

async function pickAudioCodec(channels: number, sampleRate: number): Promise<'aac' | 'opus' | undefined> {
  const wanted: { codec: string; name: 'aac' | 'opus' }[] = [
    { codec: 'mp4a.40.2', name: 'aac' },
    { codec: 'opus', name: 'opus' },
  ];
  for (const item of wanted) {
    const support = await AudioEncoder.isConfigSupported({ codec: item.codec, sampleRate, numberOfChannels: channels, bitrate: recordAudioBps }).catch(() => undefined);
    if (support?.supported) return item.name;
  }
  return undefined;
}

function sleepMs(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function errorText(cause: unknown): string {
  const detail = cause as { message?: string; name?: string };
  return detail?.message || detail?.name || '录制编码中断';
}

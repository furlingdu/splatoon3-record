import { Muxer, StreamTarget } from 'mp4-muxer';
import { recordAudioBps, recordFallbackBps } from '../../shared/bitrate.js';

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
}

export interface SegmentSink {
  onError: (message: string) => void;
  onData: (data: Uint8Array, position: number) => void;
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

interface AudioProbe {
  reader: ReadableStreamDefaultReader<AudioData>;
  choice: AudioChoice;
}

interface VideoCandidate {
  codec: string;
  muxer: 'avc' | 'hevc';
}

const keyframeGapUs = 2000000;
const queueLimit = 8;
const audioWaitMs = 1000;
const nominalBps = 8000000;
const partChunkSize = 1 << 20;
const videoCandidates: VideoCandidate[] = [
  { codec: 'hvc1.1.6.L150.B0', muxer: 'hevc' },
  { codec: 'hev1.1.6.L150.B0', muxer: 'hevc' },
  { codec: 'avc1.640033', muxer: 'avc' },
  { codec: 'avc1.640028', muxer: 'avc' },
];

export class SegmentEncoder {
  private muxer!: Muxer<StreamTarget>;
  private videoEncoder?: VideoEncoder;
  private audioEncoder?: AudioEncoder;
  private videoReader?: ReadableStreamDefaultReader<VideoFrame>;
  private audioReader?: ReadableStreamDefaultReader<AudioData>;
  private pumping = true;
  private closed = false;
  private chunks = 0;
  private dropped = false;

  private constructor(private choice: VideoChoice, private spec: SegmentSpec, private sink: SegmentSink) {}

  static async open(video: MediaStreamTrack, audio: MediaStreamTrack | undefined, quality: number, spec: SegmentSpec, sink: SegmentSink): Promise<SegmentEncoder> {
    const choice = await chooseVideo(spec, quality);
    if (!choice) throw new Error('当前系统不支持可用的录制编码格式');
    const probe = audio ? await probeAudio(audio) : undefined;
    const encoder = new SegmentEncoder(choice, spec, sink);
    encoder.muxer = new Muxer({
      target: new StreamTarget({ onData: (data, position) => sink.onData(data, position), chunked: true, chunkSize: partChunkSize }),
      video: { codec: choice.muxer, width: Math.max(2, spec.width), height: Math.max(2, spec.height), frameRate: Math.max(1, spec.fps) },
      audio: probe ? { codec: probe.choice.codec, numberOfChannels: probe.choice.channels, sampleRate: probe.choice.sampleRate } : undefined,
      fastStart: 'fragmented',
      firstTimestampBehavior: 'offset',
    });
    encoder.startVideo(video);
    if (probe) encoder.startAudio(probe.reader, probe.choice);
    return encoder;
  }

  info(): SegmentInfo {
    return { codec: this.choice.codec.split('.')[0] || this.choice.codec, ext: 'mp4', mime: `video/mp4;codecs=${this.choice.codec}` };
  }

  async close(): Promise<void> {
    if (this.closed) throw new Error('分段已经关闭');
    this.closed = true;
    const readers = [this.videoReader, this.audioReader];
    this.videoReader = undefined;
    this.audioReader = undefined;
    for (const reader of readers) {
      if (reader) void reader.cancel().catch(() => undefined);
    }
    try {
      await this.videoEncoder?.flush();
      await this.audioEncoder?.flush();
    } catch (cause) {
      this.fail(cause);
    }
    this.pumping = false;
    this.videoEncoder?.close();
    this.audioEncoder?.close();
    if (!this.chunks) throw new Error('分段没有画面数据');
    this.muxer.finalize();
  }

  private startVideo(track: MediaStreamTrack): void {
    const encoder = new VideoEncoder({
      output: (chunk, meta) => {
        if (this.pumping) {
          this.chunks += 1;
          this.muxer.addVideoChunk(chunk, meta);
        }
      },
      error: (cause) => {
        resetVideoChoice();
        this.fail(cause);
      },
    });
    encoder.configure(this.choice.config);
    this.videoEncoder = encoder;
    const reader = new MediaStreamTrackProcessor<VideoFrame>({ track }).readable.getReader();
    this.videoReader = reader;
    void this.pumpVideo(reader);
  }

  private async pumpVideo(reader: ReadableStreamDefaultReader<VideoFrame>): Promise<void> {
    let lastKeyAt = 0;
    for (;;) {
      const step = await reader.read().catch(() => ({ done: true, value: undefined }) as ReadableStreamReadResult<VideoFrame>);
      if (step.done || !step.value) return;
      const frame = step.value;
      if (!this.pumping || this.closed) {
        frame.close();
        return;
      }
      const encoder = this.videoEncoder;
      if (!encoder || encoder.state !== 'configured') {
        frame.close();
        continue;
      }
      if (encoder.encodeQueueSize > queueLimit) {
        this.dropped = true;
        frame.close();
        continue;
      }
      const key = this.dropped || lastKeyAt === 0 || frame.timestamp - lastKeyAt >= keyframeGapUs;
      if (key) {
        this.dropped = false;
        lastKeyAt = frame.timestamp;
      }
      try {
        encoder.encode(frame, { keyFrame: key });
      } catch (cause) {
        frame.close();
        this.fail(cause);
        return;
      }
      frame.close();
    }
  }

  private startAudio(reader: ReadableStreamDefaultReader<AudioData>, choice: AudioChoice): void {
    const encoder = new AudioEncoder({
      output: (chunk, meta) => {
        if (this.pumping) this.muxer.addAudioChunk(chunk, meta);
      },
      error: (cause) => this.fail(cause),
    });
    encoder.configure({ codec: choice.codec === 'aac' ? 'mp4a.40.2' : 'opus', sampleRate: choice.sampleRate, numberOfChannels: choice.channels, bitrate: recordAudioBps });
    this.audioEncoder = encoder;
    this.audioReader = reader;
    void this.pumpAudio(reader, encoder);
  }

  private async pumpAudio(reader: ReadableStreamDefaultReader<AudioData>, encoder: AudioEncoder): Promise<void> {
    for (;;) {
      const step = await reader.read().catch(() => ({ done: true, value: undefined }) as ReadableStreamReadResult<AudioData>);
      if (step.done || !step.value) return;
      const data = step.value;
      if (!this.pumping || this.closed) {
        data.close();
        return;
      }
      try {
        if (encoder.state === 'configured') encoder.encode(data);
      } catch (cause) {
        data.close();
        this.fail(cause);
        return;
      }
      data.close();
    }
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
  for (const candidate of videoCandidates) {
    for (const acceleration of ['prefer-hardware', 'no-preference'] as HardwareAcceleration[]) {
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
    framerate: Math.max(1, spec.fps),
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

async function probeAudio(track: MediaStreamTrack): Promise<AudioProbe | undefined> {
  if (typeof MediaStreamTrackProcessor === 'undefined' || typeof AudioEncoder === 'undefined') return undefined;
  const reader = new MediaStreamTrackProcessor<AudioData>({ track }).readable.getReader();
  const step = await Promise.race([
    reader.read().catch(() => ({ done: true, value: undefined }) as ReadableStreamReadResult<AudioData>),
    sleepMs(audioWaitMs).then(() => ({ done: true, value: undefined }) as ReadableStreamReadResult<AudioData>),
  ]);
  if (step.done || !step.value) {
    void reader.cancel().catch(() => undefined);
    return undefined;
  }
  const data = step.value;
  const channels = Math.max(1, Math.min(2, data.numberOfChannels));
  const sampleRate = data.sampleRate || 48000;
  data.close();
  const codec = await pickAudioCodec(channels, sampleRate);
  if (!codec) {
    void reader.cancel().catch(() => undefined);
    return undefined;
  }
  return { reader, choice: { codec, channels, sampleRate } };
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

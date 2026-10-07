declare class MediaStreamTrackProcessor<T = AudioData> {
  constructor(init: { track: MediaStreamTrack });
  readonly readable: ReadableStream<T>;
}

interface VideoEncoderConfig {
  quantizer?: number;
}

interface Window {
  __monitor?: { on: boolean; state: string; bound: boolean };
}

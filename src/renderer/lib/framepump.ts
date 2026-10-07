type VideoFrameVideo = HTMLVideoElement & {
  requestVideoFrameCallback?: (callback: () => void) => number;
  cancelVideoFrameCallback?: (handle: number) => void;
};

export function createFramePump(
  getTrack: () => MediaStreamTrack | undefined,
  getVideo: () => HTMLVideoElement | undefined,
  getFps: () => number,
  onFrame: (source: CanvasImageSource) => void,
): () => void {
  let alive = true;
  let reader: ReadableStreamDefaultReader<VideoFrame> | undefined;
  let clone: MediaStreamTrack | undefined;
  let source: MediaStreamTrack | undefined;
  let video: VideoFrameVideo | undefined;
  let videoCallback = 0;
  let timer = 0;

  const clearTimer = (): void => {
    if (!timer) return;
    window.clearTimeout(timer);
    timer = 0;
  };

  const clearVideo = (): void => {
    if (video && videoCallback) video.cancelVideoFrameCallback?.(videoCallback);
    video = undefined;
    videoCallback = 0;
  };

  const clearCapture = (): void => {
    const current = reader;
    reader = undefined;
    source = undefined;
    const currentClone = clone;
    clone = undefined;
    if (current) void current.cancel().catch(() => undefined);
    currentClone?.stop();
    clearVideo();
  };

  const scheduleStart = (delay: number): void => {
    if (!alive || timer) return;
    timer = window.setTimeout(() => {
      timer = 0;
      start();
    }, Math.max(0, delay));
  };

  const pump = async (current: ReadableStreamDefaultReader<VideoFrame>, track: MediaStreamTrack): Promise<void> => {
    for (;;) {
      const step = await current.read().catch(() => ({ done: true, value: undefined }) as ReadableStreamReadResult<VideoFrame>);
      if (step.done || !step.value) break;
      const frame = step.value;
      if (!alive || reader !== current || source !== track || getTrack() !== track) {
        frame.close();
        break;
      }
      try {
        onFrame(frame);
      } finally {
        frame.close();
      }
    }
    if (alive && reader === current) {
      clearCapture();
      scheduleStart(0);
    }
  };

  const startVideo = (element: VideoFrameVideo, track: MediaStreamTrack): void => {
    video = element;
    const tick = (): void => {
      videoCallback = 0;
      if (!alive || video !== element || getTrack() !== track) {
        clearCapture();
        scheduleStart(0);
        return;
      }
      if (element.readyState >= 2) onFrame(element);
      videoCallback = element.requestVideoFrameCallback?.(tick) ?? 0;
    };
    videoCallback = element.requestVideoFrameCallback?.(tick) ?? 0;
  };

  const fallback = (element: HTMLVideoElement, track: MediaStreamTrack): void => {
    const tick = (): void => {
      timer = 0;
      if (!alive || getTrack() !== track) {
        clearCapture();
        scheduleStart(0);
        return;
      }
      if (element.readyState >= 2) onFrame(element);
      timer = window.setTimeout(tick, Math.max(1, 1000 / Math.max(1, getFps())));
    };
    timer = window.setTimeout(tick, 0);
  };

  const start = (): void => {
    if (!alive) return;
    clearCapture();
    const track = getTrack();
    if (!track || track.readyState !== 'live') {
      scheduleStart(250);
      return;
    }
    source = track;
    if (typeof MediaStreamTrackProcessor !== 'undefined') {
      try {
        clone = track.clone();
        reader = new MediaStreamTrackProcessor<VideoFrame>({ track: clone }).readable.getReader();
        void pump(reader, track);
        return;
      } catch {
        clearCapture();
      }
    }
    const element = getVideo() as VideoFrameVideo | undefined;
    if (!element) {
      scheduleStart(250);
      return;
    }
    if (typeof element.requestVideoFrameCallback === 'function') startVideo(element, track);
    else fallback(element, track);
  };

  const stop = (): void => {
    alive = false;
    clearTimer();
    clearCapture();
  };

  start();
  return stop;
}

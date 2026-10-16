export interface VideoFeed {
  subscribe(sink: (frame: VideoFrame) => void): () => void;
  stop: () => void;
}

export function openVideoFeed(track: MediaStreamTrack): VideoFeed {
  const sinks = new Set<(frame: VideoFrame) => void>();
  const clone = track.clone();
  const reader = new MediaStreamTrackProcessor<VideoFrame>({ track: clone }).readable.getReader();
  let alive = true;
  void (async () => {
    for (;;) {
      const step = await reader.read().catch(() => ({ done: true, value: undefined }) as ReadableStreamReadResult<VideoFrame>);
      if (!alive || step.done || !step.value) {
        step.value?.close();
        break;
      }
      const frame = step.value;
      for (const sink of sinks) {
        try {
          sink(frame);
        } catch {
          void 0;
        }
      }
      frame.close();
    }
  })();
  return {
    subscribe(sink: (frame: VideoFrame) => void): () => void {
      sinks.add(sink);
      return (): void => {
        sinks.delete(sink);
      };
    },
    stop: (): void => {
      alive = false;
      sinks.clear();
      void reader.cancel().catch(() => undefined);
      clone.stop();
    },
  };
}

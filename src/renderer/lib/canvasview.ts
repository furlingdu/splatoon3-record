export function directViewReady(): boolean {
  return typeof MediaStreamTrackProcessor !== 'undefined';
}

export function drawTrack(canvas: HTMLCanvasElement, track?: MediaStreamTrack): () => void {
  if (!track || track.readyState !== 'live' || !directViewReady()) return () => undefined;
  const context = canvas.getContext('2d', { desynchronized: true });
  if (!context) return () => undefined;
  const clone = track.clone();
  const reader = new MediaStreamTrackProcessor<VideoFrame>({ track: clone }).readable.getReader();
  let alive = true;
  void (async () => {
    for (;;) {
      const step = await reader.read().catch(() => ({ done: true, value: undefined }) as ReadableStreamReadResult<VideoFrame>);
      const frame = step.value;
      if (!alive || step.done || !frame) {
        frame?.close();
        break;
      }
      try {
        if (canvas.width !== frame.displayWidth || canvas.height !== frame.displayHeight) {
          canvas.width = frame.displayWidth;
          canvas.height = frame.displayHeight;
        }
        context.drawImage(frame, 0, 0, canvas.width, canvas.height);
      } finally {
        frame.close();
      }
    }
  })();
  return () => {
    alive = false;
    void reader.cancel().catch(() => undefined);
    clone.stop();
    context.clearRect(0, 0, canvas.width, canvas.height);
  };
}

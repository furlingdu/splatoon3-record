export function startPaint(paint: () => void, fps: number): () => void {
  const interval = fps > 0 ? 1000 / fps : 1000 / 60;
  let timer = 0;
  let next = performance.now();
  let alive = true;
  const tick = (): void => {
    if (!alive) return;
    const now = performance.now();
    if (now >= next) {
      paint();
      next += interval;
      if (next <= now) next = now + interval;
    }
    timer = window.setTimeout(tick, Math.max(0, next - performance.now()));
  };
  tick();
  return () => {
    alive = false;
    window.clearTimeout(timer);
  };
}

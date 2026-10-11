export function seedOrigin(origin: number | undefined, now: number, firstUs: number | undefined): number | undefined {
  if (origin !== undefined || firstUs === undefined || !Number.isFinite(firstUs)) return origin;
  return now - firstUs / 1000;
}

export function frameWall(origin: number | undefined, firstUs: number | undefined, fallback: number): number {
  if (origin === undefined || firstUs === undefined || !Number.isFinite(firstUs)) return fallback;
  return origin + firstUs / 1000;
}

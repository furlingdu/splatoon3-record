export interface ByteRange {
  start: number;
  end: number;
}

export function parseRange(header: string | null, size: number): ByteRange | undefined {
  if (!header || size <= 0) return undefined;
  const match = /^bytes=(\d*)-(\d*)$/.exec(header.trim());
  if (!match) return undefined;
  const startText = match[1];
  const endText = match[2];
  if (startText === '' && endText === '') return undefined;
  if (startText === '') {
    const suffix = Number(endText);
    if (!Number.isFinite(suffix) || suffix <= 0) return undefined;
    const start = Math.max(0, size - suffix);
    return { start, end: size - 1 };
  }
  const start = Number(startText);
  if (!Number.isFinite(start) || start < 0 || start >= size) return undefined;
  const end = endText === '' ? size - 1 : Math.min(Number(endText), size - 1);
  if (!Number.isFinite(end) || end < start) return undefined;
  return { start, end };
}

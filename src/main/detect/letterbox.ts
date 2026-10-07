import { detectBoxLimit } from '../../shared/constants.js';
import type { DetectBox } from '../../shared/types.js';

const padValue = 114;
const padFloat = padValue / 255;
const pool: Float32Array[] = [];

export interface LetterboxFrame {
  blob: Float32Array;
  scale: number;
  left: number;
  top: number;
}

export function releaseBlob(blob: Float32Array): void {
  if (pool.length < 8) pool.push(blob);
}

export function buildBlob(frame: Uint8Array, width: number, height: number, size: number): LetterboxFrame {
  const scale = Math.min(size / width, size / height);
  const innerWidth = Math.max(1, Math.round(width * scale));
  const innerHeight = Math.max(1, Math.round(height * scale));
  const left = Math.floor((size - innerWidth) / 2);
  const top = Math.floor((size - innerHeight) / 2);
  const area = size * size;
  const total = area * 3;
  const cached = pool.pop();
  const blob = cached && cached.length === total ? cached : new Float32Array(total);
  blob.fill(padFloat);
  const area2 = area * 2;
  const invScale = 1 / scale;
  const inv255 = 1 / 255;
  for (let row = 0; row < innerHeight; row += 1) {
    const sourceY = Math.min(height - 1, (row * invScale) | 0);
    const rowOffset = sourceY * width;
    const targetRow = (top + row) * size + left;
    for (let column = 0; column < innerWidth; column += 1) {
      const sourceX = Math.min(width - 1, (column * invScale) | 0);
      const source = (rowOffset + sourceX) << 2;
      const target = targetRow + column;
      blob[target] = frame[source] * inv255;
      blob[area + target] = frame[source + 1] * inv255;
      blob[area2 + target] = frame[source + 2] * inv255;
    }
  }
  return { blob, scale, left, top };
}

export function decodeBoxes(rows: Float32Array, frame: LetterboxFrame, width: number, height: number, threshold: number): DetectBox[] {
  const boxes: DetectBox[] = [];
  for (let index = 0; index + 5 < rows.length; index += 6) {
    const conf = rows[index + 4];
    if (!(conf >= threshold)) continue;
    const left = clamp((rows[index] - frame.left) / frame.scale, width);
    const top = clamp((rows[index + 1] - frame.top) / frame.scale, height);
    const right = clamp((rows[index + 2] - frame.left) / frame.scale, width);
    const bottom = clamp((rows[index + 3] - frame.top) / frame.scale, height);
    const boxWidth = right - left;
    const boxHeight = bottom - top;
    if (boxWidth < 1 || boxHeight < 1) continue;
    boxes.push({ x: round(left, 1), y: round(top, 1), width: round(boxWidth, 1), height: round(boxHeight, 1), conf: round(conf, 4) });
  }
  boxes.sort((left, right) => right.conf - left.conf);
  return boxes.slice(0, detectBoxLimit);
}

function clamp(value: number, limit: number): number {
  if (!Number.isFinite(value)) return 0;
  return Math.min(Math.max(value, 0), limit);
}

function round(value: number, digits: number): number {
  const factor = 10 ** digits;
  return Math.round(value * factor) / factor;
}

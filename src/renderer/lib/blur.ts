import { blurBoxLimit, blurFeather, blurRadius } from '../../shared/constants.js';
import type { DetectBox } from './detect.js';

const mergeGap = 6;
const downscale = 4;
const coreScale = 2;
const featherScale = 2;
const pool: HTMLCanvasElement[] = [];

interface BlurPart {
  canvas: HTMLCanvasElement;
  left: number;
  top: number;
  wide: number;
  tall: number;
  patchW: number;
  patchH: number;
}

interface BlurLayer {
  canvas: HTMLCanvasElement;
  ctx: CanvasRenderingContext2D;
}

let overlay: BlurLayer | undefined;
let shade: BlurLayer | undefined;

export function mergeBoxes(boxes: DetectBox[], gap = mergeGap): DetectBox[] {
  const list = boxes.map((box) => ({ ...box }));
  let merged = true;
  while (merged) {
    merged = false;
    for (let left = 0; left < list.length && !merged; left += 1) {
      for (let right = left + 1; right < list.length; right += 1) {
        if (!overlaps(list[left], list[right], gap)) continue;
        list[left] = union(list[left], list[right]);
        list.splice(right, 1);
        merged = true;
        break;
      }
    }
  }
  return list;
}

export function fitBoxes(boxes: DetectBox[], width: number, height: number): DetectBox[] {
  const list: DetectBox[] = [];
  for (const box of boxes) {
    const left = Math.max(0, Math.round(box.x));
    const top = Math.max(0, Math.round(box.y));
    const right = Math.min(width, Math.round(box.x + box.width));
    const bottom = Math.min(height, Math.round(box.y + box.height));
    if (right - left < 2 || bottom - top < 2) continue;
    list.push({ x: left, y: top, width: right - left, height: bottom - top });
  }
  return list;
}

export function limitBoxes(boxes: DetectBox[], limit = blurBoxLimit): DetectBox[] {
  if (boxes.length <= limit) return boxes;
  return [...boxes].sort((left, right) => right.width * right.height - left.width * left.height).slice(0, limit);
}

export function blurBoxes(ctx: CanvasRenderingContext2D, boxes: DetectBox[], width: number, height: number): void {
  const list = limitBoxes(fitBoxes(boxes, width, height));
  if (!list.length) return;
  const scale = width / 1280;
  const radius = Math.max(4, Math.round(blurRadius * scale));
  const feather = Math.max(2, Math.round(blurFeather * scale));
  const core = feather * coreScale;
  const pad = radius * 2 + feather * 6;
  const source = ctx.canvas;
  const parts: BlurPart[] = [];
  let left = width;
  let top = height;
  let right = 0;
  let bottom = 0;
  for (const box of list) {
    const part = buildPart(source, box, radius, pad, width, height);
    if (!part) continue;
    parts.push(part);
    left = Math.min(left, part.left);
    top = Math.min(top, part.top);
    right = Math.max(right, part.left + part.wide);
    bottom = Math.max(bottom, part.top + part.tall);
  }
  if (!parts.length) return;
  const over = acquireLayer('overlay', width, height);
  const mask = acquireLayer('shade', width, height);
  if (!over || !mask) return;
  const frameW = right - left;
  const frameH = bottom - top;
  over.ctx.clearRect(left, top, frameW, frameH);
  mask.ctx.clearRect(left, top, frameW, frameH);
  for (const part of parts) {
    over.ctx.drawImage(part.canvas, 0, 0, part.patchW, part.patchH, part.left, part.top, part.wide, part.tall);
    pool.push(part.canvas);
  }
  for (const box of list) drawMask(mask.ctx, box, core, feather);
  over.ctx.save();
  over.ctx.beginPath();
  over.ctx.rect(left, top, frameW, frameH);
  over.ctx.clip();
  over.ctx.globalCompositeOperation = 'destination-in';
  over.ctx.drawImage(mask.canvas, left, top, frameW, frameH, left, top, frameW, frameH);
  over.ctx.restore();
  ctx.drawImage(over.canvas, left, top, frameW, frameH, left, top, frameW, frameH);
}

function buildPart(source: CanvasImageSource, box: DetectBox, radius: number, pad: number, width: number, height: number): BlurPart | undefined {
  const left = Math.max(0, Math.floor(box.x - pad));
  const top = Math.max(0, Math.floor(box.y - pad));
  const right = Math.min(width, Math.ceil(box.x + box.width + pad));
  const bottom = Math.min(height, Math.ceil(box.y + box.height + pad));
  const wide = right - left;
  const tall = bottom - top;
  if (wide < 2 || tall < 2) return undefined;
  const patchW = Math.max(1, Math.ceil(wide / downscale));
  const patchH = Math.max(1, Math.ceil(tall / downscale));
  const canvas = pool.pop() ?? document.createElement('canvas');
  if (canvas.width < patchW) canvas.width = patchW;
  if (canvas.height < patchH) canvas.height = patchH;
  const partCtx = canvas.getContext('2d');
  if (!partCtx) {
    pool.push(canvas);
    return undefined;
  }
  partCtx.globalCompositeOperation = 'source-over';
  partCtx.clearRect(0, 0, patchW, patchH);
  partCtx.filter = `blur(${Math.max(1, Math.round(radius / downscale))}px)`;
  partCtx.drawImage(source, left, top, wide, tall, 0, 0, patchW, patchH);
  partCtx.filter = 'none';
  return { canvas, left, top, wide, tall, patchW, patchH };
}

function drawMask(ctx: CanvasRenderingContext2D, box: DetectBox, core: number, feather: number): void {
  const x = box.x - core;
  const y = box.y - core;
  const wide = box.width + core * 2;
  const tall = box.height + core * 2;
  const soft = feather * featherScale;
  ctx.fillStyle = '#fff';
  ctx.fillRect(x, y, wide, tall);
  const leftEdge = ctx.createLinearGradient(x - soft, 0, x, 0);
  leftEdge.addColorStop(0, 'rgba(255,255,255,0)');
  leftEdge.addColorStop(1, 'rgba(255,255,255,1)');
  ctx.fillStyle = leftEdge;
  ctx.fillRect(x - soft, y - soft, soft, tall + soft * 2);
  const rightEdge = ctx.createLinearGradient(x + wide, 0, x + wide + soft, 0);
  rightEdge.addColorStop(0, 'rgba(255,255,255,1)');
  rightEdge.addColorStop(1, 'rgba(255,255,255,0)');
  ctx.fillStyle = rightEdge;
  ctx.fillRect(x + wide, y - soft, soft, tall + soft * 2);
  const topEdge = ctx.createLinearGradient(0, y - soft, 0, y);
  topEdge.addColorStop(0, 'rgba(255,255,255,0)');
  topEdge.addColorStop(1, 'rgba(255,255,255,1)');
  ctx.fillStyle = topEdge;
  ctx.fillRect(x, y - soft, wide, soft);
  const bottomEdge = ctx.createLinearGradient(0, y + tall, 0, y + tall + soft);
  bottomEdge.addColorStop(0, 'rgba(255,255,255,1)');
  bottomEdge.addColorStop(1, 'rgba(255,255,255,0)');
  ctx.fillStyle = bottomEdge;
  ctx.fillRect(x, y + tall, wide, soft);
}

function acquireLayer(kind: 'overlay' | 'shade', width: number, height: number): BlurLayer | undefined {
  const current = kind === 'overlay' ? overlay : shade;
  if (current && current.canvas.width === width && current.canvas.height === height) return current;
  const canvas = current?.canvas ?? document.createElement('canvas');
  canvas.width = width;
  canvas.height = height;
  const ctx = canvas.getContext('2d');
  const layer = ctx ? { canvas, ctx } : undefined;
  if (kind === 'overlay') overlay = layer;
  else shade = layer;
  return layer;
}

export function overlayBoxes(ctx: CanvasRenderingContext2D, boxes: DetectBox[]): void {
  if (!boxes.length) return;
  ctx.save();
  ctx.lineWidth = 2;
  ctx.strokeStyle = '#19f7d2';
  for (const box of boxes) ctx.strokeRect(box.x, box.y, box.width, box.height);
  ctx.restore();
}

export function flipBoxes(boxes: DetectBox[], height: number): DetectBox[] {
  return boxes.map((box) => ({
    x: box.x,
    y: height - (box.y + box.height),
    width: box.width,
    height: box.height,
  }));
}

function overlaps(left: DetectBox, right: DetectBox, gap: number): boolean {
  return left.x - gap < right.x + right.width && right.x - gap < left.x + left.width && left.y - gap < right.y + right.height && right.y - gap < left.y + left.height;
}

function union(left: DetectBox, right: DetectBox): DetectBox {
  const x = Math.min(left.x, right.x);
  const y = Math.min(left.y, right.y);
  const right2 = Math.max(left.x + left.width, right.x + right.width);
  const bottom = Math.max(left.y + left.height, right.y + right.height);
  return { x, y, width: right2 - x, height: bottom - y };
}

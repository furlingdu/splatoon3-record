import { describe, expect, it } from 'vitest';
import { blurBoxes, flipBoxes, fitBoxes, limitBoxes, mergeBoxes, overlayBoxes } from '../src/renderer/lib/blur.js';
import { blurConfidence, blurFeather, blurRadius, detectFrameWidth } from '../src/shared/constants.js';

function box(x: number, y: number, width: number, height: number): { x: number; y: number; width: number; height: number } {
  return { x, y, width, height };
}

describe('打码推理参数', () => {
  it('置信度固定 0.1', () => {
    expect(blurConfidence).toBe(0.1);
  });

  it('送检画面宽度上限采用小尺寸 640', () => {
    expect(detectFrameWidth).toBe(640);
  });
});

describe('mergeBoxes', () => {
  it('相邻的框合并成一个', () => {
    const merged = mergeBoxes([box(0, 0, 10, 10), box(12, 0, 10, 10)]);
    expect(merged).toEqual([box(0, 0, 22, 10)]);
  });

  it('距离超过间隔的框保持独立', () => {
    const merged = mergeBoxes([box(0, 0, 10, 10), box(40, 0, 10, 10)]);
    expect(merged).toHaveLength(2);
  });

  it('链式相邻的框最终合并成整体', () => {
    const merged = mergeBoxes([box(0, 0, 10, 10), box(12, 0, 10, 10), box(24, 0, 10, 10)]);
    expect(merged).toEqual([box(0, 0, 34, 10)]);
  });

  it('不修改传入的框', () => {
    const source = [box(0, 0, 10, 10), box(12, 0, 10, 10)];
    mergeBoxes(source);
    expect(source).toEqual([box(0, 0, 10, 10), box(12, 0, 10, 10)]);
  });
});

describe('fitBoxes', () => {
  it('检测框按原尺寸夹进画面', () => {
    const fitted = fitBoxes([box(100, 50, 40, 20)], 1920, 1080);
    expect(fitted).toEqual([box(100, 50, 40, 20)]);
  });

  it('扁长的昵称框保持自身长宽，不拉成正方形', () => {
    const fitted = fitBoxes([box(200, 100, 100, 20)], 1920, 1080);
    expect(fitted).toEqual([box(200, 100, 100, 20)]);
  });

  it('越界大框按画面夹取', () => {
    const fitted = fitBoxes([box(-20, -10, 140, 100)], 120, 90);
    expect(fitted).toEqual([box(0, 0, 120, 90)]);
  });

  it('贴边小框只保留画面内的部分', () => {
    const fitted = fitBoxes([box(1, 1, 6, 6)], 1920, 1080);
    expect(fitted).toEqual([box(1, 1, 6, 6)]);
  });

  it('越界框按原尺寸裁剪且不向外膨胀', () => {
    const fitted = fitBoxes([box(-10, -10, 30, 30)], 100, 100);
    expect(fitted).toEqual([box(0, 0, 20, 20)]);
  });

  it('框被夹到无法分辨时丢弃', () => {
    expect(fitBoxes([box(0, 0, 6, 6)], 1, 1)).toEqual([]);
  });
});

describe('flipBoxes', () => {
  it('按画幅高度翻到垂直镜像位置', () => {
    const flipped = flipBoxes([box(5, 10, 20, 30)], 100);
    expect(flipped).toEqual([box(5, 60, 20, 30)]);
  });
});

describe('limitBoxes', () => {
  it('超过上限时只保留面积最大的若干框', () => {
    const limited = limitBoxes([box(0, 0, 10, 10), box(0, 0, 100, 40), box(0, 0, 40, 40)], 2);
    expect(limited).toEqual([box(0, 0, 100, 40), box(0, 0, 40, 40)]);
  });

  it('未超过上限时原样返回', () => {
    const boxes = [box(0, 0, 10, 10)];
    expect(limitBoxes(boxes, 2)).toBe(boxes);
  });
});

interface DrawOp {
  kind: string;
  args: unknown[];
  filter: string;
  composite: string;
}

function stubContext(ops: DrawOp[], canvas: unknown): CanvasRenderingContext2D {
  const stack: { filter: string; composite: string; fillStyle: string }[] = [];
  const ctx = {
    canvas,
    filter: 'none',
    globalCompositeOperation: 'source-over',
    fillStyle: '',
    save: () => {
      stack.push({ filter: ctx.filter, composite: ctx.globalCompositeOperation, fillStyle: ctx.fillStyle });
      ops.push({ kind: 'save', args: [], filter: ctx.filter, composite: ctx.globalCompositeOperation });
    },
    restore: () => {
      const saved = stack.pop();
      if (saved) {
        ctx.filter = saved.filter;
        ctx.globalCompositeOperation = saved.composite;
        ctx.fillStyle = saved.fillStyle;
      }
      ops.push({ kind: 'restore', args: [], filter: ctx.filter, composite: ctx.globalCompositeOperation });
    },
    beginPath: () => ops.push({ kind: 'beginPath', args: [], filter: ctx.filter, composite: ctx.globalCompositeOperation }),
    rect: (...args: number[]) => ops.push({ kind: 'rect', args, filter: ctx.filter, composite: ctx.globalCompositeOperation }),
    clip: () => ops.push({ kind: 'clip', args: [], filter: ctx.filter, composite: ctx.globalCompositeOperation }),
    clearRect: (...args: number[]) => ops.push({ kind: 'clear', args, filter: ctx.filter, composite: ctx.globalCompositeOperation }),
    fillRect: (...args: number[]) => ops.push({ kind: `fill:${ctx.fillStyle}`, args, filter: ctx.filter, composite: ctx.globalCompositeOperation }),
    createLinearGradient: () => ({ addColorStop: () => undefined, toString: () => 'gradient' }),
    drawImage: (...args: unknown[]) => ops.push({ kind: 'draw', args, filter: ctx.filter, composite: ctx.globalCompositeOperation }),
  };
  return ctx as unknown as CanvasRenderingContext2D;
}

describe('blurBoxes', () => {
  it('模糊内容进叠加层，蒙版用不透明核心加渐变柔边', () => {
    const created: DrawOp[][] = [];
    const origin = (globalThis as { document?: unknown }).document;
    (globalThis as { document?: unknown }).document = {
      createElement: () => {
        const ops: DrawOp[] = [];
        created.push(ops);
        const canvas = { width: 0, height: 0, getContext: () => stubContext(ops, undefined) };
        return canvas;
      },
    };
    try {
      const mainOps: DrawOp[] = [];
      const ctx = stubContext(mainOps, { width: 1280, height: 720 });
      blurBoxes(ctx, [box(100, 50, 200, 40)], 1280, 720);
      const patch = created[0];
      const over = created[1];
      const mask = created[2];
      const blurOp = patch.find((op) => op.kind === 'draw');
      expect(blurOp?.filter).toBe(`blur(${Math.round(blurRadius / 4)}px)`);
      expect(over.filter((op) => op.kind === 'draw' && op.composite === 'source-over')).toHaveLength(1);
      expect(over.filter((op) => op.kind === 'draw' && op.composite === 'destination-in')).toHaveLength(1);
      const core = mask.find((op) => op.kind === 'fill:#fff');
      expect(core?.args).toEqual([92, 42, 216, 56]);
      expect(mask.some((op) => op.kind === 'clip')).toBe(false);
      expect(mask.every((op) => op.filter === 'none')).toBe(true);
      const draws = mainOps.filter((op) => op.kind === 'draw');
      expect(draws).toHaveLength(1);
      expect(draws[0].args.slice(1)).toEqual([56, 6, 288, 128, 56, 6, 288, 128]);

      for (const ops of created) ops.length = 0;
      mainOps.length = 0;
      const boxes = [box(100, 50, 200, 40), box(100, 50, 200, 40), box(140, 50, 200, 40)];
      blurBoxes(ctx, boxes, 1280, 720);
      const overDup = created[1];
      const maskDup = created[2];
      expect(overDup.filter((op) => op.kind === 'draw' && op.composite === 'source-over')).toHaveLength(3);
      expect(overDup.filter((op) => op.kind === 'draw' && op.composite === 'destination-in')).toHaveLength(1);
      const cores = maskDup.filter((op) => op.kind === 'fill:#fff');
      expect(cores).toHaveLength(3);
      expect(cores.every((op) => op.args[2] === 216 && op.args[3] === 56)).toBe(true);
      expect(maskDup.every((op) => op.filter === 'none')).toBe(true);
    } finally {
      (globalThis as { document?: unknown }).document = origin;
    }
  });

  it('模糊强度低于旧版固定半径', () => {
    expect(blurRadius).toBeLessThan(24);
    expect(blurRadius).toBeGreaterThanOrEqual(8);
    expect(blurFeather).toBeGreaterThan(0);
  });
});

describe('overlayBoxes', () => {
  it('按检测框位置描边', () => {
    const drawn: number[][] = [];
    const ctx = {
      save: () => undefined,
      restore: () => undefined,
      strokeRect: (...args: number[]) => drawn.push(args),
      lineWidth: 0,
      strokeStyle: '',
    } as unknown as CanvasRenderingContext2D;
    overlayBoxes(ctx, [box(1, 2, 3, 4)]);
    expect(drawn).toEqual([[1, 2, 3, 4]]);
  });
});

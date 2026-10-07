import { describe, expect, it } from 'vitest';
import { buildBlob, decodeBoxes } from '../src/main/detect/letterbox.js';
import { detectBoxLimit } from '../src/shared/constants.js';

function frameOf(width: number, height: number, color: [number, number, number]): Uint8Array {
  const frame = new Uint8Array(width * height * 4);
  for (let index = 0; index < width * height; index += 1) {
    frame[index * 4] = color[0];
    frame[index * 4 + 1] = color[1];
    frame[index * 4 + 2] = color[2];
    frame[index * 4 + 3] = 255;
  }
  return frame;
}

describe('letterbox', () => {
  it('等比填充到模型输入画幅', () => {
    const shot = buildBlob(frameOf(960, 540, [255, 0, 0]), 960, 540, 960);
    expect(shot.scale).toBe(1);
    expect(shot.left).toBe(0);
    expect(shot.top).toBe(210);
    expect(shot.blob).toHaveLength(3 * 960 * 960);
    expect(shot.blob[210 * 960 + 10]).toBeCloseTo(1, 5);
    expect(shot.blob[960 * 960 + 210 * 960 + 10]).toBeCloseTo(0, 5);
    expect(shot.blob[0]).toBeCloseTo(114 / 255, 5);
  });

  it('送检画面比模型输入小时按比例放大', () => {
    const shot = buildBlob(frameOf(480, 480, [0, 255, 0]), 480, 480, 960);
    expect(shot.scale).toBe(2);
    expect(shot.left).toBe(0);
    expect(shot.top).toBe(0);
    expect(shot.blob[960 * 960]).toBeCloseTo(1, 5);
  });

  it('还原坐标时扣掉填充并夹回画面内', () => {
    const shot = buildBlob(frameOf(960, 540, [0, 0, 0]), 960, 540, 960);
    const rows = new Float32Array([
      10, 220, 110, 260, 0.9, 0,
      10, 10, 20, 20, 0.4, 0,
      -50, 200, 50, 260, 0.7, 0,
    ]);
    const boxes = decodeBoxes(rows, shot, 960, 540, 0.5);
    expect(boxes).toHaveLength(2);
    expect(boxes[0]).toMatchObject({ x: 10, y: 10, width: 100, height: 40, conf: 0.9 });
    expect(boxes[1]).toMatchObject({ x: 0, y: 0, width: 50, height: 50, conf: 0.7 });
  });

  it('按置信度排序并限制框数', () => {
    const shot = buildBlob(frameOf(960, 540, [0, 0, 0]), 960, 540, 960);
    const rows = new Float32Array(300 * 6);
    for (let index = 0; index < 300; index += 1) {
      rows[index * 6] = 10;
      rows[index * 6 + 1] = 220;
      rows[index * 6 + 2] = 60;
      rows[index * 6 + 3] = 270;
      rows[index * 6 + 4] = 0.5 + index / 1000;
    }
    const boxes = decodeBoxes(rows, shot, 960, 540, 0.5);
    expect(boxes).toHaveLength(detectBoxLimit);
    expect(boxes[0].conf).toBeGreaterThan(boxes[1].conf);
  });

  it('低于阈值与退化框直接丢掉', () => {
    const shot = buildBlob(frameOf(960, 540, [0, 0, 0]), 960, 540, 960);
    const rows = new Float32Array([
      10, 220, 10.4, 220.4, 0.99, 0,
      10, 220, 110, 260, 0.49, 0,
    ]);
    expect(decodeBoxes(rows, shot, 960, 540, 0.5)).toEqual([]);
  });
});

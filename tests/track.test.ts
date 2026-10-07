import { describe, expect, it } from 'vitest';
import { predictBoxes, updateTracks } from '../src/renderer/lib/track.js';
import type { DetectBox } from '../src/renderer/lib/detect.js';

function box(x: number, y: number, width = 100, height = 20): DetectBox {
  return { x, y, width, height };
}

describe('updateTracks', () => {
  it('按相邻两次推理的位移记住移动速度', () => {
    const first = updateTracks([], [box(0, 0)], 1000, 1080);
    const second = updateTracks(first, [box(20, 0)], 1100, 1180);
    expect(second).toHaveLength(1);
    expect(second[0].vx).toBeCloseTo(0.2, 5);
    expect(predictBoxes(second, 1200)[0].x).toBeCloseTo(40, 5);
  });

  it('速度过快时按上限收敛', () => {
    const first = updateTracks([], [box(0, 0, 800, 20)], 1000, 1080);
    const second = updateTracks(first, [box(500, 0, 800, 20)], 1016, 1096);
    expect(second[0].vx).toBeCloseTo(20, 5);
  });

  it('镜头快速平移时按最新位移跟得更紧', () => {
    const first = updateTracks([], [box(0, 0, 400, 20)], 1000, 1080);
    const second = updateTracks(first, [box(100, 0, 400, 20)], 1100, 1180);
    const third = updateTracks(second, [box(500, 0, 400, 20)], 1200, 1280);
    expect(third[0].vx).toBeGreaterThan(3);
  });

  it('没有匹配的轨迹先减速保留再丢弃', () => {
    const first = updateTracks([], [box(0, 0)], 1000, 1000);
    const kept = updateTracks(first, [], 1100, 1150);
    expect(kept).toHaveLength(1);
    const dropped = updateTracks(kept, [], 1200, 1300);
    expect(dropped).toHaveLength(0);
  });

  it('目标离开画面后短时间内轨迹不再保留', () => {
    const tracks = updateTracks([], [box(0, 0)], 1000, 1000);
    expect(updateTracks(tracks, [], 1100, 1200)).toHaveLength(1);
    expect(updateTracks(tracks, [], 1200, 1300)).toHaveLength(0);
  });

  it('新框优先接上最近的轨迹', () => {
    const tracks = updateTracks([], [box(0, 0), box(1000, 0)], 1000, 1000);
    const next = updateTracks(tracks, [box(1004, 0)], 1100, 1100);
    expect(next).toHaveLength(2);
    expect(next.some((item) => item.x === 1004)).toBe(true);
    expect(next.some((item) => item.x === 0)).toBe(true);
  });

  it('相距太远的框不会接到同一条轨迹', () => {
    const tracks = updateTracks([], [box(0, 0)], 1000, 1000);
    const next = updateTracks(tracks, [box(900, 400)], 1100, 1100);
    expect(next).toHaveLength(2);
  });
});

describe('predictBoxes', () => {
  it('外推只补推理延迟这一段', () => {
    const first = updateTracks([], [box(0, 0)], 1000, 1080);
    const second = updateTracks(first, [box(20, 0)], 1100, 1180);
    expect(predictBoxes(second, 1100)[0].x).toBeCloseTo(20, 5);
    expect(predictBoxes(second, 5000)[0].x).toBeCloseTo(90, 5);
  });

  it('外推跨过推理间隙继续跟随目标', () => {
    const first = updateTracks([], [box(0, 0)], 1000, 1080);
    const second = updateTracks(first, [box(20, 0)], 1100, 1180);
    expect(predictBoxes(second, 1400)[0].x).toBeCloseTo(80, 5);
  });

  it('没有速度时保持原位', () => {
    const tracks = updateTracks([], [box(30, 40)], 1000, 1080);
    expect(predictBoxes(tracks, 1400)).toEqual([box(30, 40)]);
  });
});


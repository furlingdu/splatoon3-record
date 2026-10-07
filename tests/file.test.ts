import { describe, expect, it } from 'vitest';
import { safeName } from '../src/main/media/file.js';

describe('文件名', () => {
  it('转换为无连字符的小驼峰名称', () => {
    expect(safeName('vs-100')).toMatch(/^vs100h[0-9a-f]{8}$/);
    expect(safeName('battle_result-1')).toMatch(/^battleResult1h[0-9a-f]{8}$/);
    expect(safeName('../secret')).toMatch(/^secreth[0-9a-f]{8}$/);
    expect(safeName('123')).toMatch(/^file123h[0-9a-f]{8}$/);
    expect(safeName('vs-100')).not.toBe(safeName('vs100'));
  });
});

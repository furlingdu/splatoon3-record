import { describe, expect, it } from 'vitest';
import { isNewer } from '../src/main/update/checker.js';

describe('isNewer', () => {
  it('比较版本号', () => {
    expect(isNewer('0.1.0', '0.2.0')).toBe(true);
    expect(isNewer('1.0.0', '0.9.9')).toBe(false);
    expect(isNewer('0.1.0', '0.1.0')).toBe(false);
    expect(isNewer('0.1', '0.1.1')).toBe(true);
  });
});

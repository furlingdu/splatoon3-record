import { describe, expect, it } from 'vitest';
import { isRetryableLogin, retryLogin } from '../src/main/nso/retry.js';

describe('retryLogin', () => {
  it('网络类失败最多重试五次后成功', async () => {
    let calls = 0;
    const value = await retryLogin(async () => {
      calls += 1;
      if (calls < 6) throw new Error('fetch failed');
      return 'ok';
    }, 5, 0);
    expect(value).toBe('ok');
    expect(calls).toBe(6);
  });

  it('不可恢复的错误不重试', async () => {
    let calls = 0;
    await expect(retryLogin(async () => {
      calls += 1;
      throw new Error('请重新登录');
    }, 5, 0)).rejects.toThrow('请重新登录');
    expect(calls).toBe(1);
  });
});

describe('isRetryableLogin', () => {
  it('识别网络错误并排除会话问题', () => {
    expect(isRetryableLogin(new Error('fetch failed'))).toBe(true);
    expect(isRetryableLogin(new Error('该账号已停用'))).toBe(false);
  });
});

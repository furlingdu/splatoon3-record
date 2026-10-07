import { describe, expect, it } from 'vitest';
import { guestText, isOwner, resolveBind } from '../src/main/qq/bind.js';

describe('resolveBind', () => {
  it('未绑定时允许绑定', () => {
    expect(resolveBind({}, 'user-a')).toEqual({ action: 'bind', text: '绑定成功~ 欢迎使用Splatoon 3 Record项目！\n作者@澪度\n官方群聊：1109099716' });
  });

  it('主人重复绑定回复提示', () => {
    const result = resolveBind({ qqOwner: 'user-a' }, 'user-a');
    expect(result.action).toBe('ok');
    if (result.action === 'ok') expect(result.text).toContain('无需重复绑定');
  });

  it('其他用户绑定被拒绝', () => {
    const result = resolveBind({ qqOwner: 'user-a' }, 'user-b');
    expect(result.action).toBe('deny');
    if (result.action === 'deny') expect(result.text).toContain('已绑定其他用户');
  });
});

describe('isOwner', () => {
  it('仅主人通过校验', () => {
    expect(isOwner({ qqOwner: 'user-a' }, 'user-a')).toBe(true);
    expect(isOwner({ qqOwner: 'user-a' }, 'user-b')).toBe(false);
    expect(isOwner({}, 'user-a')).toBe(false);
  });
});

describe('guestText', () => {
  it('返回绑定提示', () => {
    expect(guestText()).toContain('/bind');
  });
});

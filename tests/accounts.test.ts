import { describe, expect, it } from 'vitest';
import { legacyAccountId, mergeAccount, normalizeAccounts, removeAccountFromList } from '../src/main/nso/accountmodel.js';
import type { NsoAccountSecret, NsoToken } from '../src/shared/types.js';

function token(id: string): NsoToken {
  return { bulletToken: `bullet-${id}`, gToken: `g-${id}`, language: 'zh-CN', country: 'JP', userAgent: 'ua', expiresAt: Date.now() + 3600000 };
}

function account(id: string): NsoAccountSecret {
  return { id, nickname: `昵称${id}`, session: `session-${id}`, token: token(id), addedAt: 1 };
}

function identity(id: string): { accountId: string; nickname: string; token: NsoToken } {
  return { accountId: id, nickname: `昵称${id}`, token: token(id) };
}

describe('NSO 账户列表', () => {
  it('把旧版单账户凭证迁移为一个 legacy 账户', () => {
    const result = normalizeAccounts({ nsoSession: 'old-session', nsoToken: token('legacy') });
    expect(result.accounts).toHaveLength(1);
    expect(result.accounts[0].id).toBe(legacyAccountId);
    expect(result.current).toBe(legacyAccountId);
  });

  it('同一账户重复登录只更新凭证，不增加账户', () => {
    const first = mergeAccount([], undefined, identity('1001'), undefined, 'session-1001', 5);
    const second = mergeAccount(first.accounts, first.current, identity('1001'), '1001', 'new-session', 5);
    expect(second.accounts).toHaveLength(1);
    expect(second.accounts[0].session).toBe('new-session');
    expect(second.accounts[0].nickname).toBe('昵称1001');
  });

  it('最多只保留五个账户', () => {
    const list = ['1', '2', '3', '4', '5'].map(account);
    const result = mergeAccount(list, '1', identity('6'), undefined, 'session-6', 5);
    expect(result.error).toContain('最多只能绑定 5 个');
    expect(result.accounts).toHaveLength(5);
  });

  it('重新登录 legacy 账户后合并为稳定账户 ID', () => {
    const legacy = account(legacyAccountId);
    const result = mergeAccount([legacy], legacyAccountId, identity('1001'), legacyAccountId, 'new-session', 5);
    expect(result.accounts.map((item) => item.id)).toEqual(['1001']);
    expect(result.current).toBe('1001');
  });

  it('刷新期间账户被删除时不重新创建', () => {
    const result = mergeAccount([account('1002')], '1002', identity('1001'), '1001', 'session', 5);
    expect(result.missing).toBe(true);
    expect(result.accounts.map((item) => item.id)).toEqual(['1002']);
  });

  it('最后一个账户不可删除，删除当前账户后自动选择剩余账户', () => {
    expect(removeAccountFromList([account('1001')], '1001', '1001', 1).error).toBeDefined();
    const result = removeAccountFromList([account('1001'), account('1002')], '1001', '1001', 1);
    expect(result.accounts.map((item) => item.id)).toEqual(['1002']);
    expect(result.current).toBe('1002');
  });
});

import { nsoAccountLimit } from '../../shared/constants.js';
import type { NsoAccountSecret, NsoToken, SecretData } from '../../shared/types.js';

export const legacyAccountId = 'legacy';

export interface AccountIdentity {
  accountId: string;
  nickname: string;
  token: NsoToken;
}

export interface AccountList {
  accounts: NsoAccountSecret[];
  current?: string;
}

export interface MergeResult extends AccountList {
  stored?: NsoToken;
  missing?: boolean;
  error?: string;
}

export function normalizeAccounts(data: SecretData): AccountList {
  if (Array.isArray(data.nsoAccounts)) {
    const unique = new Map<string, NsoAccountSecret>();
    for (const item of data.nsoAccounts) {
      if (!item || !item.id || !item.session || !item.token) continue;
      unique.set(String(item.id), {
        id: String(item.id),
        nickname: String(item.nickname || 'Nintendo 账号'),
        session: String(item.session),
        token: item.token,
        addedAt: Number(item.addedAt) || Date.now(),
        lastRefreshAt: Number(item.lastRefreshAt) || undefined,
      });
    }
    const accounts = [...unique.values()].slice(0, nsoAccountLimit);
    if (accounts.length || (!data.nsoSession && !data.nsoToken)) return { accounts, current: data.currentNsoAccountId };
  }
  if (data.nsoSession && data.nsoToken) {
    return {
      accounts: [{ id: legacyAccountId, nickname: 'Nintendo 账号', session: data.nsoSession, token: data.nsoToken, addedAt: Date.now() }],
      current: legacyAccountId,
    };
  }
  return { accounts: [], current: data.currentNsoAccountId };
}

export function mergeAccount(
  list: NsoAccountSecret[],
  current: string | undefined,
  result: AccountIdentity,
  targetId: string | undefined,
  sessionToken: string | undefined,
  limit: number,
): MergeResult {
  const source = list.slice();
  const byReal = source.find((item) => item.id === result.accountId);
  const byTarget = targetId ? source.find((item) => item.id === targetId) : undefined;
  if (targetId && !byReal && !byTarget) return { accounts: source, current, missing: true };
  const kept = source.filter((item) => item.id !== result.accountId && item.id !== targetId);
  if (!byReal && !byTarget && kept.length >= limit) return { accounts: source, current, error: `最多只能绑定 ${limit} 个 NSO 账户` };
  const account: NsoAccountSecret = {
    id: result.accountId,
    nickname: result.nickname,
    session: sessionToken || byReal?.session || byTarget?.session || '',
    token: result.token,
    addedAt: byReal?.addedAt ?? byTarget?.addedAt ?? Date.now(),
    lastRefreshAt: Date.now(),
  };
  return {
    accounts: [...kept, account],
    current: current === targetId || !current ? account.id : current,
    stored: result.token,
  };
}

export function removeAccountFromList(
  list: NsoAccountSecret[],
  current: string | undefined,
  accountId: string,
  limit: number,
): AccountList & { error?: string } {
  if (!list.some((item) => item.id === accountId)) return { accounts: list, current };
  if (list.length <= limit) return { accounts: list, current, error: '至少需要保留一个 NSO 账户' };
  const accounts = list.filter((item) => item.id !== accountId);
  return { accounts, current: current === accountId ? accounts[0]?.id : current };
}

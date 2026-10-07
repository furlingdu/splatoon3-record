import { loadSecret } from '../store/secret.js';
import type { NsoLogin } from './login.js';
import type { NsoToken } from '../../shared/types.js';

export function isExpired(token: NsoToken, marginMs = 60000): boolean {
  return token.expiresAt < Date.now() + marginMs;
}

export async function getToken(): Promise<NsoToken | undefined> {
  return (await loadSecret()).nsoToken;
}

export async function ensureToken(nso: NsoLogin): Promise<NsoToken | undefined> {
  const token = await getToken();
  if (!token) return undefined;
  if (!isExpired(token)) return token;
  const secret = await loadSecret();
  if (!secret.nsoSession) return token;
  try { return await nso.refresh(secret.nsoSession); } catch (error) {
    nso.markFailure(error);
    nso.notifyFailure();
    return token;
  }
}

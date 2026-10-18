import type { NsoToken } from '../../shared/types.js';

export function isExpired(token: NsoToken, marginMs = 60000): boolean {
  return token.expiresAt < Date.now() + marginMs;
}

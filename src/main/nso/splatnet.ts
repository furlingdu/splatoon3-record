import { loadSecret, saveSecret } from '../store/secret.js';
import type { NsoToken } from '../../shared/types.js';

export const splatnetUrl = 'https://api.lp1.av5ja.srv.nintendo.net';
export const splatnetUserAgent = 'Mozilla/5.0 (Linux; Android 14; Pixel 7a) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.6099.230 Mobile Safari/537.36';
export const splatnetVersion = '10.0.0-dfefd0af';
const requestTimeout = 15000;
export const queryHash = {
  latest: 'b24d22fd6cb251c515c2b90044039698aa27bc1fab15801d83014d919cd45780',
  coop: 'e11a8cf2c3de7348495dea5cdcaa25e0c153541c4ed63f044b6c174bc5b703df',
  detail: '94faa2ff992222d11ced55e0f349920a82ac50f414ae33c83d1d1c9d8161c5dd',
  coopDetail: 'f2d55873a9281213ae27edc171e2b19131b3021a2ae263757543cdd3bf015cc8',
};

export class SplatnetClient {
  private token?: NsoToken;
  constructor(token?: NsoToken) { this.token = token; }

  async request(hash: string, variable?: Record<string, unknown>): Promise<unknown> {
    if (!this.token) throw new Error('SplatNet 未登录');
    if (this.token.expiresAt < Date.now() + 60000) await this.refresh();
    const response = await fetch(`${splatnetUrl}/api/graphql`, {
      method: 'POST',
      headers: this.graphqlHeaders(),
      body: JSON.stringify({ extensions: { persistedQuery: { sha256Hash: hash, version: 1 } }, variables: variable ?? {} }),
      signal: AbortSignal.timeout(requestTimeout),
    });
    if (!response.ok) throw new Error(`SplatNet HTTP ${response.status}`);
    const data = await response.json() as { errors?: unknown[] };
    if (data.errors?.length) throw new Error('SplatNet GraphQL 请求失败');
    return data;
  }

  async refresh(): Promise<NsoToken> {
    if (!this.token?.gToken) throw new Error('GameWebToken 不存在');
    const response = await fetch(`${splatnetUrl}/api/bullet_tokens`, { method: 'POST', headers: this.headers(), signal: AbortSignal.timeout(requestTimeout) });
    if (!response.ok) throw new Error(`bullet token HTTP ${response.status}`);
    const body = await response.json() as { bulletToken?: string };
    if (!body.bulletToken) throw new Error('未获取到 bullet token');
    this.token = { ...this.token, bulletToken: body.bulletToken, expiresAt: Date.now() + 7200000 };
    const secret = await loadSecret();
    await saveSecret({ ...secret, nsoToken: this.token });
    return this.token;
  }

  private graphqlHeaders(): Record<string, string> {
    return {
      Accept: '*/*',
      'Content-Type': 'application/json',
      'User-Agent': splatnetUserAgent,
      Authorization: `Bearer ${this.token?.bulletToken || ''}`,
      'Accept-Language': this.token?.language || 'en-US',
      Referer: `https://api.lp1.av5ja.srv.nintendo.net/?lang=${this.token?.language || 'en-US'}&na_country=${this.token?.country || 'JP'}&na_lang=${this.token?.language || 'en-US'}`,
      Origin: splatnetUrl,
      'X-Requested-With': 'com.nintendo.znca',
      'X-Web-View-Ver': splatnetVersion,
      Cookie: `_gtoken=${this.token?.gToken || ''}; _dnt=1`,
    };
  }

  private headers(): Record<string, string> {
    return {
      Accept: '*/*',
      'Content-Type': 'application/json',
      'User-Agent': splatnetUserAgent,
      'X-Requested-With': 'XMLHttpRequest',
      'X-Web-View-Ver': splatnetVersion,
      'X-NACOUNTRY': this.token?.country || 'JP',
      'Accept-Language': this.token?.language || 'en-US',
      'X-GameWebToken': this.token?.gToken || '',
      Cookie: `_gtoken=${this.token?.gToken || ''}; _dnt=1`,
      Origin: splatnetUrl,
      Referer: `${splatnetUrl}/`,
    };
  }
}

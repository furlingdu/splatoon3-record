import { afterEach, describe, expect, it, vi } from 'vitest';
import { SplatnetClient, queryHash, splatnetUserAgent, splatnetVersion } from '../src/main/nso/splatnet.js';

afterEach(() => {
  vi.unstubAllGlobals();
});

describe('SplatnetClient', () => {
  it('GraphQL 请求保留账号语言且不强制简体中文', async () => {
    const fetchMock = vi.fn().mockResolvedValue({ ok: true, json: async () => ({ data: {} }) });
    vi.stubGlobal('fetch', fetchMock);
    const token = { bulletToken: 'bullet', gToken: 'g-token', language: 'ja-JP', country: 'JP', userAgent: '', expiresAt: Date.now() + 600000 };
    const client = new SplatnetClient(token);
    await client.request(queryHash.latest, {});
    const options = fetchMock.mock.calls[0][1] as RequestInit;
    expect(options.headers).toMatchObject({
      Authorization: 'Bearer bullet',
      'User-Agent': splatnetUserAgent,
      'X-Requested-With': 'com.nintendo.znca',
      'X-Web-View-Ver': splatnetVersion,
      'Accept-Language': 'ja-JP',
      Cookie: '_gtoken=g-token; _dnt=1',
    });
  });
});

import { afterEach, describe, expect, it } from 'vitest';
import { getJson } from '../src/main/nso/http.js';
import { createHttpServers } from './httphelper.js';

const servers = createHttpServers();

afterEach(() => servers.closeAll());

describe('NSO HTTP helper', () => {
  it('rejects instead of hanging when the response body never finishes', async () => {
    const base = await servers.listen((_request, response) => {
      response.writeHead(200, { 'content-type': 'application/json' });
      response.write('{"partial":');
    });
    const started = Date.now();
    await expect(getJson(`${base}/stall`, {}, 300)).rejects.toThrow(/超时/);
    expect(Date.now() - started).toBeLessThan(3000);
  });

  it('parses a normal JSON response', async () => {
    const base = await servers.listen((_request, response) => {
      response.writeHead(200, { 'content-type': 'application/json' });
      response.end(JSON.stringify({ nso_version: '3.5.0' }));
    });
    await expect(getJson(`${base}/ok`, {}, 2000)).resolves.toEqual({ nso_version: '3.5.0' });
  });

  it('keeps the server detail for non-2xx responses', async () => {
    const base = await servers.listen((_request, response) => {
      response.writeHead(503, { 'content-type': 'application/json' });
      response.end(JSON.stringify({ errorMessage: 'Service Unavailable' }));
    });
    await expect(getJson(`${base}/down`, {}, 2000)).rejects.toThrow(/503.*Service Unavailable/);
  });

  it('keeps a plain-text error body readable', async () => {
    const base = await servers.listen((_request, response) => {
      response.writeHead(503, { 'content-type': 'text/plain' });
      response.end('Service Unavailable');
    });
    await expect(getJson(`${base}/plain`, {}, 2000)).rejects.toThrow(/HTTP 503 Service Unavailable/);
  });
});

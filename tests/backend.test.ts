import { afterEach, describe, expect, it } from 'vitest';
import { checkNsoBackend } from '../src/main/nso/backend.js';
import { createHttpServers } from './httphelper.js';

const servers = createHttpServers();

afterEach(() => servers.closeAll());

describe('checkNsoBackend', () => {
  it('reports the instance version and latency when /config responds', async () => {
    const base = await servers.listen((_request, response) => {
      response.writeHead(200, { 'content-type': 'application/json' });
      response.end(JSON.stringify({ versions: [], nso_version: '3.6.0' }));
    });
    const status = await checkNsoBackend(`${base}/`, 2000);
    expect(status.state).toBe('online');
    expect(status.version).toBe('3.6.0');
    expect(status.url).toBe(base);
    expect(status.latencyMs).toBeGreaterThanOrEqual(0);
    expect(status.error).toBeUndefined();
  });

  it('reports the server error when /config is unavailable', async () => {
    const base = await servers.listen((_request, response) => {
      response.writeHead(503, { 'content-type': 'text/plain' });
      response.end('Service Unavailable');
    });
    const status = await checkNsoBackend(base, 2000);
    expect(status.state).toBe('offline');
    expect(status.error).toContain('503');
  });

  it('reports a timeout instead of hanging on a stalled response', async () => {
    const base = await servers.listen((_request, response) => {
      response.writeHead(200, { 'content-type': 'application/json' });
      response.write('{"nso_version":');
    });
    const started = Date.now();
    const status = await checkNsoBackend(base, 300);
    expect(status.state).toBe('offline');
    expect(status.error).toMatch(/超时|timeout/i);
    expect(Date.now() - started).toBeLessThan(3000);
  });
});

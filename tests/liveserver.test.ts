import { createContext, runInContext } from 'node:vm';
import { afterAll, describe, expect, it, vi } from 'vitest';
import { LiveServer } from '../src/main/live/server.js';

let server: LiveServer | undefined;

afterAll(async () => {
  await server?.close();
});

describe('LiveServer', () => {
  it('网页与状态接口可访问，未开播时拒绝拉流', async () => {
    server = new LiveServer();
    const port = await server.listen(0, '127.0.0.1');
    expect(port).toBeGreaterThan(0);

    const page = await fetch(`http://127.0.0.1:${port}/`).then((item) => item.text());
    expect(page).toContain('<title>Splatoon3 Record 直播</title>');
    expect(page).toContain('VideoDecoder');
    expect(page).toContain('/stream');
    expect(page).not.toContain('RTCPeerConnection');
    expect(page).not.toContain('等待直播');

    const idle = await fetch(`http://127.0.0.1:${port}/status`).then((item) => item.json());
    expect(idle).toEqual({ live: false, viewers: 0 });
    const refused = await fetch(`http://127.0.0.1:${port}/stream`);
    expect(refused.status).toBe(503);
    const missing = await fetch(`http://127.0.0.1:${port}/nothing`);
    expect(missing.status).toBe(404);

    server.start();
    const live = await fetch(`http://127.0.0.1:${port}/status`).then((item) => item.json());
    expect(live).toEqual({ live: true, viewers: 0 });

    const abort = new AbortController();
    const stream = await fetch(`http://127.0.0.1:${port}/stream`, { signal: abort.signal });
    expect(stream.status).toBe(200);
    expect(stream.headers.get('content-type')).toContain('application/octet-stream');
    const reader = stream.body?.getReader();
    expect(reader).toBeTruthy();
    server.writeChunk({ kind: 'meta', codec: 'avc1.64002A', width: 1920, height: 1080, fps: 60, channels: 2, sampleRate: 48000 });
    await waitViewers(server, 1);

    const meta = await reader?.read();
    expect(meta?.done).toBe(false);
    expect(meta?.value?.[0]).toBe(1);
    const head = new DataView(meta?.value?.buffer ?? new ArrayBuffer(0), meta?.value?.byteOffset ?? 0, 16);
    expect(head.getUint32(12, true)).toBeGreaterThan(0);

    server.writeChunk({ kind: 'video', key: true, timestampUs: 1000, data: new Uint8Array([1, 2, 3]).buffer });
    const video = await reader?.read();
    expect(video?.value?.[0]).toBe(2);
    expect(video?.value?.[1]).toBe(1);
    expect(video?.value?.length).toBe(19);

    abort.abort();
    await waitViewers(server, 0);

    server.stop();
    const stopped = await fetch(`http://127.0.0.1:${port}/status`).then((item) => item.json());
    expect(stopped).toEqual({ live: false, viewers: 0 });
    expect(server.listening).toBe(true);
    await server.close();
    expect(server.listening).toBe(false);
  }, 60000);

  it('关键帧请求转发给渲染进程', async () => {
    const keyed = new LiveServer();
    let count = 0;
    keyed.onKey(() => { count += 1; });
    const port = await keyed.listen(0, '127.0.0.1');
    keyed.start();
    const response = await fetch(`http://127.0.0.1:${port}/key`, { method: 'POST' });
    expect(response.status).toBe(204);
    expect(count).toBe(1);
    await keyed.close();
  }, 60000);

  it('viewer resets an overloaded decoder and waits for a key frame', async () => {
    const target = new LiveServer();
    try {
      const port = await target.listen(0, '127.0.0.1');
      const page = await fetch(`http://127.0.0.1:${port}/`).then((item) => item.text());
      const script = page.match(/<script>([\s\S]*?)<\/script>/)?.[1];
      expect(script).toBeTruthy();
      const scriptText = script as string;
      const requests: string[] = [];
      const decoders: MockDecoder[] = [];
      class MockDecoder {
        state = 'configured';
        decodeQueueSize = 0;
        chunks: { type: string }[] = [];
        callbacks: { error: () => void; output: (frame: { close: () => void }) => void };
        constructor(callbacks: MockDecoder['callbacks']) {
          this.callbacks = callbacks;
          decoders.push(this);
        }
        configure(): void { this.state = 'configured'; }
        close(): void { this.state = 'closed'; }
        decode(chunk: { type: string }): void { this.chunks.push(chunk); }
      }
      const context = createContext({
        document: { getElementById: () => ({ width: 1280, height: 720, style: {}, getContext: () => ({ fillRect: vi.fn(), drawImage: vi.fn() }) }), addEventListener: vi.fn() },
        window: { innerWidth: 1280, innerHeight: 720, addEventListener: vi.fn() },
        VideoDecoder: MockDecoder,
        EncodedVideoChunk: class { type: string; constructor(init: { type: string }) { this.type = init.type; } },
        fetch: (url: string) => { requests.push(url); return Promise.resolve({ ok: false }); },
        setTimeout: vi.fn(),
        performance: { now: () => requests.length * 300 },
        TextDecoder,
        Uint8Array,
        Float32Array,
        DataView,
        atob,
      });
      runInContext(scriptText, context);
      runInContext('applyMeta({ codec: "avc1.64002A", channels: 2, sampleRate: 48000 }); handle(2, 1, 1, new Uint8Array([1]));', context);
      expect(decoders[0].chunks).toHaveLength(1);
      decoders[0].decodeQueueSize = 7;
      runInContext('handle(2, 0, 2, new Uint8Array([2])); handle(2, 0, 3, new Uint8Array([3]));', context);
      expect(decoders[0].state).toBe('closed');
      expect(decoders[0].chunks).toHaveLength(1);
      expect(requests.filter((url) => url === '/key')).toHaveLength(2);
      decoders[0].callbacks.error();
      expect(requests.filter((url) => url === '/key')).toHaveLength(2);
      runInContext('handle(2, 1, 4, new Uint8Array([4]));', context);
      expect(decoders[1].chunks.map((chunk) => chunk.type)).toEqual(['key']);
      expect(decoders[1].state).toBe('configured');
    } finally {
      await target.close();
    }
  });
});

function waitViewers(target: LiveServer, count: number): Promise<void> {
  return new Promise((resolve) => {
    const check = (): void => {
      if (target.viewers === count) {
        resolve();
        return;
      }
      setTimeout(check, 10);
    };
    check();
  });
}

import { createServer } from 'node:http';
import { playerPage } from './page.js';
import type { IncomingMessage, Server, ServerResponse } from 'node:http';
import type { LiveChunk } from '../../shared/types.js';

const headerBytes = 16;
const chunkMeta = 1;
const chunkVideo = 2;
const chunkAudio = 3;

export class LiveServer {
  private server?: Server;
  private live = false;
  private clients = new Set<ServerResponse>();
  private meta?: Buffer;
  private watcher?: (viewers: number) => void;
  private keyer?: () => void;

  onViewers(handler: (viewers: number) => void): void {
    this.watcher = handler;
  }

  onKey(handler: () => void): void {
    this.keyer = handler;
  }

  async listen(port: number, host = '0.0.0.0'): Promise<number> {
    if (this.server) return this.port();
    const server = createServer((request, response) => this.route(request, response));
    await new Promise<void>((resolve, reject) => {
      server.once('error', reject);
      server.listen(port, host, () => {
        server.off('error', reject);
        server.on('error', () => undefined);
        resolve();
      });
    });
    this.server = server;
    return this.port();
  }

  async close(): Promise<void> {
    this.live = false;
    this.meta = undefined;
    this.endStreams();
    const server = this.server;
    this.server = undefined;
    if (!server) return;
    await new Promise<void>((resolve) => server.close(() => resolve()));
  }

  get listening(): boolean {
    return Boolean(this.server);
  }

  get streaming(): boolean {
    return this.live;
  }

  get viewers(): number {
    return this.clients.size;
  }

  start(): void {
    this.live = true;
  }

  stop(): void {
    this.live = false;
    this.meta = undefined;
    this.endStreams();
  }

  writeChunk(chunk: LiveChunk): void {
    const frame = buildFrame(chunk);
    if (!frame) return;
    if (chunk.kind === 'meta') this.meta = frame;
    for (const client of [...this.clients]) this.send(client, frame);
  }

  private route(request: IncomingMessage, response: ServerResponse): void {
    const url = (request.url ?? '/').split('?')[0];
    if (url === '/') {
      response.writeHead(200, { 'content-type': 'text/html; charset=utf-8', 'cache-control': 'no-store' });
      response.end(playerPage());
      return;
    }
    if (url === '/status') {
      response.writeHead(200, { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' });
      response.end(JSON.stringify({ live: this.live, viewers: this.clients.size }));
      return;
    }
    if (url === '/stream') {
      this.stream(request, response);
      return;
    }
    if (url === '/key') {
      if (!this.live) {
        this.reject(response, 503, '直播未开始');
        return;
      }
      this.keyer?.();
      response.writeHead(204, { 'cache-control': 'no-store' });
      response.end();
      return;
    }
    response.writeHead(404, { 'content-type': 'text/plain; charset=utf-8' });
    response.end('未找到该地址');
  }

  private stream(request: IncomingMessage, response: ServerResponse): void {
    if (!this.live) {
      this.reject(response, 503, '直播未开始');
      return;
    }
    response.writeHead(200, {
      'content-type': 'application/octet-stream',
      'cache-control': 'no-store',
      connection: 'keep-alive',
      'x-content-type-options': 'nosniff',
    });
    response.flushHeaders();
    response.socket?.setNoDelay(true);
    this.clients.add(response);
    if (this.meta) response.write(this.meta);
    this.notify();
    this.keyer?.();
    const drop = (): void => {
      if (!this.clients.delete(response)) return;
      this.notify();
    };
    request.on('close', drop);
    request.on('error', drop);
  }

  private send(client: ServerResponse, frame: Buffer): void {
    if (client.writableEnded || client.destroyed) {
      if (this.clients.delete(client)) this.notify();
      return;
    }
    const socket = client.socket;
    if (socket && socket.writableLength > 16 * 1024 * 1024) {
      this.clients.delete(client);
      this.notify();
      try {
        client.destroy();
      } catch {
        void 0;
      }
      return;
    }
    client.write(frame);
  }

  private endStreams(): void {
    for (const client of [...this.clients]) {
      this.clients.delete(client);
      try {
        client.end();
      } catch {
        void 0;
      }
    }
    this.notify();
  }

  private notify(): void {
    this.watcher?.(this.clients.size);
  }

  private reject(response: ServerResponse, code: number, text: string): void {
    response.writeHead(code, { 'content-type': 'text/plain; charset=utf-8', 'cache-control': 'no-store' });
    response.end(text);
  }

  private port(): number {
    const address = this.server?.address();
    return address && typeof address === 'object' ? address.port : 0;
  }
}

function buildFrame(chunk: LiveChunk): Buffer | undefined {
  if (chunk.kind === 'meta') {
    const description = chunk.description ? Buffer.from(chunk.description).toString('base64') : '';
    const payload = Buffer.from(JSON.stringify({
      codec: chunk.codec,
      width: chunk.width,
      height: chunk.height,
      fps: chunk.fps,
      channels: chunk.channels,
      sampleRate: chunk.sampleRate,
      description,
    }), 'utf8');
    return packFrame(chunkMeta, 0, 0, payload);
  }
  const payload = Buffer.from(chunk.data);
  if (!payload.length) return undefined;
  return chunk.kind === 'video'
    ? packFrame(chunkVideo, chunk.key ? 1 : 0, chunk.timestampUs, payload)
    : packFrame(chunkAudio, 0, chunk.timestampUs, payload);
}

function packFrame(kind: number, flags: number, timestampUs: number, payload: Buffer): Buffer {
  const head = Buffer.alloc(headerBytes);
  head[0] = kind;
  head[1] = flags;
  head.writeDoubleLE(timestampUs, 4);
  head.writeUInt32LE(payload.length, 12);
  return Buffer.concat([head, payload]);
}

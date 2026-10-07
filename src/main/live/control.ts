import { liveEnv } from '../store/env.js';
import { LiveServer } from './server.js';
import type { LiveChunk, LiveOptions, LiveState } from '../../shared/types.js';

let server: LiveServer | undefined;
let state: LiveState = 'idle';
let error: string | undefined;
let watcher: (() => void) | undefined;
let viewerCount: ((count: number) => void) | undefined;
let keyer: (() => void) | undefined;

export function onLiveChange(listener: () => void): void {
  watcher = listener;
}

export function onLiveViewers(listener: (count: number) => void): void {
  viewerCount = listener;
}

export function onLiveKey(listener: () => void): void {
  keyer = listener;
}

export function pushLiveChunk(chunk: LiveChunk): void {
  server?.writeChunk(chunk);
}

export function liveOptions(): LiveOptions {
  return { port: liveEnv().port };
}

export function liveInfo(): { liveState: LiveState; liveError?: string; liveUrl?: string; liveOptions: LiveOptions } {
  return {
    liveState: state,
    liveError: error,
    liveUrl: server?.listening ? `http://localhost:${liveEnv().port}/` : undefined,
    liveOptions: liveOptions(),
  };
}

export function openLive(): void {
  if (server) return;
  const next = new LiveServer();
  next.onViewers((count) => viewerCount?.(count));
  next.onKey(() => keyer?.());
  server = next;
  void next
    .listen(liveEnv().port)
    .then(() => {
      if (state === 'error') {
        state = 'idle';
        error = undefined;
      }
      notify();
    })
    .catch((cause) => {
      state = 'error';
      error = `直播网页服务启动失败：${messageOf(cause)}`;
      notify();
    });
}

export async function closeLive(): Promise<void> {
  await stopLive();
  const current = server;
  server = undefined;
  if (current) await current.close().catch(() => undefined);
  notify();
}

export async function startLive(): Promise<void> {
  await stopLive();
  error = undefined;
  openLive();
  const target = server;
  if (!target) {
    state = 'error';
    error = '直播网页服务不可用';
    notify();
    return;
  }
  try {
    if (!target.listening) await target.listen(liveEnv().port);
    target.start();
    state = 'live';
  } catch (cause) {
    target.stop();
    state = 'error';
    error = messageOf(cause);
  }
  notify();
}

export async function stopLive(): Promise<void> {
  server?.stop();
  state = 'idle';
  notify();
}

function notify(): void {
  watcher?.();
}

function messageOf(cause: unknown): string {
  return cause instanceof Error ? cause.message : String(cause);
}


import { nsoEnv } from '../store/env.js';
import { getJson } from './http.js';
import type { NsoBackendStatus } from '../../shared/types.js';

const probeTimeoutMs = 8000;

export function backendConfigUrl(base = nsoEnv().backendUrl): string {
  return `${base.trim().replace(/\/+$/, '')}/config`;
}

export async function checkNsoBackend(url = nsoEnv().backendUrl, timeoutMs = probeTimeoutMs): Promise<NsoBackendStatus> {
  const base = url.trim().replace(/\/+$/, '');
  const startedAt = Date.now();
  try {
    const config = await getJson(backendConfigUrl(base), {}, timeoutMs);
    const version = String(config.nso_version ?? '').trim();
    return {
      url: base,
      state: 'online',
      version: version || undefined,
      latencyMs: Date.now() - startedAt,
    };
  } catch (error) {
    return {
      url: base,
      state: 'offline',
      latencyMs: Date.now() - startedAt,
      error: messageOf(error),
    };
  }
}

function messageOf(error: unknown): string {
  const text = error instanceof Error ? error.message : String(error ?? '');
  return text.split(/\r?\n/)[0]?.trim().slice(0, 200) || '无法连接 znca 实例';
}

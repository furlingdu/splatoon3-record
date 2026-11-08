import type { ReactElement } from 'react';
import type { NsoBackendStatus } from '../../shared/types.js';

function displayUrl(url: string): string {
  try {
    const parsed = new URL(url);
    return `${parsed.host}${parsed.pathname}`.replace(/\/+$/, '');
  } catch {
    return url;
  }
}

function latencyText(ms?: number): string {
  if (ms === undefined || !Number.isFinite(ms)) return '';
  return ms >= 1000 ? `${(ms / 1000).toFixed(1)}s` : `${Math.max(1, Math.round(ms))}ms`;
}

function statusText(status: NsoBackendStatus | undefined, checking: boolean): string {
  if (checking) return '正在检测 znca 校验服务…';
  if (status?.state === 'online') {
    const version = status.version ? ` · NSO ${status.version}` : '';
    const latency = latencyText(status.latencyMs);
    return `znca 校验服务可用${version}${latency ? ` · ${latency}` : ''}`;
  }
  return `znca 校验服务不可用${status?.error ? `：${status.error}` : ''}`;
}

function backendStatusBar(props: { status?: NsoBackendStatus; checking: boolean; onRetry: () => void }): ReactElement {
  const state = props.checking ? 'checking' : props.status?.state ?? 'offline';
  return (
    <div className={`backend-status is-${state}`} role="status" aria-live="polite">
      <span className="backend-dot" aria-hidden="true" />
      <span className="backend-text">{statusText(props.status, props.checking)}</span>
      {props.status?.url ? <span className="backend-url" title={props.status.url}>{displayUrl(props.status.url)}</span> : null}
      <mdui-button variant="text" disabled={props.checking} onClick={props.onRetry}>重新检测</mdui-button>
    </div>
  );
}

export { backendStatusBar as NsoBackendStatusBar };

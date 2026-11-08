import { useCallback, useEffect, useRef, useState } from 'react';
import { snackbar } from 'mdui/functions/snackbar.js';
import { errorText } from './error.js';
import type { NsoBackendStatus, NsoRetryState } from '../../shared/types.js';

export interface BackendCheck {
  status?: NsoBackendStatus;
  checking: boolean;
  check: () => Promise<NsoBackendStatus | undefined>;
}

export interface NsoLoginGate {
  backend: BackendCheck;
  block?: NsoBackendStatus;
  start: (accountId?: string) => Promise<void>;
  confirm: () => Promise<void>;
  cancel: () => void;
}

export function useBackendCheck(refreshKey?: string): BackendCheck {
  const [status, setStatus] = useState<NsoBackendStatus>();
  const [checking, setChecking] = useState(true);
  const sequence = useRef(0);

  const check = useCallback(async (): Promise<NsoBackendStatus | undefined> => {
    const current = sequence.current + 1;
    sequence.current = current;
    setChecking(true);
    try {
      const next = await window.recordApi.checkNsoBackend();
      if (sequence.current !== current) return next;
      setStatus(next);
      return next;
    } catch (error) {
      if (sequence.current !== current) return undefined;
      const offline: NsoBackendStatus = { url: '', state: 'offline', latencyMs: 0, error: errorText(error) };
      setStatus(offline);
      return offline;
    } finally {
      if (sequence.current === current) setChecking(false);
    }
  }, []);

  useEffect(() => {
    void check();
  }, [check, refreshKey]);

  return { status, checking, check };
}

export function useNsoLoginGate(refreshKey?: string): NsoLoginGate {
  const backend = useBackendCheck(refreshKey);
  const [block, setBlock] = useState<NsoBackendStatus>();
  const target = useRef<string | undefined>(undefined);

  const start = async (accountId?: string): Promise<void> => {
    const checked = await backend.check();
    if (checked?.state === 'offline') {
      target.current = accountId;
      setBlock(checked);
      return;
    }
    await openNsoLogin(accountId);
  };

  const confirm = async (): Promise<void> => {
    const accountId = target.current;
    target.current = undefined;
    setBlock(undefined);
    await openNsoLogin(accountId);
  };

  const cancel = (): void => {
    target.current = undefined;
    setBlock(undefined);
  };

  return { backend, block, start, confirm, cancel };
}

export function retryText(retry?: NsoRetryState): string {
  return retry ? `凭证获取失败，正在重试 ${retry.attempt}/${retry.max}：${retry.error}` : '';
}

async function openNsoLogin(accountId?: string): Promise<void> {
  await window.recordApi.openNsoLogin(accountId).catch((error) => snackbar({ message: errorText(error) }));
}

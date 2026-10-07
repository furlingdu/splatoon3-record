import { useEffect, useState, type ReactElement } from 'react';
import { activeStream } from '../lib/device.js';
import { useElementEvent, targetChecked } from '../lib/event.js';
import { useSession } from '../lib/session.js';
import type { RecordSettings } from '../../shared/types.js';

let monitorOn = false;
let monitorCtx: AudioContext | undefined;
let monitorSource: MediaStreamAudioSourceNode | undefined;
let monitorFrom: MediaStream | undefined;
let gesturesBound = false;
const monitorListeners = new Set<(on: boolean) => void>();

function emitMonitor(): void {
  for (const listener of monitorListeners) listener(monitorOn);
}

function markMonitor(): void {
  window.__monitor = { on: monitorOn, state: monitorCtx?.state ?? 'closed', bound: Boolean(monitorSource) };
}

function syncMonitor(): void {
  const stream = activeStream();
  const wanted = monitorOn && stream && stream.getAudioTracks().some((track) => track.readyState === 'live') ? stream : undefined;
  if (monitorFrom !== wanted) {
    monitorSource?.disconnect();
    monitorSource = undefined;
    monitorFrom = wanted;
    if (wanted) {
      if (!monitorCtx) monitorCtx = new AudioContext({ latencyHint: 'interactive' });
      monitorSource = monitorCtx.createMediaStreamSource(wanted);
      monitorSource.connect(monitorCtx.destination);
    }
  }
  if (wanted) void monitorCtx?.resume().catch(() => undefined);
  else if (monitorCtx) {
    const closing = monitorCtx;
    monitorCtx = undefined;
    void closing.close().catch(() => undefined);
  }
  markMonitor();
}

function resumeMonitor(): void {
  if (monitorOn && monitorCtx?.state === 'suspended') void monitorCtx.resume().then(markMonitor).catch(() => undefined);
}

function bindGestures(): void {
  if (gesturesBound) return;
  gesturesBound = true;
  document.addEventListener('pointerdown', resumeMonitor, true);
  document.addEventListener('keydown', resumeMonitor, true);
}

export function setMonitorEnabled(on: boolean): void {
  if (monitorOn === on) return;
  monitorOn = on;
  if (on) bindGestures();
  syncMonitor();
  emitMonitor();
}

function useMonitorOn(): boolean {
  const [on, setOn] = useState(monitorOn);
  useEffect(() => {
    const listener = (next: boolean): void => setOn(next);
    monitorListeners.add(listener);
    listener(monitorOn);
    return () => {
      monitorListeners.delete(listener);
    };
  }, []);
  return on;
}

function monitorSwitch(props: { settings?: RecordSettings }): ReactElement {
  const session = useSession();
  const on = useMonitorOn();
  const switchRef = useElementEvent<HTMLElement>('change', (event) => {
    const checked = targetChecked(event);
    if (checked === on) return;
    setMonitorEnabled(checked);
    if (props.settings) void window.recordApi.saveSettings({ ...props.settings, monitorAudio: checked });
  });

  return (
    <span className="monitor-inline">
      <span>声音返听</span>
      <mdui-switch checked={on} disabled={!session.hasAudio} ref={switchRef} name="monitorAudio" />
      {session.hasAudio ? null : <em className="preview-monitor-hint">未启用音频</em>}
    </span>
  );
}

export { monitorSwitch as MonitorSwitch, syncMonitor };

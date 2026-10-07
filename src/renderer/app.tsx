import { useEffect, useRef, useState } from 'react';
import { createRoot } from 'react-dom/client';
import { snackbar } from 'mdui/functions/snackbar.js';
import 'mdui/mdui.css';
import 'mdui';
import { setColorScheme } from 'mdui/functions/setColorScheme.js';
import './styles/base.css';
import './styles/fonts.css';
import './styles/layout.css';
import './styles/page.css';
import './styles/setup.css';
import { Layout } from './components/layout.js';
import { PageView } from './routes.js';
import { SetupApp } from './pages/setup.js';
import { useSession } from './lib/session.js';
import { previewStream } from './lib/device.js';
import { setMonitorEnabled, syncMonitor } from './components/monitor.js';
import { markSelectClick } from './lib/event.js';
import type { AppStatus, PageName } from '../shared/types.js';

setColorScheme('#4285F4');

function useAppStatus(): AppStatus | undefined {
  const [status, setStatus] = useState<AppStatus>();
  useEffect(() => {
    void window.recordApi.getStatus().then(setStatus);
    return window.recordApi.getEvents(setStatus);
  }, []);
  return status;
}

function mainApp(): React.ReactNode {
  const status = useAppStatus();
  const [page, setPage] = useState<PageName>('status');
  const prevState = useRef<string | undefined>(undefined);
  const session = useSession(status, Boolean(status?.setupDone));

  useEffect(() => {
    const host = window as Window & { previewSource?: () => MediaStream | undefined };
    host.previewSource = previewStream;
    return () => { delete host.previewSource; };
  }, []);

  useEffect(() => {
    setMonitorEnabled(Boolean(status?.settings.monitorAudio));
  }, [status?.settings.monitorAudio]);
  useEffect(() => {
    syncMonitor();
  }, [session.hasAudio, session.revision]);

  useEffect(() => {
    document.addEventListener('click', markSelectClick, true);
    return () => document.removeEventListener('click', markSelectClick, true);
  }, []);
  useEffect(() => {
    const state = status?.nsoState;
    if (state === 'connecting' && prevState.current !== 'connecting') snackbar({ message: '正在登录 Nintendo 账号…' });
    prevState.current = state;
  }, [status?.nsoState]);

  return (
    <Layout page={page} onNavigate={setPage}>
      <div key={page} className="page-transition-wrapper">
        <PageView page={page} status={status} />
      </div>
    </Layout>
  );
}

const PreviewApp = (): React.ReactElement => {
  const videoRef = useRef<HTMLVideoElement | null>(null);
  useEffect(() => {
    const opener = window.opener as (Window & { previewSource?: () => MediaStream | undefined }) | null;
    const video = videoRef.current;
    if (!video) return undefined;
    let sourceTrack: MediaStreamTrack | undefined;
    let clone: MediaStreamTrack | undefined;
    const sync = (): void => {
      let next: MediaStreamTrack | undefined;
      try {
        next = opener?.previewSource?.()?.getVideoTracks()[0];
      } catch {
        next = undefined;
      }
      if (next === sourceTrack && clone?.readyState === 'live') return;
      clone?.stop();
      sourceTrack = next?.readyState === 'live' ? next : undefined;
      clone = sourceTrack?.clone();
      video.srcObject = clone ? new MediaStream([clone]) : null;
      if (clone) void video.play().catch(() => undefined);
    };
    sync();
    const timer = window.setInterval(sync, 500);
    return () => {
      window.clearInterval(timer);
      clone?.stop();
      video.srcObject = null;
    };
  }, []);
  return <video ref={videoRef} muted playsInline autoPlay style={{ display: 'block', width: '100vw', height: '100vh', objectFit: 'contain', background: '#000' }} />;
};
const MainApp = mainApp;

function dismissBoot(): void {
  const layer = document.getElementById('boot');
  if (!layer) return;
  layer.classList.add('is-hidden');
  window.setTimeout(() => layer.remove(), 300);
}

function bootDismiss(): null {
  useEffect(() => {
    const frame = window.requestAnimationFrame(() => dismissBoot());
    return () => window.cancelAnimationFrame(frame);
  }, []);
  return null;
}

const BootDismiss = bootDismiss;

const params = new URLSearchParams(window.location.search);
const root = createRoot(document.getElementById('root') as HTMLElement);
if (params.has('preview')) {
  document.title = '预览窗口';
  document.getElementById('boot')?.remove();
  document.body.style.cssText = 'margin:0;background:#000;overflow:hidden';
  root.render(<PreviewApp />);
} else if (params.has('setup')) root.render(<><SetupApp /><BootDismiss /></>);
else root.render(<><MainApp /><BootDismiss /></>);

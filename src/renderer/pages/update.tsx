import { useEffect, useState, type ReactElement } from 'react';
import { snackbar } from 'mdui/functions/snackbar.js';
import { targetChecked, useElementEvent } from '../lib/event.js';
import { iconSvg } from '../lib/icons.js';
import type { AppStatus, RecordSettings, UpdateState } from '../../shared/types.js';

function updatePage(props: { status?: AppStatus }): ReactElement {
  const settings = props.status?.settings;
  const [state, setState] = useState<UpdateState>();
  const [busy, setBusy] = useState(false);
  const switchRef = useElementEvent<HTMLElement>('change', (event) => {
    const name = nameOf(event);
    const checked = targetChecked(event);
    if (!settings || Boolean((settings as unknown as Record<string, unknown>)[name]) === checked) return;
    void window.recordApi.saveSettings({ ...settings, [name]: checked } as RecordSettings).catch(() => snackbar({ message: '保存设置失败' }));
  });
  const start = async (manual: boolean): Promise<UpdateState | undefined> => {
    if (manual) setBusy(true);
    try {
      let next = await window.recordApi.updateState();
      if (!next.available) next = await window.recordApi.updateCheck();
      if (next.available && next.phase !== 'ready' && next.phase !== 'downloading') next = await window.recordApi.updateDownload();
      return next;
    } catch (cause) {
      snackbar({ message: errorOf(cause) });
      return undefined;
    } finally {
      if (manual) setBusy(false);
    }
  };

  useEffect(() => {
    let alive = true;
    const off = window.recordApi.onUpdate((next) => { if (alive) setState(next); });
    void start(false).then((next) => { if (alive && next) setState(next); });
    return () => { alive = false; off(); };
  }, []);

  const phase = state?.phase ?? 'idle';
  const percent = Math.round((state?.progress ?? 0) * 100);
  return (
    <div className="page-body">
      <h2 className="page-title">更新</h2>

      <div className="about-card">
        <div className="about-block">
          <div>
            <div className="about-name">{state?.available ? `发现新版本 ${state.latest}` : `当前版本 ${state?.current ?? ''}`}</div>
            <div className="about-sub">{updateHint(state)}</div>
          </div>
        </div>
        {phase === 'downloading' || phase === 'installing' ? <mdui-linear-progress value={state?.progress ?? 0} /> : null}
        {phase === 'downloading' ? <span className="status-value">已下载 {percent}%，{sizeText(state?.received)} / {sizeText(state?.total)}</span> : null}
        {state?.available && state.notes ? <pre className="update-notes">{state.notes}</pre> : null}
        <div className="status-actions">
          {state?.available && phase === 'ready' ? (
            <mdui-button variant="filled" onClick={() => void window.recordApi.updateInstall()}>
              <mdui-icon slot="icon" dangerouslySetInnerHTML={{ __html: iconSvg('update') }} />
              立即安装
            </mdui-button>
          ) : null}
          <mdui-button variant={state?.available && phase === 'ready' ? 'outlined' : 'filled'} disabled={busy || phase === 'downloading' || phase === 'installing'} onClick={() => void start(true)}>
            <mdui-icon slot="icon" dangerouslySetInnerHTML={{ __html: iconSvg('refresh') }} />
            {busy || phase === 'checking' ? '正在检查更新' : '检查更新'}
          </mdui-button>
        </div>
      </div>

      <div className="about-card">
        <div className="form-switch form-field-wide">
          <span>网络加速<em className="form-note">开启后将使用加速源获取更新包</em></span>
          <mdui-switch checked={Boolean(settings?.updateProxy)} ref={switchRef} name="updateProxy" />
        </div>
        <div className="form-switch form-field-wide">
          <span>自动检查更新<em className="form-note">开启后启动应用时自动检查更新并提示</em></span>
          <mdui-switch checked={Boolean(settings?.updateCheck)} ref={switchRef} name="updateCheck" />
        </div>
      </div>
    </div>
  );
}

function updateHint(state?: UpdateState): string {
  if (!state) return '正在读取更新状态…';
  if (state.phase === 'checking') return '正在检查 GitHub 上的最新发行版…';
  if (state.phase === 'downloading') return `正在下载 ${state.latest ?? ''} 安装包`;
  if (state.phase === 'installing') return '正在启动安装程序，应用即将退出';
  if (state.phase === 'error') return state.error || '更新失败，请稍后重试';
  if (state.phase === 'ready') return '安装包已下载完成，点击立即安装后会退出应用并启动安装程序';
  if (state.available) return '正在准备下载更新包…';
  return '已是最新版本';
}

function sizeText(bytes?: number): string {
  const value = Number(bytes ?? 0);
  if (!Number.isFinite(value) || value <= 0) return '0 MB';
  return `${(value / 1048576).toFixed(1)} MB`;
}

function nameOf(event: Event): string {
  const current = event.currentTarget as HTMLElement | undefined;
  const target = event.target as HTMLElement | undefined;
  return current?.getAttribute('name') || target?.getAttribute('name') || '';
}

function errorOf(cause: unknown): string {
  const text = (cause instanceof Error ? cause.message : String(cause ?? '')).replace(/^Error invoking remote method '[^']*':\s*(Error:\s*)?/, '').trim();
  return text || '更新失败';
}

export { updatePage as UpdatePage };

import { useEffect, useRef, useState, type ReactElement } from 'react';
import { snackbar } from 'mdui/functions/snackbar.js';
import { Preview } from '../components/preview.js';
import { StatusItem } from '../components/item.js';
import { useSession } from '../lib/session.js';
import { mountLive, setBlurEnabled, setDebugBoxes, startLiveStream, stopLiveStream, unmountLive, useLive } from '../lib/live.js';
import { iconSvg } from '../lib/icons.js';
import { useElementEvent } from '../lib/event.js';
import type { AppStatus, RecordSettings } from '../../shared/types.js';

const stateNames: Record<string, string> = {
  idle: '未直播',
  live: '直播中',
  error: '异常',
};

function livePage(props: { status?: AppStatus }): ReactElement {
  const status = props.status;
  const session = useSession();
  const live = useLive(status?.settings);
  const settings = status?.settings;
  const hostRef = useRef<HTMLDivElement | null>(null);
  const shiftRef = useRef(false);
  const [busy, setBusy] = useState(false);
  const options = status?.liveOptions;
  const watch = status?.liveUrl || '';
  const starting = live.starting && !live.streaming;
  const cpuDetect = live.blurOn && live.device === 'CPU';

  useEffect(() => {
    const host = hostRef.current;
    if (!host) return undefined;
    mountLive(host);
    return () => unmountLive();
  }, []);

  useEffect(() => {
    if (status?.liveState === 'error' && live.streaming) void stopLiveStream();
  }, [status?.liveState, live.streaming]);

  useEffect(() => {
    const markShift = (event: Event): void => {
      if (!(event.target as HTMLElement | undefined)?.closest?.('mdui-switch[name="blurNickname"]')) return;
      shiftRef.current = Boolean((event as MouseEvent).shiftKey);
    };
    document.addEventListener('click', markShift, true);
    return () => document.removeEventListener('click', markShift, true);
  }, []);

  const save = (part: Partial<RecordSettings>): void => {
    const current = settings;
    if (!current) {
      void window.recordApi.getStatus().then((latest) => {
        if (latest?.settings) void window.recordApi.saveSettings({ ...latest.settings, ...part });
      });
      return;
    }
    void window.recordApi.saveSettings({ ...current, ...part }).catch(() => snackbar({ message: '保存设置失败' }));
  };

  const blurRef = useElementEvent<HTMLElement>('change', (event) => {
    const target = event.target as HTMLInputElement | undefined;
    const checked = Boolean(target?.checked);
    setDebugBoxes(shiftRef.current && checked);
    shiftRef.current = false;
    if (checked === live.blurOn) return;
    setBlurEnabled(checked);
    save({ blurNickname: checked });
  });

  const toggleLive = (): void => {
    if (!settings) return;
    setBusy(true);
    const streaming = live.streaming;
    const task = streaming ? stopLiveStream() : startLiveStream(settings);
    void task
      .then(() => snackbar({ message: streaming ? '已停止直播' : '已开始直播' }))
      .catch((cause) => snackbar({ message: errorOf(cause) }))
      .finally(() => setBusy(false));
  };

  const copy = (text: string): void => {
    if (!text) return;
    void window.recordApi.copyText(text).then(() => snackbar({ message: '直播地址已复制' }));
  };

  return (
    <div className="page-body">
      <h2 className="page-title">直播</h2>
      <div className="live-grid">
        <div className="live-pane">
          <span className="live-caption">采集画面</span>
          <Preview session={session} settings={settings} pip={false} />
        </div>
        <div className="live-pane">
          <span className="live-caption">直播画面</span>
          <div className="live-stage" ref={hostRef} />
        </div>
      </div>
      <div className="status-actions">
        <mdui-button variant={live.streaming ? 'outlined' : 'filled'} disabled={busy} onClick={toggleLive}>
          {starting ? '正在启动' : live.streaming ? '停止直播' : '开始直播'}
        </mdui-button>
      </div>
      <h3 className="section-title">直播与打码</h3>
      <div className="form-grid">
        <div className="form-switch form-field-wide">
          <span>昵称自动打码<em className="form-note">开启按钮后，将在本地进行画面后处理。对画面中展示的昵称进行模糊打码处理。适用于直播用户。</em><em className="form-note">由于实时检测存在一定的性能需求，推荐搭载了独立显卡的用户进行使用。</em></span>
          <mdui-switch checked={live.blurOn} ref={blurRef} name="blurNickname" />
        </div>
      </div>
      {live.debugBoxes ? <div className="status-note">检测框调试已开启，直播画面会叠加 YOLO 检测框。</div> : null}
      <h3 className="section-title">直播地址</h3>
      <div className="status-grid">
        <div className="status-row">
          <span className="status-label">观看地址</span>
          <span className="status-value live-address">{watch || '等待主进程就绪'}</span>
          <mdui-button-icon disabled={!watch} onClick={() => copy(watch)}>
            <mdui-icon dangerouslySetInnerHTML={{ __html: iconSvg('copy') }} />
          </mdui-button-icon>
        </div>
        <StatusItem label="端口" value={options ? `${options.port}` : '-'} />
      </div>
      <div className="status-note">请将下面的观看地址填入OBS内（点击新增源-&gt;浏览器），皆可开始画面直播。</div>
      <div className="status-note">同时直播码率、分辨率跟随设置中设定的画面进行直播。</div>
      <h3 className="section-title">直播状态</h3>
      <div className="status-grid">
        <StatusItem label="直播状态" value={starting ? '正在启动' : stateNames[status?.liveState || 'idle'] || '未直播'} />
        <StatusItem label="观看连接" value={`${live.viewers} 个`} />
        <StatusItem label="编码器" value={live.codec || (live.streaming ? '等待连接' : '未直播')} />
        <StatusItem label="直播码率" value={live.rate ? `${live.rate} Mbps` : live.streaming ? '等待连接' : '未直播'} />
        <StatusItem label="推理设备" value={live.blurOn ? live.device || '正在启动推理后端' : '未开启打码'} />
        <StatusItem label="打码目标" value={live.blurOn ? `${live.boxes} 个` : '未开启'} />
        <StatusItem label="画面帧率" value={live.drawFps ? `${live.drawFps} fps` : '未运行'} />
        <StatusItem label="推理帧率" value={live.blurOn ? `${live.inferFps} fps` : '未开启'} />
        {status?.liveError ? <StatusItem label="直播错误" value={status.liveError} /> : null}
        {live.error ? <StatusItem label="打码错误" value={live.error} /> : null}
      </div>
      {status?.liveState === 'error' ? <div className="status-warn">直播已中断，请检查端口是否被占用后重新开始直播</div> : null}
      {cpuDetect ? <div className="status-warn">推理后端当前跑在 CPU 上，帧率会明显下降，请检查显卡驱动是否支持可用的硬件推理后端</div> : null}
    </div>
  );
}

function errorOf(cause: unknown): string {
  const text = (cause instanceof Error ? cause.message : String(cause ?? '')).replace(/^Error invoking remote method '[^']*':\s*(Error:\s*)?/, '').trim();
  return text || '直播启动失败';
}

export { livePage as LivePage };

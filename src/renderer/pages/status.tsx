import { snackbar } from 'mdui/functions/snackbar.js';
import { MonitorSwitch } from '../components/monitor.js';
import { Preview } from '../components/preview.js';
import { StatusItem } from '../components/item.js';
import { startCapture, stopCapture, retryCapture, useSession } from '../lib/session.js';
import { formatText, resolutionText } from '../../shared/capture.js';
import { durationText, kindNames, resultText, ruleName } from '../../shared/nso.js';
import { type MouseEvent as ReactMouseEvent, type ReactElement } from 'react';
import type { AppStatus } from '../../shared/types.js';

const stateNames: Record<string, string> = {
  unbound: '未绑定',
  connecting: '登录中',
  connected: '已连接',
  expired: '已过期，请重新登录',
  error: '连接异常',
};

function statusPage(props: { status?: AppStatus }): ReactElement {
  const status = props.status;
  const session = useSession();
  const settings = status?.settings;
  const recordState = session.recordState;
  const recent = status?.recentMatches ?? [];
  const processing = new Set(status?.processingMatchIds ?? []);
  const sizeMissed = Boolean(settings) && session.width > 0 && !session.applying && (session.width !== settings?.width || session.height !== settings?.height);

  const exportDebug = (): void => {
    void window.recordApi.debugExportLast()
      .then((output) => snackbar({ message: output ? '已导出最近 1 分钟画面' : '导出失败：缓存中没有可用的画面分段' }))
      .catch(() => snackbar({ message: '导出失败：缓存中没有可用的画面分段' }));
  };

  const stopOrDebug = (event: ReactMouseEvent<HTMLElement>): void => {
    void stopCapture().then(() => { if (event.shiftKey) exportDebug(); });
  };

  return (
    <div className="page-body">
      <h2 className="page-title">状态</h2>
      <Preview session={session} settings={settings} />
      <div className="status-actions">
        <mdui-button variant="filled" disabled={recordState === 'recording'} onClick={() => void startCapture()}>开始录制</mdui-button>
        <mdui-button variant="outlined" disabled={recordState === 'idle'} onClick={stopOrDebug}>停止录制</mdui-button>
        <mdui-button variant="filled" disabled={!session.width || Boolean(session.error)} onClick={() => void window.recordApi.openPreview()}>打开预览窗口</mdui-button>
        {session.error ? <mdui-button variant="text" onClick={() => void retryCapture()}>重试采集</mdui-button> : null}
        <MonitorSwitch settings={settings} />
      </div>
      {recordState === 'recording' ? <div className="record-tip">正在录制对局中……</div> : null}
      <h3 className="section-title">录制</h3>
      <div className="status-grid">
        <StatusItem label="分辨率" value={session.width > 0 ? resolutionText(session.width, session.height) : '未开始采集'} />
        <StatusItem label="帧率" value={session.fps > 0 ? `${Number(session.fps.toFixed(2))} fps` : '未开始采集'} />
        <StatusItem label="采集格式" value={formatText(session.format)} />
        <StatusItem label="硬件加速" value={status?.hwAccel ? `${status.hwAccel} 硬件解码` : '未启用'} />
        <StatusItem label="编码器" value={status?.encoder || '-'} />
        {session.recordError ? <StatusItem label="错误信息" value={session.recordError} /> : null}
      </div>
      {sizeMissed ? <div className="status-warn">采集卡未接受设置页的分辨率，当前输出 {resolutionText(session.width, session.height)}</div> : null}
      <h3 className="section-title">连接</h3>
      <div className="status-grid">
        <StatusItem label="NSO 登录" value={stateNames[status?.nsoState || 'unbound']} />
        {status?.nsoState === 'error' && status?.nsoError ? <StatusItem label="失败原因" value={status.nsoError} /> : null}
        <StatusItem label="QQBot 连接" value={stateNames[status?.qqState || 'unbound']} />
        <StatusItem label="自动推送" value={status?.settings.autoPush ? '已开启' : '已关闭'} />
      </div>
      {status?.nsoState === 'connecting' ? <mdui-linear-progress indeterminate className="connect-loading" /> : null}
      <h3 className="section-title">最近一局</h3>
      {recent.length ? (
        <div className="recent-grid">
          {recent.map((match) => (
            <StatusItem key={match.matchId} label={kindNames[match.kind]}
              value={`${ruleName(match.rule)} · ${new Date(match.endAt).toLocaleString('zh-CN')} · ${durationText(match.duration)} · ${match.isDisconnected ? '掉线' : resultText(match.result)} · ${processing.has(match.matchId) ? '正在保存' : match.videoPath ? '已归档' : '未录制'}`} />
          ))}
        </div>
      ) : (
        <div className="empty-tip">{status?.nsoState === 'unbound' ? '暂未登录NSO，无法获取数据' : '正在获取 NSO 对局数据'}</div>
      )}
    </div>
  );
}

export { statusPage as StatusPage };

import { useEffect, useState, type ReactElement } from 'react';
import QRCode from 'qrcode';
import { StatusItem } from '../components/item.js';
import { NsoApiNotice } from '../components/notice.js';
import type { AppStatus } from '../../shared/types.js';

const stateNames: Record<string, string> = {
  unbound: '未绑定',
  connecting: '等待操作',
  connected: '已连接',
  expired: '已过期，需要重新登录',
  error: '连接异常',
};

function bindingPage(props: { status?: AppStatus }): ReactElement {
  const status = props.status;
  const [qrImage, setQrImage] = useState('');
  useEffect(() => {
    const url = status?.qrCode || '';
    if (!url) { setQrImage(''); return; }
    QRCode.toDataURL(url, { width: 440, margin: 1 }).then(setQrImage).catch(() => setQrImage(''));
  }, [status?.qrCode]);

  return (
    <div className="page-body">
      <h2 className="page-title">绑定</h2>
      <h3 className="section-title">Nintendo Switch Online</h3>
      <NsoApiNotice />
      <div className="bind-row">
        <mdui-button variant="filled" disabled={status?.nsoState === 'connected' || status?.nsoState === 'connecting'} onClick={() => window.recordApi.openNsoLogin()}>登录 Nintendo 账号</mdui-button>
        <mdui-button variant="outlined" disabled={status?.nsoState === 'unbound'} onClick={() => window.recordApi.unbindNso()}>解除 NSO 绑定</mdui-button>
      </div>
      <div className="status-grid">
        <StatusItem label="NSO 状态" value={stateNames[status?.nsoState || 'unbound']} />
      </div>
      {status?.nsoError ? <div className="bind-info">失败原因：{status.nsoError}</div> : null}
      <h3 className="section-title">QQBot</h3>
      <div className="bind-info">请点击下方按钮获取机器人绑定二维码，并跟随指引创建机器人。当你创建完毕后，请在私聊窗口中发送/bind以绑定用户。</div>
      <div className="bind-row">
        <mdui-button variant="filled" disabled={status?.qqState === 'connecting' || status?.qqState === 'connected'} onClick={() => window.recordApi.startQqLogin()}>获取绑定机器人二维码</mdui-button>
        <mdui-button variant="outlined" disabled={status?.qqState === 'unbound'} onClick={() => window.recordApi.unbindQq()}>解除 QQBot 绑定</mdui-button>
      </div>
      <div className="status-grid">
        <StatusItem label="QQBot 状态" value={stateNames[status?.qqState || 'unbound']} />
        <StatusItem label="推送用户" value={status?.qqOwner ? '已绑定' : '未通过 /bind 绑定'} />
      </div>
      {qrImage ? (
        <div className="qr-box">
          <img className="qr-image" src={qrImage} alt="QQBot 绑定二维码" />
          <span className="bind-info">请使用创建机器人的 QQ 扫描该二维码完成授权</span>
        </div>
      ) : null}
    </div>
  );
}

export { bindingPage as BindingPage };

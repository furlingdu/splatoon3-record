import { useEffect, useState, type ReactElement } from 'react';
import QRCode from 'qrcode';
import { snackbar } from 'mdui/functions/snackbar.js';
import { StatusItem } from '../components/item.js';
import { NsoApiNotice } from '../components/notice.js';
import { useElementEvent } from '../lib/event.js';
import { nsoAccountLimit } from '../../shared/constants.js';
import type { AppStatus, NsoAccountStatus } from '../../shared/types.js';

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
  const [deleteId, setDeleteId] = useState<string>();
  const accounts = status?.nsoAccounts ?? [];
  const connecting = status?.nsoState === 'connecting';
  const deleteCloseRef = useElementEvent<HTMLElement>('closed', () => setDeleteId(undefined));
  useEffect(() => {
    const url = status?.qrCode || '';
    if (!url) { setQrImage(''); return; }
    QRCode.toDataURL(url, { width: 440, margin: 1 }).then(setQrImage).catch(() => setQrImage(''));
  }, [status?.qrCode]);

  const addAccount = (): void => {
    void window.recordApi.openNsoLogin().catch((error) => snackbar({ message: errorText(error) }));
  };
  const relogin = (accountId: string): void => {
    void window.recordApi.openNsoLogin(accountId).catch((error) => snackbar({ message: errorText(error) }));
  };
  const select = (accountId: string): void => {
    void window.recordApi.selectNsoAccount(accountId).catch((error) => snackbar({ message: errorText(error) }));
  };
  const remove = (): void => {
    const target = deleteId;
    setDeleteId(undefined);
    if (!target) return;
    void window.recordApi.deleteNsoAccount(target).catch((error) => snackbar({ message: errorText(error) }));
  };

  return (
    <div className="page-body">
      <h2 className="page-title">绑定</h2>
      <h3 className="section-title">Nintendo Switch Online</h3>
      <NsoApiNotice />
      <div className="status-grid">
        <StatusItem label="当前 NSO 账户" value={status?.nsoCurrentNickname || '未选择'} />
        <StatusItem label="已绑定账户" value={`${accounts.length} / ${nsoAccountLimit}`} />
        <StatusItem label="NSO 状态" value={stateNames[status?.nsoState || 'unbound']} />
      </div>
      {status?.nsoError ? <div className="bind-info">失败原因：{status.nsoError}</div> : null}
      <div className="bind-row">
        <mdui-button variant="filled" disabled={connecting || accounts.length >= nsoAccountLimit} onClick={addAccount}>添加 Nintendo 账号</mdui-button>
      </div>
      {accounts.length ? (
        <div className="account-list">
          {accounts.map((account) => (
            <AccountRow key={account.accountId} account={account} only={accounts.length <= 1} connecting={connecting}
              onSelect={select} onRelogin={relogin} onDelete={setDeleteId} />
          ))}
        </div>
      ) : (
        <div className="empty-tip">尚未绑定 NSO 账户</div>
      )}
      <div className="bind-info">至少需要保留一个 NSO 账户。</div>
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
      <mdui-dialog className="delete-nso" ref={deleteCloseRef} open={Boolean(deleteId)} headline="删除 NSO 账户" description="将移除该账户的登录凭证。历史录像和归档不会被删除。" close-on-overlay-click>
        <mdui-button slot="action" variant="text" onClick={() => setDeleteId(undefined)}>取消</mdui-button>
        <mdui-button slot="action" variant="filled" onClick={remove}>删除</mdui-button>
      </mdui-dialog>
    </div>
  );
}

function accountRow(props: { account: NsoAccountStatus; only: boolean; connecting: boolean; onSelect: (id: string) => void; onRelogin: (id: string) => void; onDelete: (id: string) => void }): ReactElement {  const { account, only, connecting, onSelect, onRelogin, onDelete } = props;
  return (
    <div className={account.current ? 'account-row is-current' : 'account-row'}>
      <div className="account-main">
        <div className="account-name">
          {account.nickname || '未命名账户'}
          {account.current ? <span className="tag account-current">当前</span> : null}
        </div>
        <div className="account-sub">
          {stateNames[account.state] || account.state}
          {account.lastMatchAt ? ` · 最近对局 ${new Date(account.lastMatchAt).toLocaleString('zh-CN')}` : ''}
        </div>
        {account.error ? <div className="account-error">{account.error}</div> : null}
      </div>
      <div className="match-actions">
        <mdui-button variant="text" disabled={account.current || connecting} onClick={() => onSelect(account.accountId)}>设为当前</mdui-button>
        <mdui-button variant="text" disabled={connecting} onClick={() => onRelogin(account.accountId)}>重新登录</mdui-button>
        <mdui-button variant="text" disabled={only || connecting} onClick={() => onDelete(account.accountId)}>删除</mdui-button>
      </div>
    </div>
  );
}

export { bindingPage as BindingPage };

const AccountRow = accountRow;

function errorText(error: unknown): string {
  const text = (error instanceof Error ? error.message : String(error ?? '')).replace(/^Error invoking remote method '[^']*':\s*(Error:\s*)?/, '').trim();
  return text || '操作失败';
}

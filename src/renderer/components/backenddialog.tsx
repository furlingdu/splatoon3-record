import type { ReactElement } from 'react';
import { dialogLayer } from '../lib/portal.js';
import type { NsoBackendStatus } from '../../shared/types.js';

function backendDialog(props: { status?: NsoBackendStatus; onCancel: () => void; onConfirm: () => void }): ReactElement {
  return dialogLayer(
    <mdui-dialog className="backend-block" open={Boolean(props.status)} headline="znca 校验服务不可用"
      description={props.status?.error ? `检测失败：${props.status.error}。仍要登录 Nintendo 账号吗？` : '仍要登录 Nintendo 账号吗？'} close-on-overlay-click>
      <mdui-button slot="action" variant="text" onClick={props.onCancel}>取消</mdui-button>
      <mdui-button slot="action" variant="filled" onClick={props.onConfirm}>仍然登录</mdui-button>
    </mdui-dialog>,
  );
}

export { backendDialog as NsoBackendDialog };

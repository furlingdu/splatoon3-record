export interface BindView {
  qqOwner?: string;
}

export type BindAction = { action: 'bind'; text: string } | { action: 'deny'; text: string } | { action: 'ok'; text: string } | { action: 'guest'; text: string };

export function resolveBind(view: BindView, senderId: string): BindAction {
  if (!view.qqOwner) return { action: 'bind', text: '绑定成功~ 欢迎使用Splatoon 3 Record项目！\n作者@澪度\n官方群聊：1109099716' };
  if (view.qqOwner === senderId) return { action: 'ok', text: '你已绑定本机器人，无需重复绑定' };
  return { action: 'deny', text: '机器人已绑定其他用户，请先解除现有绑定' };
}

export function isOwner(view: BindView, senderId: string): boolean {
  return Boolean(view.qqOwner) && view.qqOwner === senderId;
}

export function guestText(): string {
  return '请先发送 /bind 完成用户绑定';
}

import { QQBot } from '@tencent-connect/qqbot-nodejs';
import { loadSecret } from '../store/secret.js';
import { getConfig, saveConfig } from '../store/config.js';
import { makeMessage, matchText, parseCommand } from './command.js';
import { guestText, isOwner, resolveBind } from './bind.js';
import { pushMatch, pushRecord, pushTarget } from './push.js';
import { timeText } from '../../shared/nso.js';
import type { AppStatus, BattleMatch, UserMessage } from '../../shared/types.js';

export interface BotSource {
  status: () => AppStatus;
  latest: () => Promise<BattleMatch | undefined>;
  changed: () => void;
}

export class QqBot {
  private bot?: QQBot;
  private state: AppStatus['qqState'] = 'unbound';
  constructor(private source: BotSource) {}

  async start(): Promise<void> {
    const secret = await loadSecret();
    if (!secret.qqAppId || !secret.qqSecret) { this.state = 'unbound'; return; }
    this.bot?.stop();
    this.state = 'connecting'; this.source.changed();
    this.bot = new QQBot({ appId: secret.qqAppId, appSecret: secret.qqSecret, logger: { info: () => undefined, error: (message) => console.error('[qq]', message) } });
    this.bot.on('ready', () => { this.state = 'connected'; this.source.changed(); });
    this.bot.on('error', () => { this.state = 'error'; this.source.changed(); });
    this.bot.on('message', async (_ctx, msg) => this.handle(makeMessage(String(msg.content || ''), String(msg.senderId || ''), msg.replyTarget, msg.kind === 'c2c')));
    void this.bot.start().catch(() => { this.state = 'error'; this.source.changed(); });
  }

  stop(): void { this.bot?.stop(); this.bot = undefined; this.state = 'unbound'; this.source.changed(); }
  get linkState(): AppStatus['qqState'] { return this.state; }
  pushEnabled(): boolean { return Boolean(this.bot); }

  async pushMatch(match: BattleMatch): Promise<void> {
    if (!this.bot) return;
    const config = getConfig();
    await pushMatch(this.bot, config, match).catch((error) => console.error(error));
  }

  async notifyText(text: string): Promise<void> {
    if (!this.bot) return;
    const owner = getConfig().qqOwner;
    if (!owner) return;
    await this.bot.sendText(pushTarget(owner), text).catch(() => undefined);
  }

  private async handle(message: UserMessage): Promise<void> {
    if (!this.bot || !message.isPrivate) return;
    const target = message.target as Parameters<QQBot['sendText']>[0];
    const config = getConfig();
    const command = parseCommand(message.content);
    if (command === 'bind') {
      const result = resolveBind(config, message.senderId);
      if (result.action === 'bind') { await saveConfig({ ...config, qqOwner: message.senderId }); this.source.changed(); }
      await this.bot.sendText(target, result.text);
      return;
    }
    if (!isOwner(config, message.senderId)) { await this.bot.sendText(target, guestText()); return; }
    const latest = await this.source.latest();
    if (command === 'record') await this.sendRecord(target, latest);
    else if (command === 'last') await this.sendMarkdown(target, matchText(latest));
    else if (command === 'push') await this.togglePush(target, config);
    else if (command === 'status') await this.sendStatus(target);
    else await this.bot.sendText(target, '可用命令：/bind /record /last /push /status');
  }

  private async sendRecord(target: Parameters<QQBot['sendText']>[0], latest?: BattleMatch): Promise<void> {
    if (!this.bot) return;
    if (!latest?.videoPath) { await this.bot.sendText(target, '尚无可发送的录像'); return; }
    await pushRecord(this.bot, target, getConfig(), latest);
  }

  private async sendMarkdown(target: Parameters<QQBot['sendText']>[0], content: string): Promise<void> {
    if (!this.bot) return;
    try { await this.bot.sendMarkdown(target, content); } catch { await this.bot.sendText(target, content); }
  }

  private async togglePush(target: Parameters<QQBot['sendText']>[0], config: ReturnType<typeof getConfig>): Promise<void> {
    if (!this.bot) return;
    const enabled = !config.pushEnabled;
    await saveConfig({ ...config, pushEnabled: enabled, settings: { ...config.settings, autoPush: enabled } });
    await this.bot.sendText(target, `自动推送已${enabled ? '开启' : '关闭'}`);
    this.source.changed();
  }

  private async sendStatus(target: Parameters<QQBot['sendText']>[0]): Promise<void> {
    if (!this.bot) return;
    const status = this.source.status();
    const minutes = status.cacheStart ? Math.round(((status.cacheEnd || Date.now()) - status.cacheStart) / 60000) : 0;
    const latest = status.latestMatch;
    await this.bot.sendText(target, [`录制：${status.recordState}`, `NSO：${status.nsoState}`, `QQBot：${status.qqState}`, `缓存：${minutes} 分钟`, `最近对局：${latest ? timeText(latest.endAt) : '无'}`].join('\n'));
  }
}

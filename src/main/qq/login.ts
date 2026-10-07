import { startQrConnect } from '@tencent-connect/qqbot-connector';
import { loadSecret, saveSecret } from '../store/secret.js';
import type { AppStatus } from '../../shared/types.js';

export interface QrEvents {
  qr: (url: string) => void;
  state: (state: AppStatus['qqState']) => void;
}

export class QqLogin {
  private stop?: () => void;
  constructor(private events: QrEvents) {}

  start(): void {
    this.stop?.();
    this.events.state('connecting');
    this.stop = startQrConnect({
      onQrDisplayed: (url) => this.events.qr(url),
      onSuccess: (credentials) => void this.success(credentials[0]),
      onFailure: () => this.events.state('error'),
    }, { displayQrCodeToConsole: false, source: 'Splatoon3Record' });
  }

  cancel(): void { this.stop?.(); this.stop = undefined; }

  private async success(credential: { appId: string; appSecret: string } | undefined): Promise<void> {
    if (!credential) { this.events.state('error'); return; }
    const old = await loadSecret();
    await saveSecret({ ...old, qqAppId: credential.appId, qqSecret: credential.appSecret });
    this.events.qr('');
    this.events.state('connected');
  }
}

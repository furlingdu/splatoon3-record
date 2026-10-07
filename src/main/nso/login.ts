import { randomBytes, createHash } from 'node:crypto';
import { BrowserWindow, dialog, session, type WebContents } from 'electron';
import { URL } from 'node:url';
import { userAgent } from '../store/env.js';
import { loadSecret, saveSecret } from '../store/secret.js';
import { coralToken, nsoVersion, postForm } from './coral.js';
import { isRetryableLogin, retryLogin } from './retry.js';
import { logLogin } from './log.js';
import type { LinkState, NsoLoginData, NsoToken } from '../../shared/types.js';

const loginRetries = 5;
const loginRetryDelay = 5000;
const dialogInterval = 600000;

const authUrl = 'https://accounts.nintendo.com/connect/1.0.0/authorize';
const sessionUrl = 'https://accounts.nintendo.com/connect/1.0.0/api/session_token';
const appClient = '71b963c1b7b6d119';
const callbackScheme = `npf${appClient}://auth`;

const webauthnBlock = "(() => { const deny = () => Promise.reject(new DOMException('WebAuthn disabled', 'NotAllowedError')); try { Object.defineProperty(Navigator.prototype, 'credentials', { configurable: true, get: () => ({ create: deny, get: deny, store: deny }) }); } catch {} try { Object.defineProperty(window, 'PublicKeyCredential', { configurable: true, value: undefined }); } catch {} })();";

const personSelectBlock = `(function () {
  if (window.__s3rPersonSelect) return;
  window.__s3rPersonSelect = true;
  let tries = 0;
  const timer = setInterval(() => {
    tries += 1;
    const nodes = [].slice.call(document.querySelectorAll('button, a, [role="button"]')).filter((el) => {
      const text = (el.innerText || '').trim();
      return el.getClientRects().length > 0 && /^(選擇此人|选择此人|Select this (person|account))$/i.test(text);
    });
    if (nodes.length === 1) { clearInterval(timer); nodes[0].click(); }
    if (tries > 50) clearInterval(timer);
  }, 400);
})();`;

function injectLoginGuard(contents: WebContents): void {
  
  void contents.executeJavaScript(webauthnBlock, true).catch(() => undefined);
  void contents.executeJavaScript(personSelectBlock, true).catch(() => undefined);
}

export class NsoLogin {
  state: LinkState = 'unbound';
  lastError = '';
  private loginWindow?: BrowserWindow;
  private loginData?: NsoLoginData;
  private linked = false;
  private dialogAt = 0;

  constructor(private changed?: () => void) {}

  async open(parent?: BrowserWindow): Promise<void> {
    
    if (this.loginWindow && !this.loginWindow.isDestroyed()) {
      if (this.loginWindow.isMinimized()) this.loginWindow.restore();
      this.loginWindow.show();
      this.loginWindow.focus();
      return;
    }
    const verifier = randomBytes(32).toString('base64url');
    const state = randomBytes(36).toString('base64url');
    const challenge = createHash('sha256').update(verifier).digest('base64url');
    this.loginData = { state, verifier, authUrl: `${authUrl}?${new URLSearchParams({ state, redirect_uri: callbackScheme, client_id: appClient, scope: 'openid user user.birthday user.mii user.screenName', response_type: 'session_token_code', session_token_code_challenge: challenge, session_token_code_challenge_method: 'S256', theme: 'login_form' })}` };
    this.state = 'connecting';
    this.linked = false;
    this.lastError = '';
    this.changed?.();
    this.loginWindow = new BrowserWindow({ width: 900, height: 760, parent, modal: Boolean(parent), webPreferences: { contextIsolation: true, nodeIntegration: false, partition: 'persist:splatoon3record-nso' } });
    const contents = this.loginWindow.webContents;
    logLogin(`open ${this.loginData.authUrl.slice(0, 200)}`);
    contents.on('will-redirect', (event, url) => this.captureCallback('will-redirect', event, url));
    contents.on('will-navigate', (event, url) => this.captureCallback('will-navigate', event, url));
    contents.on('dom-ready', () => { logLogin(`dom-ready ${contents.getURL().slice(0, 200)}`); injectLoginGuard(contents); });
    contents.on('did-frame-navigate', () => injectLoginGuard(contents));
    contents.on('did-navigate', (_event, url) => logLogin(`did-navigate ${url.slice(0, 200)}`));
    contents.on('did-fail-load', (_event, code, desc, url) => { if (code !== -3) logLogin(`did-fail-load ${code} ${desc} ${url.slice(0, 200)}`); });
    contents.setWindowOpenHandler(({ url }) => {
      logLogin(`window-open ${url.slice(0, 300)}`);
      if (url.startsWith(callbackScheme)) void this.callback(url);
      return { action: url.startsWith(callbackScheme) ? 'deny' : 'allow' };
    });
    contents.session.webRequest.onBeforeRequest((details, callback) => {
      if (details.url.startsWith(callbackScheme)) {
        logLogin(`web-request ${details.url.slice(0, 400)}`);
        void this.callback(details.url);
        callback({ cancel: true });
        return;
      }
      callback({});
    });
    this.loginWindow.on('closed', () => { this.loginWindow = undefined; if (this.state === 'connecting' && !this.linked) this.state = 'unbound'; this.changed?.(); });
    this.loginWindow.once('ready-to-show', () => { this.loginWindow?.show(); this.loginWindow?.focus(); });
    const target = this.loginWindow;
    void this.loadAuthPage(target, this.loginData.authUrl);
  }

  private async loadAuthPage(target: BrowserWindow, url: string): Promise<void> {
    
    for (let attempt = 0; attempt <= loginRetries; attempt += 1) {
      try {
        await target.loadURL(url);
        return;
      } catch (error) {
        if (this.loginWindow !== target || this.linked) return;
        if (attempt >= loginRetries || !isRetryableLogin(error)) {
          this.markFailure(error);
          this.notifyFailure(true);
          return;
        }
        logLogin(`load retry ${attempt + 1}/${loginRetries} ${error instanceof Error ? error.message : String(error)}`);
        await new Promise((resolve) => setTimeout(resolve, loginRetryDelay));
      }
    }
  }

  async restore(): Promise<boolean> {
    
    this.state = 'connecting';
    this.lastError = '';
    this.changed?.();
    const secret = await loadSecret();
    const token = secret.nsoToken;
    if (!secret.nsoSession || !token) { this.state = 'unbound'; this.changed?.(); return false; }
    if (token.language === 'zh-CN' && token.expiresAt > Date.now() + 60000) {
      this.state = 'connected';
      this.lastError = '';
      this.changed?.();
      return true;
    }
    try {
      await this.refresh(secret.nsoSession);
      return true;
    } catch (error) {
      this.markFailure(error);
      this.notifyFailure();
      return false;
    }
  }

  markFailure(error: unknown): void {
    
    const message = error instanceof Error ? error.message : String(error);
    this.lastError = message;
    this.state = /重新登录/.test(message) ? 'expired' : 'error';
    this.changed?.();
  }

  async clear(): Promise<void> {
    const secret = await loadSecret();
    delete secret.nsoSession; delete secret.nsoToken;
    await saveSecret(secret);
    this.state = 'unbound';
    this.lastError = '';
  }

  async clearAndOpen(parent?: BrowserWindow): Promise<void> {
    
    this.loginWindow?.destroy();
    this.loginWindow = undefined;
    await session.fromPartition('persist:splatoon3record-nso').clearStorageData();
    await this.clear();
    await this.open(parent);
  }

  async refresh(sessionToken: string): Promise<NsoToken> {
    logLogin('refresh start');
    const token = await retryLogin(() => coralToken(sessionToken), loginRetries, loginRetryDelay, (attempt, error) => {
      logLogin(`refresh retry ${attempt}/${loginRetries} ${error instanceof Error ? error.message : String(error)}`);
    });
    await saveSecret({ ...(await loadSecret()), nsoSession: sessionToken, nsoToken: token });
    logLogin('refresh complete');
    this.state = 'connected';
    this.lastError = '';
    this.changed?.();
    return token;
  }

  notifyFailure(interactive = false): void {
    
    if (this.state !== 'error' && this.state !== 'expired') return;
    if (!interactive && (this.state !== 'expired' || Date.now() - this.dialogAt < dialogInterval)) return;
    this.dialogAt = Date.now();
    void dialog.showMessageBox({
      type: 'warning',
      title: 'NSO 登录失败',
      message: `NSO 登录失败：${this.lastError}`,
      detail: interactive ? '登录未能完成，请重新登录后再试。' : '已自动重试 5 次仍未成功，应用会继续定期自动重试；你也可以到绑定页重新登录。',
      buttons: ['稍后重试', '重新登录'],
      defaultId: 0,
      cancelId: 0,
    }).then(({ response }) => { if (response === 1) void this.clearAndOpen(); });
  }

  private captureCallback(source: string, event: { preventDefault(): void }, url: string): void {
    logLogin(`capture ${source} ${url.slice(0, 400)}`);
    if (!url.startsWith(callbackScheme)) return;
    event.preventDefault();
    void this.callback(url);
  }

  private async callback(url: string): Promise<void> {
    if (this.linked) { logLogin('callback skip already-linked'); return; }
    if (!this.loginData || this.state !== 'connecting' || !url.startsWith(callbackScheme)) { logLogin('callback skip guard'); return; }
    const loginData = this.loginData;
    this.linked = true;
    const parsed = new URL(url);
    const params = new URLSearchParams(parsed.search || parsed.hash.slice(1));
    const state = params.get('state');
    const code = params.get('session_token_code');
    logLogin(`callback state-ok=${state === loginData.state} code=${code ? 'yes' : 'no'}`);
    if (state && state !== loginData.state) { this.linked = false; return; }
    if (!code) { this.linked = false; return; }
    try {
      const sessionToken = await retryLogin(async () => {
        const version = await nsoVersion();
        const response = await postForm(sessionUrl, { client_id: appClient, session_token_code: code, session_token_code_verifier: loginData.verifier }, { 'User-Agent': `OnlineLounge/${version} NASDKAPI Android`, 'Accept-Language': 'en-US' });
        const value = String(response.session_token || '');
        logLogin(`session-token ${value ? 'received' : 'missing'}`);
        if (!value) throw new Error('未获取到 Nintendo session token');
        return value;
      }, loginRetries, loginRetryDelay, (attempt, error) => {
        logLogin(`session retry ${attempt}/${loginRetries} ${error instanceof Error ? error.message : String(error)}`);
      });
      this.loginWindow?.close();
      logLogin('login window closed, fetching in background');
      await this.refresh(sessionToken);
      logLogin('login complete');
    } catch (error) {
      const message = (error instanceof Error ? error.message : String(error)).slice(0, 300);
      logLogin(`exchange failed ${message}`);
      this.markFailure(error);
      this.notifyFailure(true);
    }
  }
}

export { userAgent };

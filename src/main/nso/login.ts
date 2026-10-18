import { randomBytes, createHash } from 'node:crypto';
import { BrowserWindow, dialog, session, type WebContents } from 'electron';
import { URL } from 'node:url';
import { userAgent } from '../store/env.js';
import { readSecret, updateSecret } from '../store/secret.js';
import { coralToken, nsoVersion, postForm, type CoralAccountToken } from './coral.js';
import { isRetryableLogin, retryLogin } from './retry.js';
import { logLogin } from './log.js';
import { isExpired } from './token.js';
import { nsoAccountLimit } from '../../shared/constants.js';
import { normalizeAccounts, mergeAccount, removeAccountFromList, legacyAccountId } from './accountmodel.js';
import type { LinkState, NsoAccountSecret, NsoAccountStatus, NsoLoginData, NsoToken } from '../../shared/types.js';

const loginRetries = 5;
const loginRetryDelay = 5000;
const dialogInterval = 600000;
const loginPartition = 'persist:splatoon3record-nso';

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

interface AccountRuntime extends NsoAccountSecret {
  state: LinkState;
  error: string;
  lastPollAt?: number;
  lastMatchAt?: number;
}

function messageOf(error: unknown): string {
  return (error instanceof Error ? error.message : String(error)).slice(0, 300);
}

export class NsoAccounts {
  state: LinkState = 'unbound';
  lastError = '';
  private accounts: AccountRuntime[] = [];
  private currentId = '';
  private loginWindow?: BrowserWindow;
  private loginData?: NsoLoginData;
  private linked = false;
  private loginTargetId?: string;
  private loginBusy = false;
  private dialogAt = 0;
  private ready = false;
  private refreshes = new Map<string, Promise<NsoToken | undefined>>();
  private restoring?: Promise<boolean>;

  constructor(private changed?: () => void) {}

  get currentAccountId(): string | undefined {
    return this.currentId || undefined;
  }

  get currentNickname(): string | undefined {
    return this.accounts.find((item) => item.id === this.currentId)?.nickname;
  }

  hasAccount(accountId: string): boolean {
    return this.accounts.some((item) => item.id === accountId);
  }

  nicknameOf(accountId: string): string {
    return this.accounts.find((item) => item.id === accountId)?.nickname ?? '';
  }

  statuses(): NsoAccountStatus[] {
    return this.accounts.map((item) => ({
      accountId: item.id,
      nickname: item.nickname,
      state: item.state,
      error: item.error || undefined,
      current: item.id === this.currentId,
      lastPollAt: item.lastPollAt,
      lastMatchAt: item.lastMatchAt,
    }));
  }

  private emit(): void {
    this.recompute();
    this.changed?.();
  }

  private recompute(): void {
    if (this.loginBusy) {
      this.state = 'connecting';
      return;
    }
    if (!this.accounts.length) {
      this.state = 'unbound';
      this.lastError = '';
      return;
    }
    const states = this.accounts.map((item) => item.state);
    if (states.includes('connected')) this.state = 'connected';
    else if (states.includes('connecting')) this.state = 'connecting';
    else if (states.includes('expired')) this.state = 'expired';
    else if (states.includes('error')) this.state = 'error';
    else this.state = 'unbound';
    this.lastError = this.accounts.find((item) => item.error)?.error ?? '';
  }

  private async load(): Promise<void> {
    const data = await readSecret();
    const { accounts, current } = normalizeAccounts(data);
    this.accounts = accounts.map((item) => ({ ...item, state: isExpired(item.token) ? 'expired' : 'connected', error: '' }));
    this.currentId = current && this.accounts.some((item) => item.id === current) ? current : this.accounts[0]?.id ?? '';
    if (accounts.length && (!data.nsoAccounts || data.nsoAccounts.length !== this.accounts.length || data.currentNsoAccountId !== this.currentId || data.nsoSession || data.nsoToken)) {
      await updateSecret((secret) => {
        secret.nsoAccounts = this.accounts.map(({ state: _state, error: _error, lastPollAt: _lastPollAt, lastMatchAt: _lastMatchAt, ...item }) => item);
        secret.currentNsoAccountId = this.currentId;
        delete secret.nsoSession;
        delete secret.nsoToken;
      });
    }
    this.recompute();
  }

  async restore(): Promise<boolean> {
    if (this.restoring) return this.restoring;
    this.restoring = this.doRestore().finally(() => { this.restoring = undefined; });
    return this.restoring;
  }

  private async doRestore(): Promise<boolean> {
    this.loginBusy = false;
    await this.load();
    this.ready = true;
    if (!this.accounts.length) {
      this.emit();
      return false;
    }
    this.state = 'connecting';
    this.changed?.();
    for (const account of [...this.accounts]) {
      const needIdentity = account.id === legacyAccountId;
      if (!needIdentity && !isExpired(account.token)) {
        account.state = 'connected';
        account.error = '';
        continue;
      }
      try {
        await this.refreshAccount(account.id);
      } catch (error) {
        if (isExpired(account.token)) this.markAccountFailure(account.id, error);
        else {
          account.state = 'connected';
          account.error = '';
        }
      }
    }
    this.emit();
    return this.accounts.some((item) => item.state === 'connected');
  }

  async open(parent?: BrowserWindow, accountId?: string): Promise<void> {
    if (this.restoring) await this.restoring;
    else if (!this.ready) await this.restore();
    if (this.loginBusy || (this.loginWindow && !this.loginWindow.isDestroyed())) {
      if (this.loginWindow && !this.loginWindow.isDestroyed()) {
        if (this.loginWindow.isMinimized()) this.loginWindow.restore();
        this.loginWindow.show();
        this.loginWindow.focus();
      }
      return;
    }
    const target = accountId ? this.accounts.find((item) => item.id === accountId) : undefined;
    if (accountId && !target) throw new Error('要重新登录的 NSO 账户不存在');
    if (!target && this.accounts.length >= nsoAccountLimit) throw new Error(`最多只能绑定 ${nsoAccountLimit} 个 NSO 账户`);
    this.loginBusy = true;
    this.loginTargetId = target?.id;
    this.lastError = '';
    this.state = 'connecting';
    this.emit();
    try {
      const ses = session.fromPartition(loginPartition);
      await ses.clearStorageData();
      await ses.clearCache().catch(() => undefined);
      await this.startLoginWindow(parent);
    } catch (error) {
      this.loginBusy = false;
      this.lastError = messageOf(error);
      this.state = 'error';
      this.changed?.();
      throw error;
    }
  }

  private async startLoginWindow(parent?: BrowserWindow): Promise<void> {
    const verifier = randomBytes(32).toString('base64url');
    const state = randomBytes(36).toString('base64url');
    const challenge = createHash('sha256').update(verifier).digest('base64url');
    this.loginData = { state, verifier, authUrl: `${authUrl}?${new URLSearchParams({ state, redirect_uri: callbackScheme, client_id: appClient, scope: 'openid user user.birthday user.mii user.screenName', response_type: 'session_token_code', session_token_code_challenge: challenge, session_token_code_challenge_method: 'S256', theme: 'login_form' })}` };
    this.linked = false;
    this.loginWindow = new BrowserWindow({ width: 900, height: 760, parent, modal: Boolean(parent), webPreferences: { contextIsolation: true, nodeIntegration: false, partition: loginPartition } });
    const contents = this.loginWindow.webContents;
    logLogin(`open account=${this.loginTargetId ?? 'new'} ${this.loginData.authUrl.slice(0, 200)}`);
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
    this.loginWindow.on('closed', () => {
      this.loginWindow = undefined;
      if (this.loginBusy && !this.linked) {
        this.loginBusy = false;
        this.lastError = '登录窗口已关闭';
        this.recompute();
        this.changed?.();
      }
    });
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
          this.failLogin(error, true);
          return;
        }
        logLogin(`load retry ${attempt + 1}/${loginRetries} ${messageOf(error)}`);
        await new Promise((resolve) => setTimeout(resolve, loginRetryDelay));
      }
    }
  }

  private failLogin(error: unknown, interactive = false): void {
    this.loginBusy = false;
    this.loginWindow?.destroy();
    this.loginWindow = undefined;
    this.lastError = messageOf(error);
    this.state = /重新登录/.test(this.lastError) ? 'expired' : 'error';
    this.changed?.();
    this.notifyFailure(interactive);
  }

  markAccountFailure(accountId: string, error: unknown): void {
    const account = this.accounts.find((item) => item.id === accountId);
    if (!account) return;
    account.error = messageOf(error);
    account.state = /重新登录/.test(account.error) ? 'expired' : 'error';
    this.emit();
  }

  markPolled(accountId: string): void {
    const account = this.accounts.find((item) => item.id === accountId);
    if (!account) return;
    account.lastPollAt = Date.now();
    if (account.state === 'error') {
      account.state = 'connected';
      account.error = '';
      this.emit();
    }
  }

  markMatch(accountId: string): void {
    const account = this.accounts.find((item) => item.id === accountId);
    if (!account) return;
    account.lastMatchAt = Date.now();
    this.changed?.();
  }

  async refreshAccount(accountId: string): Promise<NsoToken | undefined> {
    const running = this.refreshes.get(accountId);
    if (running) return running;
    const task = this.doRefresh(accountId).finally(() => { this.refreshes.delete(accountId); });
    this.refreshes.set(accountId, task);
    return task;
  }

  private async doRefresh(accountId: string): Promise<NsoToken | undefined> {
    const account = this.accounts.find((item) => item.id === accountId);
    if (!account) return undefined;
    logLogin(`refresh start account=${accountId}`);
    const result = await retryLogin(() => coralToken(account.session), loginRetries, loginRetryDelay, (attempt, error) => {
      logLogin(`refresh retry account=${accountId} ${attempt}/${loginRetries} ${messageOf(error)}`);
    });
    const latest = this.accounts.find((item) => item.id === accountId);
    if (!latest || latest.session !== account.session) {
      logLogin(`refresh discarded account=${accountId} reason=credentials-changed`);
      return latest?.token;
    }
    const token = await this.storeAccount(result, accountId, account.session);
    logLogin(`refresh complete account=${result.accountId}`);
    return token;
  }

  async ensureAccountToken(accountId: string): Promise<NsoToken | undefined> {
    const account = this.accounts.find((item) => item.id === accountId);
    if (!account) return undefined;
    if (!isExpired(account.token)) return account.token;
    try {
      return await this.refreshAccount(accountId);
    } catch (error) {
      this.markAccountFailure(accountId, error);
      return undefined;
    }
  }

  needsRefresh(accountId: string): boolean {
    const account = this.accounts.find((item) => item.id === accountId);
    return Boolean(account && isExpired(account.token));
  }

  async updateAccountToken(accountId: string, token: NsoToken): Promise<void> {
    const account = this.accounts.find((item) => item.id === accountId);
    if (account) account.token = token;
    await updateSecret((secret) => {
      const item = secret.nsoAccounts?.find((value) => value.id === accountId);
      if (item) item.token = token;
    }).catch((error) => logLogin(`persist bullet token failed account=${accountId} ${messageOf(error)}`));
  }

  private async storeAccount(result: CoralAccountToken, targetId?: string, sessionToken?: string, interactive = false): Promise<NsoToken | undefined> {
    let stored: NsoToken | undefined;
    let missing = false;
    await updateSecret((secret) => {
      const outcome = mergeAccount(secret.nsoAccounts ?? [], secret.currentNsoAccountId, result, targetId, sessionToken, nsoAccountLimit);
      if (outcome.error) throw new Error(outcome.error);
      if (outcome.missing) {
        missing = true;
        return;
      }
      secret.nsoAccounts = outcome.accounts;
      secret.currentNsoAccountId = outcome.current;
      delete secret.nsoSession;
      delete secret.nsoToken;
      stored = outcome.stored;
    });
    await this.load();
    if (missing) {
      if (interactive) {
        this.loginBusy = false;
        this.linked = true;
      }
      this.emit();
      return undefined;
    }
    if (interactive) {
      this.loginBusy = false;
      this.linked = true;
    }
    this.emit();
    return stored;
  }

  async removeAccount(accountId: string): Promise<void> {
    if (!this.accounts.some((item) => item.id === accountId)) return;
    const plain = this.accounts.map(({ id, nickname, session, token, addedAt, lastRefreshAt }) => ({ id, nickname, session, token, addedAt, lastRefreshAt }));
    const outcome = removeAccountFromList(plain, this.currentId, accountId, 1);
    if (outcome.error) throw new Error(outcome.error);
    await updateSecret((secret) => {
      secret.nsoAccounts = outcome.accounts;
      secret.currentNsoAccountId = outcome.current;
    });
    if (this.loginTargetId === accountId) this.loginTargetId = undefined;
    await this.load();
    this.emit();
  }

  async selectAccount(accountId: string): Promise<void> {
    if (!this.accounts.some((item) => item.id === accountId)) throw new Error('NSO 账户不存在');
    await updateSecret((secret) => { secret.currentNsoAccountId = accountId; });
    this.currentId = accountId;
    this.emit();
  }

  async clear(): Promise<void> {
    await updateSecret((secret) => {
      delete secret.nsoAccounts;
      delete secret.currentNsoAccountId;
      delete secret.nsoSession;
      delete secret.nsoToken;
    });
    this.accounts = [];
    this.currentId = '';
    this.loginBusy = false;
    this.emit();
  }

  async clearAndOpen(parent?: BrowserWindow): Promise<void> {
    await this.open(parent);
  }

  notifyFailure(interactive = false): void {
    if (this.state !== 'error' && this.state !== 'expired') return;
    if (!interactive && (this.state !== 'expired' || Date.now() - this.dialogAt < dialogInterval)) return;
    this.dialogAt = Date.now();
    const failed = this.accounts.find((item) => item.error);
    void dialog.showMessageBox({
      type: 'warning',
      title: 'NSO 登录失败',
      message: `NSO 登录失败：${this.lastError || failed?.error || '未知错误'}`,
      detail: interactive ? '登录未能完成，请重新登录后再试。' : '已自动重试 5 次仍未成功，应用会继续定期自动重试；你也可以到绑定页重新登录。',
      buttons: ['稍后重试', '重新登录'],
      defaultId: 0,
      cancelId: 0,
    }).then(({ response }) => { if (response === 1) void this.open(undefined, failed?.id); });
  }

  private captureCallback(source: string, event: { preventDefault(): void }, url: string): void {
    logLogin(`capture ${source} ${url.slice(0, 400)}`);
    if (!url.startsWith(callbackScheme)) return;
    event.preventDefault();
    void this.callback(url);
  }

  private async callback(url: string): Promise<void> {
    if (this.linked) { logLogin('callback skip already-linked'); return; }
    if (!this.loginData || !this.loginBusy || !url.startsWith(callbackScheme)) { logLogin('callback skip guard'); return; }
    const loginData = this.loginData;
    const targetId = this.loginTargetId;
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
        logLogin(`session retry ${attempt}/${loginRetries} ${messageOf(error)}`);
      });
      this.loginWindow?.close();
      logLogin('login window closed, fetching in background');
      const result = await retryLogin(() => coralToken(sessionToken), loginRetries, loginRetryDelay, (attempt, error) => {
        logLogin(`coral retry ${attempt}/${loginRetries} ${messageOf(error)}`);
      });
      const stored = await this.storeAccount(result, targetId, sessionToken, true);
      if (stored) logLogin(`login complete account=${result.accountId}`);
    } catch (error) {
      logLogin(`login failed ${messageOf(error)}`);
      this.failLogin(error, true);
    }
  }
}

export { userAgent, legacyAccountId };

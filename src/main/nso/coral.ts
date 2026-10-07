import { request } from 'node:https';
import { mkdir, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
import CoralApi, { CoralErrorResponse, CoralStatus } from 'nxapi/coral';
import SplatNet3Api from 'nxapi/splatnet3';
import { nsoEnv, userAgent } from '../store/env.js';
import { nsoPath } from '../store/path.js';
import { logLogin } from './log.js';
import type { NsoToken } from '../../shared/types.js';
import { splatnetUserAgent } from './splatnet.js';

const liveConfigUrl = 'https://fancy.org.uk/api/nxapi/config';
const fUserAgent = 'splatoon3record/0.1.0';
const appVersionFallback = '3.5.0';
const webServiceId = 4834290508791808;
const publicClientId = 'Orh4jxABP3D3jYaBFgL9Ug';
const configPath = join(nsoPath, 'zncaConfig.json');
const backendUrl = nsoEnv().backendUrl;
const fConfigUrl = `${backendUrl}/config`;

process.env.NXAPI_ZNCA_API_CLIENT_ID ||= publicClientId;
process.env.ZNCA_API_URL = backendUrl;

let appVersion = '';

export async function coralToken(sessionToken: string): Promise<NsoToken> {
  
  await writeZncaConfig();
  try {
    const { nso, data } = await CoralApi.createWithSessionToken(sessionToken, fUserAgent);
    logLogin(`coral account login ok user=${String(data.nsoAccount.user.id)} country=${data.user.country} name=${data.user.nickname}`);
    const service = await nso.getWebServiceToken(webServiceId);
    logLogin('coral webservice token ok');
    const s3 = await SplatNet3Api.loginWithWebServiceToken(service, data.user);
    const bulletToken = String(s3.bullet_token.bulletToken || '');
    if (!bulletToken) throw new Error('bullet token 获取失败');
    logLogin(`coral bullet token ok version=${s3.version}`);
    return { gToken: service.accessToken, bulletToken, language: data.user.language, country: data.user.country, userAgent: splatnetUserAgent, expiresAt: Date.now() + 7200000 };
  } catch (error) {
    throw new Error(loginErrorText(error), { cause: error });
  }
}

async function writeZncaConfig(): Promise<void> {
  
  const version = await nsoVersion();
  logLogin(`znca config version ${version}`);
  let config: Record<string, any>;
  try {
    config = await getJson(liveConfigUrl, { 'User-Agent': fUserAgent });
  } catch {
    config = { require_version: ['1.6.1'] };
  }
  config.coral = { znca_version: version };
  if (!config.coral_auth) config.coral_auth = { default: ['nxapi', backendUrl], splatnet2statink: null, flapg: null, imink: null };
  if (!config.coral_gws_splatnet3) config.coral_gws_splatnet3 = { app_ver: '10.0.0-dfefd0af', version: '10.0.0', revision: 'dfefd0af8969f0c27f0ff6a8d6bc1f75e3da9df5' };
  await mkdir(nsoPath, { recursive: true });
  await writeFile(configPath, JSON.stringify(config));
  process.env.NXAPI_CONFIG_URL = pathToFileURL(configPath).href;
}

function loginErrorText(error: unknown): string {
  
  const raw = error instanceof Error ? error.message : String(error);
  if (/znca-api/i.test(raw)) return '第三方 znca 校验服务暂时不可用，请稍后重试，恢复后应用会自动重新连接';
  if (error instanceof CoralErrorResponse) {
    const status = Number(error.status ?? 0);
    if (status === CoralStatus.MEMBERSHIP_REQUIRED) return '该 Nintendo 账号未开通（或已过期） Nintendo Switch Online 会员，无法获取鱿鱼圈3数据。';
    if (status === CoralStatus.INVALID_TOKEN || status === CoralStatus.UNAUTHORISED) return 'Nintendo 授权无效或已失效，请重新登录';
    if (status === CoralStatus.TOKEN_EXPIRED) return 'Nintendo 凭证已过期，请重新登录';
    if (status === CoralStatus.ACCOUNT_DISABLED) return '该 Nintendo 账号已被停用';
    if (status === CoralStatus.RATE_LIMIT_EXCEEDED) return '请求过于频繁，请稍后再试';
    const detail = error.data?.errorMessage || raw;
    return `Nintendo 服务返回错误 ${status || '未知'} ${detail}`.trim();
  }
  if (/znca/i.test(raw)) return '第三方 znca 校验服务暂时不可用，请稍后重试，恢复后应用会自动重新连接';
  return `NSO 登录失败 ${raw.slice(0, 180)}`;
}

export async function nsoVersion(): Promise<string> {
  
  if (appVersion) return appVersion;
  try {
    const config = await getJson(fConfigUrl, { 'User-Agent': fUserAgent });
    appVersion = String(config.nso_version || '') || appVersionFallback;
  } catch {
    appVersion = appVersionFallback;
  }
  return appVersion;
}

export function postForm(url: string, data: Record<string, string>, headers: Record<string, string> = {}): Promise<Record<string, unknown>> {
  return new Promise((resolve, reject) => {
    const body = new URLSearchParams(data).toString();
    const target = new URL(url);
    const req = request({ hostname: target.hostname, path: `${target.pathname}${target.search}`, method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded', 'Content-Length': Buffer.byteLength(body), 'User-Agent': userAgent, ...headers } }, (res) => collectBody(res, resolve, reject));
    req.on('error', reject);
    req.write(body);
    req.end();
  });
}

function getJson(url: string, headers: Record<string, string> = {}): Promise<Record<string, any>> {
  return new Promise((resolve, reject) => {
    const target = new URL(url);
    const req = request({ hostname: target.hostname, path: `${target.pathname}${target.search}`, method: 'GET', headers: { Accept: 'application/json', 'User-Agent': userAgent, ...headers } }, (res) => collectBody(res, resolve, reject));
    req.on('error', reject);
    req.end();
  });
}

function collectBody(res: import('node:http').IncomingMessage, resolve: (data: Record<string, any>) => void, reject: (error: Error) => void): void {
  let text = '';
  res.setEncoding('utf8');
  res.on('data', (chunk) => { text += chunk; });
  res.on('end', () => {
    try {
      const value = JSON.parse(text) as Record<string, any>;
      if ((res.statusCode ?? 500) >= 400) {
        const detail = [value.reason, value.errorMessage, value.error_description, value.error].filter((item): item is string => typeof item === 'string').join(' ');
        reject(new Error(`HTTP ${res.statusCode} ${detail} ${text.slice(0, 120)}`.trim()));
      } else resolve(value);
    } catch {
      reject(new Error(`Nintendo 响应格式错误 HTTP ${res.statusCode} ${text.slice(0, 120)}`));
    }
  });
}

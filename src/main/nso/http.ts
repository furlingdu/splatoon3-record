import { request as httpRequest, type ClientRequest, type IncomingMessage } from 'node:http';
import { request as httpsRequest } from 'node:https';
import { userAgent } from '../store/env.js';

const requestTimeoutMs = 10000;

export function postForm(url: string, data: Record<string, string>, headers: Record<string, string> = {}): Promise<Record<string, unknown>> {
  const body = new URLSearchParams(data).toString();
  return requestJson(url, 'POST', { 'Content-Type': 'application/x-www-form-urlencoded', 'Content-Length': String(Buffer.byteLength(body)), 'User-Agent': userAgent, ...headers }, body);
}

export function getJson(url: string, headers: Record<string, string> = {}, timeoutMs = requestTimeoutMs): Promise<Record<string, any>> {
  return requestJson(url, 'GET', { Accept: 'application/json', 'User-Agent': userAgent, ...headers }, undefined, timeoutMs);
}

export async function withTimeout<T>(task: Promise<T>, ms: number, label: string): Promise<T> {
  let timer: NodeJS.Timeout | undefined;
  const timeout = new Promise<never>((_resolve, reject) => {
    timer = setTimeout(() => reject(new Error(`${label}超时（${ms}ms）`)), ms);
  });
  try {
    return await Promise.race([task, timeout]);
  } finally {
    clearTimeout(timer);
  }
}

function requestJson(url: string, method: 'GET' | 'POST', headers: Record<string, string>, body?: string, timeoutMs = requestTimeoutMs): Promise<Record<string, any>> {
  return new Promise((resolve, reject) => {
    const target = new URL(url);
    const options = {
      hostname: target.hostname.replace(/^\[|\]$/g, ''),
      port: target.port || undefined,
      path: `${target.pathname}${target.search}`,
      method,
      headers,
    };
    let settled = false;
    const finish = (action: () => void): void => {
      if (settled) return;
      settled = true;
      action();
    };
    const fail = (error: Error): void => finish(() => reject(error));
    const onResponse = (response: IncomingMessage): void => collectBody(response, (data) => finish(() => resolve(data)), fail);
    const req: ClientRequest = target.protocol === 'http:' ? httpRequest(options, onResponse) : httpsRequest(options, onResponse);
    const timer = setTimeout(() => {
      const error = new Error(`请求超时（${timeoutMs}ms）`);
      req.destroy(error);
      fail(error);
    }, timeoutMs);
    req.on('close', () => clearTimeout(timer));
    req.on('error', (error) => {
      clearTimeout(timer);
      fail(error instanceof Error ? error : new Error(String(error)));
    });
    if (body !== undefined) req.write(body);
    req.end();
  });
}

function collectBody(response: IncomingMessage, resolve: (data: Record<string, any>) => void, reject: (error: Error) => void): void {
  let text = '';
  response.setEncoding('utf8');
  response.on('data', (chunk) => { text += chunk; });
  response.on('aborted', () => reject(new Error('Nintendo 响应中断')));
  response.on('error', (error) => reject(error instanceof Error ? error : new Error(String(error))));
  response.on('close', () => { if (!response.complete) reject(new Error('Nintendo 响应提前关闭')); });
  response.on('end', () => {
    const status = response.statusCode ?? 500;
    let value: Record<string, any> | undefined;
    try {
      value = JSON.parse(text) as Record<string, any>;
    } catch {
      value = undefined;
    }
    if (status >= 400) {
      const detail = value ? [value.reason, value.errorMessage, value.error_description, value.error].filter((item): item is string => typeof item === 'string').join(' ') : '';
      reject(new Error([`HTTP ${status}`, detail, text.slice(0, 120)].filter(Boolean).join(' ')));
      return;
    }
    if (!value) {
      reject(new Error(`HTTP ${status} 响应不是有效 JSON ${text.slice(0, 120)}`.trim()));
      return;
    }
    resolve(value);
  });
}

import { readdir, readFile, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { logPath } from './path.js';

const logFiles = ['app.log', 'loginDebug.log'];
const tailLines = 300;

// 把设备反馈信息与最近运行日志写成 txt，供用户提交反馈
export async function saveReport(text: string): Promise<string | undefined> {
  const body = text.trim();
  if (!body) return undefined;
  const file = join(logPath, reportName());
  await writeFile(file, `${body}\n\n${await collectLogs()}`, 'utf8');
  return file;
}

async function collectLogs(): Promise<string> {
  const parts: string[] = [];
  for (const name of logFiles) {
    const tail = await tailLog(join(logPath, name));
    if (tail) parts.push(`===== ${name} =====\n${tail}`);
  }
  const header = `===== 运行日志 =====\n日志目录：${logPath}`;
  if (!parts.length) return `${header}\n未找到日志文件，目录内容：${await listLogs()}`;
  return `${header}\n${parts.join('\n\n')}`;
}

async function listLogs(): Promise<string> {
  try {
    const names = await readdir(logPath);
    return names.length ? names.join('、') : '空';
  } catch {
    return '目录不可读';
  }
}

async function tailLog(file: string): Promise<string> {
  try {
    const lines = (await readFile(file, 'utf8')).split(/\r?\n/);
    return redactLog(lines.slice(-tailLines).join('\n').trim());
  } catch {
    return '';
  }
}

function redactLog(text: string): string {
  return text
    .replace(/(session_token_code|access_token|id_token|refresh_token|code_verifier|code_challenge)=([^&\s"'\\]+)/gi, '$1=[已隐藏]')
    .replace(/(Bearer\s+)[A-Za-z0-9._~+/=-]+/gi, '$1[已隐藏]');
}

function reportName(): string {
  const now = new Date();
  const pad = (value: number): string => String(value).padStart(2, '0');
  return `report-${now.getFullYear()}${pad(now.getMonth() + 1)}${pad(now.getDate())}-${pad(now.getHours())}${pad(now.getMinutes())}${pad(now.getSeconds())}.txt`;
}

import { spawn, type ChildProcessWithoutNullStreams } from 'node:child_process';
import { existsSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const currentDir = dirname(fileURLToPath(import.meta.url));
const ffmpegFile = process.platform === 'win32' ? 'ffmpeg.exe' : 'ffmpeg';

export interface CommandResult {
  code: number;
  output: string;
}

export function ffmpegPath(): string {
  const packaged = join(process.resourcesPath || '', 'bin', ffmpegFile);
  if (existsSync(packaged)) return packaged;
  return join(currentDir, '..', '..', '..', 'bin', ffmpegFile);
}

export function ffmpegErrorText(stderr: string): string {
  const lines = stderr.split(/\r?\n/).map((line) => line.trim()).filter(Boolean);
  const meaningful = lines.filter((line) => !/^(ffmpeg version|built with|configuration:|libav\w|libpostproc|frame=\s|size=\s)/.test(line));
  const picked = meaningful.filter((line) => /\b(error|invalid|failed|unable|could not|malformed|denied|timed out|i\/o error|not (?:supported|found|recognized))/i.test(line) || line.startsWith('['));
  const text = (picked.length ? picked : meaningful).slice(-4).join(' ');
  return text.slice(-300);
}

export function runFFmpeg(args: string[], timeoutMs = 0): Promise<void> {
  return new Promise((resolve, reject) => {
    const child = spawn(ffmpegPath(), ['-hide_banner', '-y', ...args], { windowsHide: true });
    let error = '';
    let settled = false;
    const timer = timeoutMs > 0 ? setTimeout(() => {
      if (settled) return;
      settled = true;
      child.kill();
      reject(new Error(`ffmpeg 执行超时 ${timeoutMs}ms`));
    }, timeoutMs) : undefined;
    child.stderr.on('data', (data: Buffer) => { error += data.toString(); });
    child.on('error', (cause) => {
      if (settled) return;
      settled = true;
      if (timer) clearTimeout(timer);
      reject(cause);
    });
    child.on('close', (code) => {
      if (settled) return;
      settled = true;
      if (timer) clearTimeout(timer);
      if (code === 0) resolve();
      else reject(new Error(ffmpegErrorText(error) || `ffmpeg 退出码 ${code}`));
    });
  });
}

export function startFfmpeg(args: string[]): ChildProcessWithoutNullStreams {
  return spawn(ffmpegPath(), ['-hide_banner', '-y', ...args], { windowsHide: true });
}

export function runCommand(args: string[], timeoutMs = 15000): Promise<CommandResult> {
  return new Promise((resolve) => {
    const child = spawn(ffmpegPath(), args, { windowsHide: true });
    let output = '';
    let settled = false;
    const finish = (code: number): void => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      resolve({ code, output });
    };
    const timer = setTimeout(() => {
      if (settled) return;
      settled = true;
      child.kill();
      resolve({ code: -1, output });
    }, timeoutMs);
    child.stdout.on('data', (data: Buffer) => { output += data.toString(); });
    child.stderr.on('data', (data: Buffer) => { output += data.toString(); });
    child.on('error', () => finish(-1));
    child.on('close', (code) => finish(code ?? -1));
  });
}

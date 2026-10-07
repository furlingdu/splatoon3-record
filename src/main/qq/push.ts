import { stat } from 'node:fs/promises';
import { basename } from 'node:path';
import type { ReplyTarget } from '@tencent-connect/qqbot-nodejs';
import type { AppConfig, BattleMatch } from '../../shared/types.js';
import { pushFileLimitMb } from '../../shared/constants.js';
import { dropCopy, pushCopy } from '../match/pushcopy.js';
import { pushText } from './command.js';

const pushTimeoutMs = 180000;
const pushRetries = 2;

export interface PushSender {
  sendText: (target: ReplyTarget, text: string) => Promise<unknown>;
  sendMarkdown?: (target: ReplyTarget, text: string) => Promise<unknown>;
  sendFile: (target: ReplyTarget, file: { localPath: string }, options: { fileName: string }) => Promise<unknown>;
}

export function pushTarget(owner: string): ReplyTarget {
  return { scope: 'c2c', targetId: owner };
}

export function pushAllowed(config: AppConfig): boolean {
  return Boolean(config.pushEnabled && config.qqOwner);
}

export async function sendVideo(sender: PushSender, target: ReplyTarget, videoPath: string): Promise<void> {
  let failure: string | undefined;
  try {
    const file = await stat(videoPath);
    if (file.size > pushFileLimitMb * 1024 * 1024) {
      failure = `文件超过 QQ 单文件上限 ${pushFileLimitMb} MB`;
    } else {
      let lastError: unknown;
      for (let attempt = 0; attempt <= pushRetries; attempt++) {
        try {
          await withTimeout(sender.sendFile(target, { localPath: videoPath }, { fileName: basename(videoPath) }), pushTimeoutMs);
          return;
        } catch (error) {
          lastError = error;
          if (attempt < pushRetries) await sleepMs(1000);
        }
      }
      failure = lastError instanceof Error ? lastError.message : String(lastError);
    }
  } catch (error) {
    failure = error instanceof Error ? error.message : String(error);
  }
  if (failure) await sender.sendText(target, `录像发送失败：${failure}\n文件已保留在本地归档`).catch(() => undefined);
}

export async function pushRecord(sender: PushSender, target: ReplyTarget, config: AppConfig, match: BattleMatch): Promise<void> {
  const videoPath = match.videoPath;
  if (!videoPath) return;
  const copy = await pushCopy(match, config.settings).catch(() => undefined);
  if (!copy) {
    await sender.sendText(target, '录像发送失败：压制版生成失败\n文件已保留在本地归档').catch(() => undefined);
    return;
  }
  try {
    await sendVideo(sender, target, copy);
  } finally {
    await dropCopy(copy);
  }
}

export async function pushMatch(sender: PushSender, config: AppConfig, match: BattleMatch): Promise<void> {
  if (!pushAllowed(config)) return;
  try {
    const target = pushTarget(config.qqOwner as string);
    const text = pushText(match);
    if (sender.sendMarkdown) {
      try {
        await sender.sendMarkdown(target, text);
      } catch {
        await sender.sendText(target, text);
      }
    } else {
      await sender.sendText(target, text).catch(() => undefined);
    }
    if (match.videoPath) await pushRecord(sender, target, config, match);
  } catch (error) {
    await sender.sendText(pushTarget(config.qqOwner as string), `推送失败：${error instanceof Error ? error.message : String(error)}\n文件已保留在本地归档`).catch(() => undefined);
  }
}

function withTimeout(promise: Promise<unknown>, timeoutMs: number): Promise<unknown> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  return Promise.race([
    promise,
    new Promise((_, reject) => {
      timer = setTimeout(() => reject(new Error(`发送超时 ${timeoutMs / 1000} 秒`)), timeoutMs);
    }),
  ]).finally(() => {
    if (timer) clearTimeout(timer);
  });
}

function sleepMs(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

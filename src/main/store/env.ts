import { existsSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { config as loadDotenv } from 'dotenv';
import { livePortDefault, livePortRange, nsoBackendDefault, pushBitrateDefault, pushBitrateRange, pushCodecDefault, pushFileLimitMb, pushTargetMb } from '../../shared/constants.js';
import { dataPath } from './path.js';
import type { PushCodec } from '../../shared/types.js';

export interface PublicEnv {
  appName: string;
  projectName: string;
  version: string;
  projectUrl: string;
  userAgent: string;
  avatarUrl: string;
  groupUrl: string;
}

export interface PushEnv {
  cap: number;
  codec: PushCodec;
  targetMb: number;
}

export interface LiveEnv {
  port: number;
}

export interface NsoEnv {
  backendUrl: string;
}

loadEnvFile();

export function loadEnvFile(): void {
  for (const file of envFiles()) {
    if (!existsSync(file)) continue;
    loadDotenv({ path: file, override: false, quiet: true });
    return;
  }
}

export function pushEnv(): PushEnv {
  const cap = readFloat('PUSH_BITRATE_MBPS', pushBitrateDefault);
  const target = readNumber('PUSH_FILE_LIMIT_MB', pushTargetMb);
  return {
    cap: Math.min(pushBitrateRange.max, Math.max(pushBitrateRange.min, cap)),
    codec: readCodec(process.env.PUSH_CODEC),
    targetMb: Math.min(pushFileLimitMb, target),
  };
}

export function liveEnv(): LiveEnv {
  const port = readNumber('LIVE_PORT', livePortDefault);
  return { port: Math.min(livePortRange.max, Math.max(livePortRange.min, port)) };
}

export function nsoEnv(): NsoEnv {
  const raw = (process.env.NSO_BACKEND_URL ?? '').trim();
  return { backendUrl: isBackendUrl(raw) ? raw.replace(/\/+$/, '') : nsoBackendDefault };
}

export function publicEnv(): PublicEnv {
  const projectName = process.env.PROJECT_NAME || 'Splatoon3Record';
  const version = process.env.PROJECT_VERSION || '2.0.0';
  const projectUrl = process.env.PROJECT_URL || 'https://github.com/furlingdu/splatoon3-record';
  return {
    appName: process.env.APP_NAME || 'Splatoon3 Record',
    projectName,
    version,
    projectUrl,
    userAgent: process.env.NSO_USER_AGENT || `${projectName}/${version} (+${projectUrl})`,
    avatarUrl: process.env.AUTHOR_AVATAR_URL || 'https://q2.qlogo.cn/headimg_dl?dst_uin=3648192311&spec=640',
    groupUrl: process.env.QQ_GROUP_URL || '',
  };
}

export const userAgent = publicEnv().userAgent;

function envFiles(): string[] {
  return [join(process.cwd(), '.env'), join(dirname(process.execPath), '.env'), join(dataPath, '.env')];
}

function readNumber(key: string, fallback: number): number {
  const value = Number(process.env[key]);
  return Number.isFinite(value) && value > 0 ? Math.round(value) : fallback;
}

function readFloat(key: string, fallback: number): number {
  const value = Number(process.env[key]);
  return Number.isFinite(value) && value > 0 ? value : fallback;
}

function readCodec(raw: string | undefined): PushCodec {
  const text = (raw ?? '').trim().toLowerCase();
  if (text === 'hevc' || text === 'h265' || text === 'x265') return 'hevc';
  if (text === 'h264' || text === 'x264') return 'h264';
  if (text === 'av1') return 'av1';
  return pushCodecDefault;
}

function isBackendUrl(raw: string): boolean {
  if (!raw) return false;
  try {
    const url = new URL(raw);
    return url.protocol === 'http:' || url.protocol === 'https:';
  } catch {
    return false;
  }
}

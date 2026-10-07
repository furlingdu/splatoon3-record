import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { liveEnv, nsoEnv, pushEnv } from '../src/main/store/env.js';

const keys = ['PUSH_CODEC', 'PUSH_BITRATE_MBPS', 'PUSH_FILE_LIMIT_MB', 'LIVE_PORT', 'NSO_BACKEND_URL'];

function clearEnv(): void {
  for (const key of keys) delete process.env[key];
}

beforeEach(clearEnv);
afterEach(clearEnv);

describe('pushEnv', () => {
  it('缺省时给出 HEVC、2 Mbps 上限与 100 MB 目标体积', () => {
    expect(pushEnv()).toEqual({ cap: 2, codec: 'hevc', targetMb: 100 });
  });

  it('支持小数码率上限', () => {
    process.env.PUSH_BITRATE_MBPS = '0.5';
    expect(pushEnv().cap).toBe(0.5);
  });

  it('可切到 AV1 并收紧目标体积', () => {
    process.env.PUSH_CODEC = 'AV1';
    process.env.PUSH_FILE_LIMIT_MB = '15';
    expect(pushEnv()).toEqual({ cap: 2, codec: 'av1', targetMb: 15 });
  });

  it('目标体积不允许超过 QQ 单文件硬上限', () => {
    process.env.PUSH_FILE_LIMIT_MB = '900';
    expect(pushEnv().targetMb).toBe(100);
  });

  it('非法值与越界码率回退默认', () => {
    process.env.PUSH_BITRATE_MBPS = '0';
    process.env.PUSH_CODEC = 'invalid_codec';
    expect(pushEnv()).toEqual({ cap: 2, codec: 'hevc', targetMb: 100 });
    process.env.PUSH_BITRATE_MBPS = '900';
    expect(pushEnv().cap).toBe(50);
  });
});

describe('liveEnv', () => {
  it('缺省时给出内置端口', () => {
    expect(liveEnv()).toEqual({ port: 11567 });
  });

  it('按 .env 覆盖端口', () => {
    process.env.LIVE_PORT = '19350';
    expect(liveEnv()).toEqual({ port: 19350 });
  });

  it('端口越界按内置范围夹取', () => {
    process.env.LIVE_PORT = '80';
    expect(liveEnv().port).toBe(1024);
    process.env.LIVE_PORT = '70000';
    expect(liveEnv().port).toBe(65535);
  });

  it('非法端口回退内置默认', () => {
    process.env.LIVE_PORT = 'abc';
    expect(liveEnv()).toEqual({ port: 11567 });
  });
});

describe('nsoEnv', () => {
  it('缺省时给出内置 znca 后端', () => {
    expect(nsoEnv()).toEqual({ backendUrl: 'https://znca.furlingdu.com' });
  });

  it('按 .env 覆盖后端并去掉尾部斜杠', () => {
    process.env.NSO_BACKEND_URL = 'https://nso.example.cn/api/znca/';
    expect(nsoEnv()).toEqual({ backendUrl: 'https://nso.example.cn/api/znca' });
  });

  it('非法值回退内置后端', () => {
    process.env.NSO_BACKEND_URL = 'not-a-url';
    expect(nsoEnv()).toEqual({ backendUrl: 'https://znca.furlingdu.com' });
    process.env.NSO_BACKEND_URL = 'ftp://nso.example.cn/znca';
    expect(nsoEnv()).toEqual({ backendUrl: 'https://znca.furlingdu.com' });
  });
});

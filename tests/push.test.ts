import { stat } from 'node:fs/promises';
import { CHUNKED_UPLOAD_MAX_SIZE, LARGE_FILE_THRESHOLD, MAX_UPLOAD_SIZE } from '@tencent-connect/qqbot-nodejs';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { pushAllowed, pushMatch, pushRecord, pushTarget, sendVideo } from '../src/main/qq/push.js';
import { dropCopy, pushCopy } from '../src/main/match/pushcopy.js';
import { defaultSettings, pushFileLimitMb, pushTargetMb } from '../src/shared/constants.js';
import type { AppConfig, BattleMatch } from '../src/shared/types.js';

vi.mock('node:fs/promises', () => ({ stat: vi.fn().mockResolvedValue({ size: 1024 }) }));
vi.mock('../src/main/match/pushcopy.js', () => ({ pushCopy: vi.fn(), dropCopy: vi.fn().mockResolvedValue(undefined) }));

const statFile = vi.mocked(stat);
const copyFile = vi.mocked(pushCopy);
const dropFile = vi.mocked(dropCopy);
const copyPath = 'D:/cache/tmp/push1/占地对战-20260916-221530.mp4';

beforeEach(() => {
  statFile.mockClear();
  statFile.mockResolvedValue({ size: 1024 } as never);
  copyFile.mockClear();
  copyFile.mockResolvedValue(copyPath);
  dropFile.mockClear();
});

function makeConfig(part: Partial<AppConfig>): AppConfig {
  return { settings: { ...defaultSettings, saveDir: 'D:/videos' }, pushEnabled: true, setupDone: false, handledIds: [], ...part };
}

const match = { matchId: 'm1', kind: 'regular', mode: 'REGULAR', rule: 'TURF_WAR', startAt: 0, endAt: 1000, duration: 1000, result: 'WIN', isDisconnected: false, isSalmon: false, videoPath: 'D:/tmp/占地对战-20260916-221530.mp4', rawData: {} } satisfies BattleMatch;

describe('pushAllowed', () => {
  it('默认开启且绑定后允许推送', () => {
    expect(pushAllowed(makeConfig({ qqOwner: 'user-a' }))).toBe(true);
  });

  it('关闭推送或未绑定用户时禁止', () => {
    expect(pushAllowed(makeConfig({ qqOwner: 'user-a', pushEnabled: false }))).toBe(false);
    expect(pushAllowed(makeConfig({ qqOwner: undefined }))).toBe(false);
  });
});

describe('pushTarget', () => {
  it('生成 C2C 推送目标', () => {
    expect(pushTarget('user-a')).toEqual({ scope: 'c2c', targetId: 'user-a' });
  });
});

describe('pushMatch', () => {
  it('发送对局文本与压制后的录像文件', async () => {
    const sender = { sendText: vi.fn().mockResolvedValue({}), sendFile: vi.fn().mockResolvedValue({}) };
    await pushMatch(sender, makeConfig({ qqOwner: 'user-a' }), match);
    expect(sender.sendText).toHaveBeenCalledTimes(1);
    expect(sender.sendText.mock.calls[0][1]).toContain('新对局，已成功录制对局');
    expect(sender.sendFile).toHaveBeenCalledWith({ scope: 'c2c', targetId: 'user-a' }, { localPath: copyPath }, { fileName: '占地对战-20260916-221530.mp4' });
    expect(dropFile).toHaveBeenCalledWith(copyPath);
  });

  it('推送文本只说明已压制，不含任何路径', async () => {
    const sender = { sendText: vi.fn().mockResolvedValue({}), sendFile: vi.fn().mockResolvedValue({}) };
    await pushMatch(sender, makeConfig({ qqOwner: 'user-a' }), match);
    const text = sender.sendText.mock.calls[0][1];
    expect(text).toContain('本条消息附带的视频已压制为 1080p60');
    expect(text).not.toContain('当前视频路径');
    expect(text).not.toContain('原视频请前往录制文件夹获取');
    expect(text).not.toContain(match.videoPath as string);
  });

  it('压制失败时不改发原画，只提示保留本地', async () => {
    copyFile.mockResolvedValue(undefined);
    const sender = { sendText: vi.fn().mockResolvedValue({}), sendFile: vi.fn().mockResolvedValue({}) };
    await pushMatch(sender, makeConfig({ qqOwner: 'user-a' }), match);
    expect(sender.sendFile).not.toHaveBeenCalled();
    expect(dropFile).not.toHaveBeenCalled();
    expect(sender.sendText.mock.calls.at(-1)?.[1]).toContain('压制版生成失败');
    expect(sender.sendText.mock.calls.at(-1)?.[1]).toContain('文件已保留在本地归档');
  });

  it('支持 Markdown 推送', async () => {
    const sender = { sendText: vi.fn().mockResolvedValue({}), sendMarkdown: vi.fn().mockResolvedValue({}), sendFile: vi.fn().mockResolvedValue({}) };
    await pushMatch(sender, makeConfig({ qqOwner: 'user-a' }), match);
    expect(sender.sendMarkdown).toHaveBeenCalledTimes(1);
    expect(sender.sendText).not.toHaveBeenCalled();
  });

  it('Markdown 推送失败时回退文本', async () => {
    const sender = { sendText: vi.fn().mockResolvedValue({}), sendMarkdown: vi.fn().mockRejectedValue(new Error('denied')), sendFile: vi.fn().mockResolvedValue({}) };
    await pushMatch(sender, makeConfig({ qqOwner: 'user-a' }), match);
    expect(sender.sendMarkdown).toHaveBeenCalledTimes(1);
    expect(sender.sendText).toHaveBeenCalledTimes(1);
  });

  it('未开启推送时不发送', async () => {
    const sender = { sendText: vi.fn(), sendFile: vi.fn() };
    await pushMatch(sender, makeConfig({ pushEnabled: false, qqOwner: 'user-a' }), match);
    expect(sender.sendText).not.toHaveBeenCalled();
    expect(copyFile).not.toHaveBeenCalled();
  });

  it('文件发送失败时回退文本提示且不中断', async () => {
    const sender = { sendText: vi.fn().mockResolvedValue({}), sendFile: vi.fn().mockRejectedValue(new Error('too large')) };
    await pushMatch(sender, makeConfig({ qqOwner: 'user-a' }), match);
    expect(sender.sendFile).toHaveBeenCalledTimes(3);
    expect(sender.sendText).toHaveBeenCalledTimes(2);
    expect(sender.sendText.mock.calls.at(-1)?.[1]).toContain('录像发送失败');
  });

  it('文件超过 QQ 单文件上限时跳过发送并提示保留本地', async () => {
    statFile.mockResolvedValueOnce({ size: pushFileLimitMb * 1024 * 1024 + 1 } as never);
    const sender = { sendText: vi.fn().mockResolvedValue({}), sendFile: vi.fn() };
    await pushMatch(sender, makeConfig({ qqOwner: 'user-a' }), match);
    expect(sender.sendFile).not.toHaveBeenCalled();
    expect(sender.sendText.mock.calls.at(-1)?.[1]).toContain(`文件超过 QQ 单文件上限 ${pushFileLimitMb} MB`);
    expect(sender.sendText.mock.calls.at(-1)?.[1]).toContain('文件已保留在本地归档');
  });
});

describe('pushRecord', () => {
  it('没有录像路径时不做任何发送', async () => {
    const sender = { sendText: vi.fn(), sendFile: vi.fn() };
    await pushRecord(sender, pushTarget('user-a'), makeConfig({ qqOwner: 'user-a' }), { ...match, videoPath: undefined });
    expect(sender.sendFile).not.toHaveBeenCalled();
    expect(copyFile).not.toHaveBeenCalled();
  });
});

describe('sendVideo', () => {
  it('手动发送超限录像时不调用 SDK', async () => {
    statFile.mockResolvedValueOnce({ size: pushFileLimitMb * 1024 * 1024 + 1 } as never);
    const sender = { sendText: vi.fn().mockResolvedValue({}), sendFile: vi.fn() };
    await sendVideo(sender, pushTarget('user-a'), 'D:/tmp/m1.mp4');
    expect(sender.sendFile).not.toHaveBeenCalled();
    expect(sender.sendText.mock.calls[0][1]).toContain(`文件超过 QQ 单文件上限 ${pushFileLimitMb} MB`);
    expect(sender.sendText.mock.calls[0][1]).toContain('文件已保留在本地归档');
  });

  it('上限以内的录像整局交给 SDK 发送，不做分卷', async () => {
    const sender = { sendText: vi.fn().mockResolvedValue({}), sendFile: vi.fn().mockResolvedValue({}) };
    await sendVideo(sender, pushTarget('user-a'), 'D:/tmp/m1.mp4');
    expect(sender.sendFile).toHaveBeenCalledWith({ scope: 'c2c', targetId: 'user-a' }, { localPath: 'D:/tmp/m1.mp4' }, { fileName: 'm1.mp4' });
  });
});

describe('QQ 上传限额', () => {
  it('内置上限与 SDK 常量一致', () => {
    expect(pushFileLimitMb * 1024 * 1024).toBe(CHUNKED_UPLOAD_MAX_SIZE);
    expect(pushTargetMb).toBeLessThanOrEqual(pushFileLimitMb);
    expect(pushTargetMb * 1024 * 1024).toBeGreaterThan(LARGE_FILE_THRESHOLD);
    expect(pushTargetMb * 1024 * 1024).toBeGreaterThan(MAX_UPLOAD_SIZE);
  });
});

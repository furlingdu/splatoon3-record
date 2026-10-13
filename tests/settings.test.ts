import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';
import { sanitizeSettings } from '../src/main/capture/settings.js';
import { startupBackend } from '../src/main/store/config.js';
import { defaultSettings } from '../src/shared/constants.js';
import type { RecordSettings } from '../src/shared/types.js';

describe('sanitizeSettings', () => {
  it('保留 NV12 采集开关且缺省关闭', () => {
    const base: RecordSettings = { ...defaultSettings };
    expect(sanitizeSettings({}, base).nv12Capture).toBe(false);
    expect(sanitizeSettings({ nv12Capture: true }, base).nv12Capture).toBe(true);
  });

  it('保留采集画面格式且非法值回退 NV12', () => {
    const base: RecordSettings = { ...defaultSettings };
    expect(sanitizeSettings({}, base).captureFormat).toBe('nv12');
    expect(sanitizeSettings({ captureFormat: 'yuy2' }, base).captureFormat).toBe('yuy2');
    expect(sanitizeSettings({ captureFormat: 'mjpeg' }, base).captureFormat).toBe('nv12');
  });
});

describe('startupBackend', () => {
  async function withRoot<T>(task: (root: string) => Promise<T>): Promise<T> {
    const root = await mkdtemp(join(tmpdir(), 's3rBackend'));
    try {
      return await task(root);
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  }

  it('配置开启 NV12 采集后启动走 Media Foundation', async () => {
    await withRoot(async (root) => {
      const file = join(root, 'config.json');
      await writeFile(file, JSON.stringify({ settings: { nv12Capture: true } }), 'utf8');
      expect(startupBackend(file)).toBe('mf');
      await writeFile(file, JSON.stringify({ settings: { nv12Capture: true, captureFormat: 'nv12' } }), 'utf8');
      expect(startupBackend(file)).toBe('mf');
    });
  });

  it('配置选择 YUY2 格式后启动走 DirectShow', async () => {
    await withRoot(async (root) => {
      const file = join(root, 'config.json');
      await writeFile(file, JSON.stringify({ settings: { nv12Capture: true, captureFormat: 'yuy2' } }), 'utf8');
      expect(startupBackend(file)).toBe('dshow');
    });
  });

  it('缺省、未开启与损坏配置回退 DirectShow', async () => {
    await withRoot(async (root) => {
      const file = join(root, 'config.json');
      expect(startupBackend(file)).toBe('dshow');
      await writeFile(file, JSON.stringify({ settings: { nv12Capture: false } }), 'utf8');
      expect(startupBackend(file)).toBe('dshow');
      await writeFile(file, '{not json', 'utf8');
      expect(startupBackend(file)).toBe('dshow');
    });
  });
});

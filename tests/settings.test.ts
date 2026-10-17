import { describe, expect, it } from 'vitest';
import { sanitizeSettings } from '../src/main/capture/settings.js';
import { defaultSettings } from '../src/shared/constants.js';
import type { RecordSettings } from '../src/shared/types.js';

describe('sanitizeSettings', () => {
  it('保留更新开关且缺省按默认值', () => {
    const base: RecordSettings = { ...defaultSettings };
    expect(sanitizeSettings({}, base).updateProxy).toBe(false);
    expect(sanitizeSettings({}, base).updateCheck).toBe(true);
    expect(sanitizeSettings({ updateProxy: true, updateCheck: false }, base)).toMatchObject({ updateProxy: true, updateCheck: false });
  });

  it('保留电脑声音与麦克风录制设置', () => {
    const base: RecordSettings = { ...defaultSettings };
    expect(sanitizeSettings({}, base)).toMatchObject({ desktopAudio: false, micAudio: false, micDevice: '' });
    expect(sanitizeSettings({ desktopAudio: true, micAudio: true, micDevice: 'mic1' }, base)).toMatchObject({ desktopAudio: true, micAudio: true, micDevice: 'mic1' });
  });

  it('丢弃已移除的采集后端字段', () => {
    const base: RecordSettings = { ...defaultSettings };
    const settings = sanitizeSettings({ nv12Capture: true, captureFormat: 'yuy2' }, base) as unknown as Record<string, unknown>;
    expect(settings.nv12Capture).toBeUndefined();
    expect(settings.captureFormat).toBeUndefined();
  });
});

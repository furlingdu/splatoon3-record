import { describe, expect, it } from 'vitest';
import { join } from 'node:path';
import { sanitizeSettings } from '../src/main/capture/settings.js';
import { backgroundDir } from '../src/main/store/path.js';
import { defaultSettings, defaultThemeColor } from '../src/shared/constants.js';
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

  it('保留并校验采集格式偏好', () => {
    const base: RecordSettings = { ...defaultSettings };
    expect(sanitizeSettings({}, base).captureFormat).toBe('nv12');
    expect(sanitizeSettings({ captureFormat: 'yuy2' }, base).captureFormat).toBe('yuy2');
    expect(sanitizeSettings({ captureFormat: 'invalid' }, base).captureFormat).toBe('nv12');
  });

  it('校验主题色与背景路径', () => {
    const base: RecordSettings = { ...defaultSettings };
    expect(sanitizeSettings({}, base).themeColor).toBe(defaultThemeColor);
    expect(sanitizeSettings({ themeColor: '#FF9800' }, base).themeColor).toBe('#ff9800');
    expect(sanitizeSettings({ themeColor: 'red' }, base).themeColor).toBe(defaultThemeColor);
    const inside = join(backgroundDir, 'background-1.png');
    expect(sanitizeSettings({ backgroundPath: inside }, base).backgroundPath).toBe(inside);
    expect(sanitizeSettings({ backgroundPath: 'C:/Windows/win.ini' }, base).backgroundPath).toBe('');
    expect(sanitizeSettings({}, base).backgroundDim).toBe(40);
    expect(sanitizeSettings({ backgroundDim: 70 }, base).backgroundDim).toBe(70);
    expect(sanitizeSettings({ backgroundDim: 200 }, base).backgroundDim).toBe(100);
    expect(sanitizeSettings({ backgroundDim: -5 }, base).backgroundDim).toBe(0);
  });
});

import { describe, expect, it } from 'vitest';
import { notesOf, pickAsset, releaseUrl, safeFileName, updateUrls } from '../src/main/update/release.js';

describe('releaseUrl', () => {
  it('从项目地址推导发行版接口', () => {
    expect(releaseUrl('https://github.com/furlingdu/splatoon3-record')).toBe('https://api.github.com/repos/furlingdu/splatoon3-record/releases/latest');
    expect(releaseUrl('https://github.com/furlingdu/splatoon3-record.git')).toBe('https://api.github.com/repos/furlingdu/splatoon3-record/releases/latest');
  });

  it('不是 GitHub 地址时返回 undefined', () => {
    expect(releaseUrl('https://example.com/x')).toBeUndefined();
    expect(releaseUrl('')).toBeUndefined();
  });
});

describe('updateUrls', () => {
  it('开启加速时把加速前缀拼在原地址前并保留直连回退', () => {
    expect(updateUrls('https://github.com/a/b/x.exe', 'https://gh-proxy.com/', true)).toEqual([
      'https://gh-proxy.com/https://github.com/a/b/x.exe',
      'https://github.com/a/b/x.exe',
    ]);
  });

  it('关闭加速时直连优先', () => {
    expect(updateUrls('https://github.com/a/b/x.exe', 'https://gh-proxy.com/', false)[0]).toBe('https://github.com/a/b/x.exe');
  });
});

describe('pickAsset', () => {
  const assets = [
    { name: 'splatoon3Record2.3.0arm64Setup.exe', browser_download_url: 'https://github.com/a/b/arm64.exe', size: 10 },
    { name: 'splatoon3Record2.3.0x64Setup.exe', browser_download_url: 'https://github.com/a/b/x64.exe', size: 20 },
    { name: 'splatoon3Record2.3.0x64.dmg', browser_download_url: 'https://github.com/a/b/x64.dmg', size: 30 },
    { name: 'splatoon3Record2.3.0arm64.dmg', browser_download_url: 'https://github.com/a/b/arm64.dmg', size: 40 },
    { name: 'splatoon3Record2.3.0.AppImage', browser_download_url: 'https://github.com/a/b/app.AppImage', size: 50 },
  ];

  it('按系统与架构挑选资产', () => {
    expect(pickAsset(assets, 'win32', 'x64')?.name).toBe('splatoon3Record2.3.0x64Setup.exe');
    expect(pickAsset(assets, 'win32', 'arm64')?.name).toBe('splatoon3Record2.3.0arm64Setup.exe');
    expect(pickAsset(assets, 'darwin', 'arm64')?.name).toBe('splatoon3Record2.3.0arm64.dmg');
    expect(pickAsset(assets, 'darwin', 'x64')?.name).toBe('splatoon3Record2.3.0x64.dmg');
    expect(pickAsset(assets, 'linux', 'x64')?.name).toBe('splatoon3Record2.3.0.AppImage');
  });

  it('没有匹配资产时返回 undefined', () => {
    expect(pickAsset([{ name: 'source.zip', browser_download_url: 'https://github.com/a/b/s.zip' }], 'win32', 'x64')).toBeUndefined();
    expect(pickAsset([], 'win32', 'x64')).toBeUndefined();
  });
});

describe('notesOf', () => {
  it('截断过长的更新说明', () => {
    expect(notesOf(' a\nb ', 10)).toBe('a\nb');
    expect(notesOf('x'.repeat(30), 10)).toBe('x'.repeat(10));
    expect(notesOf(undefined, 10)).toBeUndefined();
  });
});

describe('safeFileName', () => {
  it('剔除文件名中的非法字符', () => {
    expect(safeFileName('a/b:c?.exe')).toBe('a_b_c_.exe');
    expect(safeFileName('')).toBe('update');
  });
});

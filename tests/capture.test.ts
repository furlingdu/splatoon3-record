import { describe, expect, it } from 'vitest';
import { chooseMime, cleanNames, deviceKey, deviceLabel, deviceName, formatText, fpsList, matchDevice, mimeCandidates, resolutionKey, resolutionList, resolutionText } from '../src/shared/capture.js';
import type { CaptureDevice } from '../src/shared/types.js';

const camera: CaptureDevice = { id: 'cam1', name: 'Camera', kind: 'video', maxWidth: 1920, maxHeight: 1080, maxFps: 30 };

describe('resolutionKey', () => {
  it('拼出画幅键', () => {
    expect(resolutionKey(1920, 1080)).toBe('1920x1080');
    expect(resolutionText(1920, 1080)).toBe('1920 x 1080');
  });
});

describe('resolutionList', () => {
  it('无设备信息时给出全部档位', () => {
    expect(resolutionList()).toContainEqual({ width: 3840, height: 2160 });
  });

  it('按设备上限裁剪档位', () => {
    expect(resolutionList(camera)).toEqual([
      { width: 1920, height: 1080 },
      { width: 1280, height: 720 },
      { width: 960, height: 540 },
    ]);
  });

  it('并入设备默认档位与当前档位', () => {
    const device: CaptureDevice = { id: 'cam1', name: 'Camera', kind: 'video', maxWidth: 1920, maxHeight: 1080, nativeWidth: 1600, nativeHeight: 900 };
    expect(resolutionList(device)).toContainEqual({ width: 1600, height: 900 });
    expect(resolutionList(device, { width: 2560, height: 1440 })[0]).toEqual({ width: 2560, height: 1440 });
  });

  it('上限低于全部预设时保留上限档位', () => {
    expect(resolutionList({ id: 'a', name: 'a', kind: 'video', maxWidth: 800, maxHeight: 600 })).toEqual([{ width: 800, height: 600 }]);
  });
});

describe('fpsList', () => {
  it('按设备上限裁剪帧率', () => {
    expect(fpsList()).toEqual([30, 60]);
    expect(fpsList(camera)).toEqual([30]);
    expect(fpsList({ id: 'a', name: 'a', kind: 'video', maxFps: 120 })).toEqual([30, 60]);
  });

  it('并入设备默认帧率与当前帧率', () => {
    expect(fpsList({ id: 'a', name: 'a', kind: 'video', maxFps: 120, nativeFps: 50 })).toEqual([30, 50, 60]);
    expect(fpsList(camera, 24)).toEqual([24, 30]);
  });
});

describe('deviceName', () => {
  it('去掉 Chromium 追加的芯片编号', () => {
    expect(deviceName('USB3 Video (345f:2132)')).toBe('USB3 Video');
    expect(deviceName('数字音频接口 (USB3 Digital Audio) (345f:2132)')).toBe('数字音频接口 (USB3 Digital Audio)');
    expect(deviceName('OBS Virtual Camera')).toBe('OBS Virtual Camera');
    expect(deviceKey('USB3 Video (345F:2132)')).toBe('usb3 video');
  });
});

describe('cleanNames', () => {
  it('同名设备保留编号区分', () => {
    const list = cleanNames([
      { id: 'a', name: 'Capture (1111:2222)', kind: 'video' },
      { id: 'b', name: 'Capture (3333:4444)', kind: 'video' },
      { id: 'c', name: 'USB3 Video (345f:2132)', kind: 'video' },
    ]);
    expect(list.map((item) => item.name)).toEqual(['Capture (1111:2222)', 'Capture (3333:4444)', 'USB3 Video']);
  });
});

describe('matchDevice', () => {
  const list: CaptureDevice[] = [
    { id: 'usb3', name: 'USB3 Video', kind: 'video' },
    { id: 'mic', name: '数字音频接口 (USB3 Digital Audio)', kind: 'audio' },
  ];

  it('按标识、名称、去编号名称依次匹配', () => {
    expect(matchDevice(list, 'video', 'usb3')?.id).toBe('usb3');
    expect(matchDevice(list, 'video', 'USB3 Video (345f:2132)')?.id).toBe('usb3');
    expect(matchDevice(list, 'audio', '数字音频接口 (USB3 Digital Audio)')?.id).toBe('mic');
    expect(matchDevice(list, 'video', 'Unknown')).toBeUndefined();
    expect(matchDevice(list, 'video', undefined)).toBeUndefined();
  });
});

describe('chooseMime', () => {
  it('优先选择带音频的 mp4', () => {
    expect(chooseMime(() => true, true)?.ext).toBe('mp4');
    expect(chooseMime(() => true, true)?.type).toContain('avc1');
  });

  it('不支持 mp4 时回退到 mkv 与 webm', () => {
    expect(chooseMime((type) => type.includes('matroska'), true)?.ext).toBe('mkv');
    expect(chooseMime((type) => type.includes('webm'), false)?.ext).toBe('webm');
  });

  it('全部不支持时返回 undefined', () => {
    expect(chooseMime(() => false, true)).toBeUndefined();
  });

  it('纯视频优先取 avc1 硬解友好格式', () => {
    expect(mimeCandidates(false)[0].codec).toBe('avc1');
    expect(mimeCandidates(true)[0].type).toContain('mp4a');
  });
});

describe('mimeCandidates 录制顺序', () => {
  it('录制候选把 HEVC MP4 排在最前', () => {
    const list = mimeCandidates(true, 'hevc');
    expect(list[0].type).toBe('video/mp4;codecs=hvc1.1.6.L150.B0,mp4a.40.2');
    expect(list[0].ext).toBe('mp4');
    expect(chooseMime(() => true, true, 'hevc')?.type).toContain('hvc1');
  });

  it('HEVC 不被支持时回退到 H.264 MP4', () => {
    const picked = chooseMime((type) => !type.includes('hvc1'), true, 'hevc');
    expect(picked?.type).toBe('video/mp4;codecs=avc1,mp4a.40.2');
  });

  it('HEVC 优先时保留 WebM 与 mkv 回退', () => {
    const list = mimeCandidates(true, 'hevc').map((item) => item.type);
    expect(list).toContain('video/webm;codecs=h264,opus');
    expect(list).toContain('video/x-matroska;codecs=avc1,opus');
  });

  it('WebM 优先时把 WebM 容器排在最前', () => {
    const list = mimeCandidates(true, 'webm');
    expect(list[0].type).toBe('video/webm;codecs=h264,opus');
    expect(list[0].ext).toBe('webm');
  });

  it('默认候选顺序保持 mp4 优先', () => {
    expect(mimeCandidates(true)[0].type).toBe('video/mp4;codecs=avc1,mp4a.40.2');
  });
});

describe('deviceLabel', () => {
  it('缺名时按类型兜底', () => {
    expect(deviceLabel({ id: 'a', name: 'Card', kind: 'video' })).toBe('Card');
    expect(deviceLabel({ id: 'a', name: '', kind: 'audio' })).toBe('音频设备');
  });
});

describe('formatText', () => {
  it('转成易读格式', () => {
    expect(formatText()).toBe('未开始采集');
    expect(formatText('video/mp4;codecs=avc1')).toBe('mp4 · avc1');
  });
});

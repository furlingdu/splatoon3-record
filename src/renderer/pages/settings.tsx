import { useEffect, useState, type ReactElement } from 'react';
import { snackbar } from 'mdui/functions/snackbar.js';
import { setColorScheme } from 'mdui/functions/setColorScheme.js';
import { useElementEvent, restoreSelect, targetChecked, targetValue } from '../lib/event.js';
import { EncodeHint } from '../components/encodehint.js';
import { iconSvg } from '../lib/icons.js';
import { refreshDevices, useSession } from '../lib/session.js';
import { probedFps } from '../lib/device.js';
import { deviceLabel, clampModeFps, formatLabel, fpsList, matchDevice, modeFormats, modeFpsList, modeResolutions, pickMode, resolutionKey, resolutionList, resolutionText } from '../../shared/capture.js';
import { defaultSettings, defaultThemeColor, qualityTiers } from '../../shared/constants.js';
import type { AppStatus, CaptureFormat, CaptureMode, RecordSettings } from '../../shared/types.js';

const encoderOptions = [
  { value: 'auto', label: '自动选择' },
  { value: 'nvidia', label: 'NVIDIA NVENC' },
  { value: 'amd', label: 'AMD AMF' },
  { value: 'intel', label: 'Intel QSV' },
  { value: 'software', label: '软件编码' },
];

const encoderHints: Record<string, string> = {
  auto: '',
  nvidia: '使用 NVIDIA 显卡的 NVENC 硬件编码。',
  amd: '使用 AMD 显卡的 AMF 硬件编码。',
  intel: '使用 Intel 核显的 QSV 硬件编码。',
  software: '使用 CPU 软件编码，画质上限最高但 CPU 占用大。',
};

const qualityLabels: Record<number, string> = {
  18: '高质量、存储占用大',
  22: '普通质量、存储占用适中',
  28: '低质量、存储占用小',
};

const themeColors = ['#4285f4', '#3f51b5', '#9c27b0', '#e91e63', '#f44336', '#ff9800', '#4caf50', '#009688', '#00bcd4', '#607d8b'];

function settingsPage(props: { status?: AppStatus }): ReactElement {
  const status = props.status;
  const session = useSession();
  const settings = status?.settings;
  const [loading, setLoading] = useState(false);
  const [modes, setModes] = useState<CaptureMode[]>([]);
  const [restartHint, setRestartHint] = useState('');
  const [restartOpen, setRestartOpen] = useState(false);
  const [colorOpen, setColorOpen] = useState(false);
  const [draftColor, setDraftColor] = useState(defaultThemeColor);
  const colorCloseRef = useElementEvent<HTMLElement>('closed', () => {
    setColorOpen(false);
    setColorScheme(settings?.themeColor || defaultThemeColor);
  });
  const videoDevice = matchDevice(session.devices, 'video', settings?.videoDevice);
  const audioDevice = matchDevice(session.devices, 'audio', settings?.audioDevice);
  const micDevice = matchDevice(session.devices, 'audio', settings?.micDevice);
  const captureFormat: CaptureFormat = settings?.captureFormat ?? defaultSettings.captureFormat;
  const modeSizes = modeResolutions(modes, captureFormat);
  const resolutions = modeSizes.length ? modeSizes : resolutionList(videoDevice, settings ? { width: settings.width, height: settings.height } : undefined);
  const modeRates = settings ? modeFpsList(modes, captureFormat, settings.width, settings.height, settings.fps) : [];
  const probed = settings && videoDevice ? probedFps(videoDevice.id, settings.width, settings.height) : undefined;
  const sizes = modeRates.length ? modeRates : fpsList(videoDevice, settings?.fps, probed);
  const sizeMissed = Boolean(settings) && session.width > 0 && !session.applying && (session.width !== settings?.width || session.height !== settings?.height);
  const fpsMissed = Boolean(settings) && session.fps > 0 && !session.applying && Math.abs(session.fps - (settings?.fps || 0)) > 0.5;

  useEffect(() => {
    setLoading(true);
    void refreshDevices().finally(() => setLoading(false));
  }, []);
  useEffect(() => {
    if (!settings || !videoDevice?.name) {
      setModes([]);
      return undefined;
    }
    let alive = true;
    setModes([]);
    void window.recordApi.listModes(videoDevice.name).then((list) => {
      if (alive) setModes(list);
    }).catch(() => {
      if (alive) setModes([]);
    });
    return () => { alive = false; };
  }, [settings?.videoDevice, videoDevice?.name]);
  useEffect(() => {
    if (colorOpen) setColorScheme(draftColor);
    else setColorScheme(settings?.themeColor || defaultThemeColor);
  }, [colorOpen, draftColor, settings?.themeColor]);

  const save = (part: Partial<RecordSettings>): void => {
    if (!settings) return;
    void window.recordApi.saveSettings({ ...settings, ...part }).catch(() => snackbar({ message: '保存设置失败' }));
  };

  const deviceRef = useElementEvent<HTMLElement>('change', (event) => {
    const name = nameOf(event);
    const value = targetValue(event);
    if (!settings) return;
    const current = name === 'videoDevice' ? videoDevice?.id : name === 'micDevice' ? micDevice?.id : audioDevice?.id;
    if (value === '' && restoreSelect(event)) return;
    if (current === value) return;
    if (name === 'videoDevice') save({ videoDevice: value, width: defaultSettings.width, height: defaultSettings.height, fps: defaultSettings.fps });
    else if (name === 'micDevice') save({ micDevice: value });
    else save({ audioDevice: value });
  });
  const sizeRef = useElementEvent<HTMLElement>('change', (event) => {
    const value = targetValue(event);
    if (!settings) return;
    const current = resolutionKey(settings.width, settings.height);
    if (value === '' && restoreSelect(event, current)) return;
    const size = value.match(/^(\d+)x(\d+)$/);
    if (!size || current === value) return;
    save({ width: Number(size[1]), height: Number(size[2]) });
  });
  const fpsRef = useElementEvent<HTMLElement>('change', (event) => {
    const value = Number(targetValue(event));
    if (!settings || !Number.isFinite(value) || settings.fps === value) return;
    save({ fps: value });
  });
  const encoderRef = useElementEvent<HTMLElement>('change', (event) => {
    const name = nameOf(event);
    const value = targetValue(event);
    if (!settings) return;
    if (value === '' && restoreSelect(event, String(settings.encoder))) return;
    if (String(settings.encoder) === value) return;
    save({ [name]: value } as Partial<RecordSettings>);
  });
  const switchRef = useElementEvent<HTMLElement>('change', (event) => {
    const name = nameOf(event);
    const checked = targetChecked(event);
    if (!settings || Boolean((settings as unknown as Record<string, unknown>)[name]) === checked) return;
    save({ [name]: checked } as Partial<RecordSettings>);
  });
  const formatRef = useElementEvent<HTMLElement>('change', (event) => {
    const value = targetValue(event) as CaptureFormat;
    if (!settings || (value !== 'nv12' && value !== 'yuy2') || captureFormat === value) return;
    const part: Partial<RecordSettings> = { captureFormat: value };
    const pick = pickMode(modes, value, settings.width, settings.height, settings.fps);
    if (pick) {
      part.width = pick.width;
      part.height = pick.height;
      part.fps = clampModeFps(pick, settings.fps);
    }
    void window.recordApi.saveSettings({ ...settings, ...part }).then(() => {
      setRestartHint(`采集格式已切换为 ${formatLabel(value)}，请重启应用程序。`);
      setRestartOpen(true);
    }).catch(() => snackbar({ message: '保存设置失败' }));
  });
  const qualityRef = useElementEvent<HTMLElement>('change', (event) => {
    const value = Number(targetValue(event));
    if (!settings || !Number.isFinite(value) || settings.quality === value) return;
    save({ quality: value });
  });
  const pickRef = useElementEvent<HTMLElement>('click', () => {
    void window.recordApi.pickFolder().then((folder) => {
      if (folder) save({ saveDir: folder });
    });
  });
  const reloadRef = useElementEvent<HTMLElement>('click', () => {
    setLoading(true);
    void refreshDevices().finally(() => setLoading(false));
  });
  const pickBackground = (): void => {
    void window.recordApi.pickBackground().then((path) => {
      if (path) save({ backgroundPath: path });
    }).catch((error) => snackbar({ message: errorText(error, '更换背景失败') }));
  };
  const resetBackground = (): void => save({ backgroundPath: '' });
  const dimRef = useElementEvent<HTMLElement>('change', (event) => {
    const value = Math.round(Number(targetValue(event)));
    if (!settings || !Number.isFinite(value) || settings.backgroundDim === value) return;
    save({ backgroundDim: Math.max(0, Math.min(100, value)) });
  });
  const openPalette = (): void => {
    setDraftColor(settings?.themeColor || defaultThemeColor);
    setColorOpen(true);
  };
  const applyColor = (): void => {
    if (!settings) return;
    const previous = settings.themeColor || defaultThemeColor;
    void window.recordApi.saveSettings({ ...settings, themeColor: draftColor }).then(() => {
      setColorOpen(false);
    }).catch(() => {
      setColorScheme(previous);
      setColorOpen(false);
      snackbar({ message: '保存主题颜色失败' });
    });
  };
  const cancelColor = (): void => {
    setColorScheme(settings?.themeColor || defaultThemeColor);
    setColorOpen(false);
  };

  return (
    <div className="page-body">
      <h2 className="page-title">设置</h2>
      <h3 className="section-title">采集设备</h3>
      <div className="form-grid">
        <div className="form-field">
          <mdui-select label="摄像头 / 采集卡" value={videoDevice?.id || ''} ref={deviceRef} name="videoDevice">
            <mdui-menu-item value="">未选择</mdui-menu-item>
            {session.devices.filter((item) => item.kind === 'video').map((device) => <mdui-menu-item key={device.id} value={device.id}>{deviceLabel(device)}</mdui-menu-item>)}
          </mdui-select>
          <span className="form-hint">选择采集卡</span>
        </div>
        <div className="form-field">
          <mdui-select label="采集画面格式" value={captureFormat} ref={formatRef} name="captureFormat">
            {modeFormats(modes, captureFormat).map((item) => <mdui-menu-item key={item} value={item}>{formatLabel(item)}</mdui-menu-item>)}
          </mdui-select>
        </div>
        <div className="form-field">
          <div className="select-icon-row">
            <mdui-select label="音频录制设备" value={audioDevice?.id || ''} ref={deviceRef} name="audioDevice">
              <mdui-menu-item value="">不录制音频</mdui-menu-item>
              {session.devices.filter((item) => item.kind === 'audio').map((device) => <mdui-menu-item key={device.id} value={device.id}>{deviceLabel(device)}</mdui-menu-item>)}
            </mdui-select>
            <mdui-button-icon disabled={loading} ref={reloadRef}>
              <mdui-icon dangerouslySetInnerHTML={{ __html: iconSvg('refresh') }} />
            </mdui-button-icon>
          </div>
          {loading ? <mdui-linear-progress indeterminate className="device-loading" /> : null}
          <span className="form-hint">选择音频输入</span>
        </div>
        <div className="form-switch form-field-wide">
          <span>电脑声音录制<em className="form-note">开启后，将同时捕获电脑输出声音并录制。</em></span>
          <mdui-switch checked={Boolean(settings?.desktopAudio)} ref={switchRef} name="desktopAudio" />
        </div>
        <div className="form-switch form-field-wide">
          <span>麦克风声音录制<em className="form-note">开启后，将同时捕获麦克风输出声音并录制。</em></span>
          <mdui-switch checked={Boolean(settings?.micAudio)} ref={switchRef} name="micAudio" />
        </div>
        {settings?.micAudio ? (
          <div className="form-field">
            <mdui-select label="麦克风设备" value={micDevice?.id || ''} ref={deviceRef} name="micDevice">
              <mdui-menu-item value="">未选择</mdui-menu-item>
              {session.devices.filter((item) => item.kind === 'audio').map((device) => <mdui-menu-item key={device.id} value={device.id}>{deviceLabel(device)}</mdui-menu-item>)}
            </mdui-select>
            <span className="form-hint">选择麦克风输入</span>
          </div>
        ) : null}
      </div>
      <h3 className="section-title">画质与编码</h3>
      <div className="form-grid">
        <div className="form-field">
          <mdui-select label="录制分辨率" value={settings ? resolutionKey(settings.width, settings.height) : ''} ref={sizeRef} name="width">
            {resolutions.map((item) => <mdui-menu-item key={resolutionKey(item.width, item.height)} value={resolutionKey(item.width, item.height)}>{resolutionText(item.width, item.height)}</mdui-menu-item>)}
          </mdui-select>
          {sizeMissed ? <span className="form-hint">采集卡未接受该分辨率，当前输出 {resolutionText(session.width, session.height)}</span> : null}
        </div>
        <div className="form-field">
          <mdui-select label="录制帧率" value={String(settings?.fps ?? defaultSettings.fps)} ref={fpsRef} name="fps">
            {sizes.map((item) => <mdui-menu-item key={String(item)} value={String(item)}>{item} fps</mdui-menu-item>)}
          </mdui-select>
          {fpsMissed ? <span className="form-hint">采集卡未接受设置页的帧率，当前输出 {Number(session.fps.toFixed(2))} fps</span> : null}
          {settings ? <EncodeHint width={settings.width} height={settings.height} fps={settings.fps} /> : null}
        </div>
        <div className="form-switch form-field-wide">
          <span>垂直翻转画面<em className="form-note">画面上下颠倒时开启</em></span>
          <mdui-switch checked={Boolean(settings?.flipVertical)} ref={switchRef} name="flipVertical" />
        </div>
        <div className="form-field">
          <mdui-select label="编码器" value={settings?.encoder || 'auto'} ref={encoderRef} name="encoder">
            {encoderOptions.map((item) => <mdui-menu-item key={item.value} value={item.value}>{item.label}</mdui-menu-item>)}
          </mdui-select>
          {encoderHints[settings?.encoder || 'auto'] ? <span className="form-hint">{encoderHints[settings?.encoder || 'auto']}</span> : null}
        </div>
        <div className="form-field">
          <mdui-select label="录制质量" value={String(settings?.quality ?? defaultSettings.quality)} ref={qualityRef} name="quality">
            {qualityTiers.map((tier) => <mdui-menu-item key={String(tier)} value={String(tier)}>{qualityLabels[tier]}</mdui-menu-item>)}
          </mdui-select>
          <span className="form-hint">CQP 数值越低画质越高，录制文件体积随画面复杂度变化。</span>
        </div>
      </div>
      <h3 className="section-title">存储与运行</h3>
      <div className="form-grid">
        <div className="form-field form-field-wide">
          <div className="select-icon-row">
            <mdui-text-field label="视频保存目录" value={settings?.saveDir || ''} readonly placeholder="默认保存到 ~/.splatoon3record/videos" />
            <mdui-button-icon ref={pickRef}>
              <mdui-icon dangerouslySetInnerHTML={{ __html: iconSvg('folder') }} />
            </mdui-button-icon>
          </div>
          <span className="form-hint">裁剪完成的对局录像保存到该目录。</span>
        </div>
      </div>
      <div className="form-grid">
        <div className="form-switch">
          <span>自动推送录像<em className="form-note">对局裁剪完成后由 QQBot 私聊推送</em></span>
          <mdui-switch checked={Boolean(settings?.autoPush)} ref={switchRef} name="autoPush" />
        </div>
        <div className="form-switch">
          <span>启动时自动录制<em className="form-note">应用打开后立即开始缓存采集卡画面</em></span>
          <mdui-switch checked={Boolean(settings?.autoRecord)} ref={switchRef} name="autoRecord" />
        </div>
        <div className="form-switch">
          <span>开机自启动<em className="form-note">开机后自动运行 Splatoon3 Record</em></span>
          <mdui-switch checked={Boolean(settings?.autoLaunch)} ref={switchRef} name="autoLaunch" />
        </div>
      </div>
      <h3 className="section-title">外观</h3>
      <div className="form-grid">
        <div className="form-field form-field-wide">
          <span className="form-label">背景图片</span>
          <span className="form-hint">{settings?.backgroundPath ? '正在使用自定义背景，吉祥物已自动隐藏。' : '正在使用默认背景和吉祥物。'}</span>
          <div className="appearance-actions">
            <mdui-button full-width variant="filled" onClick={pickBackground}>更换背景</mdui-button>
            <mdui-button full-width variant="outlined" disabled={!settings?.backgroundPath} onClick={resetBackground}>恢复默认背景</mdui-button>
          </div>
          <div className="slider-header background-dim-header">
            <span className="form-label">背景压黑</span>
            <span className="slider-value">{settings?.backgroundDim ?? defaultSettings.backgroundDim}%</span>
          </div>
          <mdui-slider ref={dimRef} name="backgroundDim" min={0} max={100} step={5} value={settings?.backgroundDim ?? defaultSettings.backgroundDim} disabled={!settings?.backgroundPath} />
          <span className="form-hint">数值越高背景越暗，能避免背景图案影响文字阅读。</span>
        </div>
        <div className="form-field form-field-wide">
          <span className="form-label">MDUI 主题色</span>
          <div className="color-actions">
            <span className="color-swatch" style={{ background: settings?.themeColor || defaultThemeColor }} />
            <span className="form-hint">{settings?.themeColor || defaultThemeColor}</span>
          </div>
          <div className="appearance-actions">
            <mdui-button full-width variant="outlined" onClick={openPalette}>打开色板</mdui-button>
          </div>
        </div>
      </div>
      <mdui-dialog ref={colorCloseRef} open={colorOpen} headline="选择主题颜色">
        <div className="color-palette">
          {themeColors.map((color) => (
            <button key={color} type="button" aria-label={color} className={draftColor === color ? 'color-dot is-active' : 'color-dot'} style={{ background: color }} onClick={() => setDraftColor(color)} />
          ))}
        </div>
        <div className="color-custom">
          <input type="color" value={draftColor} onChange={(event) => setDraftColor(event.target.value)} />
          <span className="form-hint">{draftColor}</span>
        </div>
        <mdui-button slot="action" variant="text" onClick={cancelColor}>取消</mdui-button>
        <mdui-button slot="action" variant="filled" onClick={applyColor}>确定</mdui-button>
      </mdui-dialog>
      {restartOpen ? (
        <mdui-dialog open headline="需要重启应用" description={restartHint}>
          <mdui-button slot="action" variant="text" onClick={() => setRestartOpen(false)}>稍后重启</mdui-button>
          <mdui-button slot="action" variant="filled" onClick={() => void window.recordApi.relaunchApp()}>立即重启</mdui-button>
        </mdui-dialog>
      ) : null}
    </div>
  );
}

export { settingsPage as SettingsPage };

function nameOf(event: Event): string {
  const current = event.currentTarget as HTMLElement | undefined;
  const target = event.target as HTMLElement | undefined;
  return current?.getAttribute('name') || target?.getAttribute('name') || target?.closest?.('mdui-select')?.getAttribute('name') || target?.closest?.('mdui-slider')?.getAttribute('name') || '';
}

function errorText(error: unknown, fallback: string): string {
  const text = (error instanceof Error ? error.message : String(error ?? '')).replace(/^Error invoking remote method '[^']*':\s*(Error:\s*)?/, '').trim();
  return text || fallback;
}


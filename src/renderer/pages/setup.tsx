import { useEffect, useRef, useState, type ReactElement } from 'react';
import QRCode from 'qrcode';
import appLogo from '../assets/appIcon.png';
import { useElementEvent, markSelectClick, restoreSelect, targetChecked, targetValue } from '../lib/event.js';
import { listDevices } from '../lib/device.js';
import { deviceLabel, fpsList, matchDevice, resolutionKey, resolutionList, resolutionText } from '../../shared/capture.js';
import { appName, defaultSettings } from '../../shared/constants.js';
import { NsoApiNotice } from '../components/notice.js';
import characterImg from '../assets/character/character.png';
import { iconSvg } from '../lib/icons.js';
import type { AppStatus, CaptureDevice, RecordSettings } from '../../shared/types.js';

const stepTitles = ['选择采集卡设备', '绑定 Nintendo 账号', '绑定 QQBot'];

const stateNames: Record<string, string> = {
  unbound: '未绑定',
  connecting: '登录中',
  connected: '已连接',
  expired: '已过期，需要重新登录',
  error: '连接异常',
};

function setupApp(): ReactElement {
  const [status, setStatus] = useState<AppStatus>();
  const [devices, setDevices] = useState<CaptureDevice[]>([]);
  const [step, setStep] = useState(0);
  const [draft, setDraft] = useState<RecordSettings>();
  const [qrImage, setQrImage] = useState('');
  const [loadingDevices, setLoadingDevices] = useState(false);
  const [finishError, setFinishError] = useState('');
  const pickedDevice = useRef(false);
  const value = draft ?? status?.settings;
  const qqReady = status?.qqState === 'connected' && Boolean(status.qqOwner);

  useEffect(() => {
    const markDevicePick = (event: Event): void => {
      if ((event.target as HTMLElement | undefined)?.closest?.('mdui-select[name="videoDevice"]')) pickedDevice.current = true;
    };
    document.addEventListener('click', markSelectClick, true);
    document.addEventListener('click', markDevicePick, true);
    return () => {
      document.removeEventListener('click', markSelectClick, true);
      document.removeEventListener('click', markDevicePick, true);
    };
  }, []);
  useEffect(() => {
    void window.recordApi.getStatus().then(setStatus);
    return window.recordApi.getEvents(setStatus);
  }, []);
  useEffect(() => {
    setLoadingDevices(true);
    void listDevices(value?.videoDevice).then(setDevices).catch(() => setDevices([])).finally(() => setLoadingDevices(false));
  }, [value?.videoDevice]);
  useEffect(() => {
    const url = status?.qrCode || '';
    if (!url) {
      setQrImage('');
      return;
    }
    QRCode.toDataURL(url, { width: 440, margin: 1 }).then(setQrImage).catch(() => setQrImage(''));
  }, [status?.qrCode]);

  const videoDevices = devices.filter((item) => item.kind === 'video');
  const audioDevices = devices.filter((item) => item.kind === 'audio');
  const videoDevice = matchDevice(videoDevices, 'video', value?.videoDevice);
  const audioDevice = matchDevice(audioDevices, 'audio', value?.audioDevice);
  const resolutions = resolutionList(videoDevice, value ? { width: value.width, height: value.height } : undefined);
  const sizes = fpsList(videoDevice, value?.fps);

  const patch = (part: Partial<RecordSettings>): void => {
    if (value) setDraft({ ...value, ...part });
  };
  useEffect(() => {
    if (pickedDevice.current || !value || !videoDevices.length) return;
    if (matchDevice(videoDevices, 'video', value.videoDevice)) return;
    patch({ videoDevice: videoDevices[0].id, width: defaultSettings.width, height: defaultSettings.height, fps: defaultSettings.fps });
  }, [devices, value]);
  const switchRef = useElementEvent<HTMLElement>('change', (event) => {
    const name = nameOf(event);
    const checked = targetChecked(event);
    if (!value || Boolean((value as unknown as Record<string, unknown>)[name]) === checked) return;
    patch({ [name]: checked } as Partial<RecordSettings>);
  });
  const deviceRef = useElementEvent<HTMLElement>('change', (event) => {
    const data = targetValue(event);
    const name = nameOf(event);
    if (!value || String((value as unknown as Record<string, unknown>)[name] ?? '') === data) return;
    if (data === '' && name === 'videoDevice' && restoreSelect(event)) return;
    if (name === 'videoDevice') {
      patch({ videoDevice: data, width: defaultSettings.width, height: defaultSettings.height, fps: defaultSettings.fps });
      return;
    }
    patch({ [name]: data } as Partial<RecordSettings>);
  });
  const sizeRef = useElementEvent<HTMLElement>('change', (event) => {
    const data = targetValue(event);
    if (data === '' && value && restoreSelect(event, resolutionKey(value.width, value.height))) return;
    const size = data.match(/^(\d+)x(\d+)$/);
    if (!size) return;
    patch({ width: Number(size[1]), height: Number(size[2]) });
  });
  const fpsRef = useElementEvent<HTMLElement>('change', (event) => {
    const fps = Number(targetValue(event));
    if (!Number.isFinite(fps) || value?.fps === fps) return;
    patch({ fps });
  });
  const pickRef = useElementEvent<HTMLElement>('click', () => {
    void window.recordApi.pickFolder().then((folder) => {
      if (folder) patch({ saveDir: folder });
    });
  });
  const saveDraft = async (): Promise<void> => {
    if (!value) return;
    const saved = await window.recordApi.saveSettings(value);
    setStatus(saved);
  };
  const refresh = (): void => {
    setLoadingDevices(true);
    void listDevices(value?.videoDevice).then(setDevices).catch(() => setDevices([])).finally(() => setLoadingDevices(false));
  };
  const reloadRef = useElementEvent<HTMLElement>('click', refresh);
  const goNext = async (): Promise<void> => {
    await saveDraft().catch(() => undefined);
    setStep(Math.min(step + 1, 2));
  };
  const goBack = (): void => setStep(Math.max(step - 1, 0));
  const finishSetup = async (): Promise<void> => {
    if (!qqReady) return;
    setFinishError('');
    try {
      const result = await window.recordApi.finishSetup();
      if (!result.success) setFinishError(result.error);
    } catch {
      setFinishError('完成初始设置失败，请稍后重试。');
    }
  };
  useEffect(() => {
    if (status?.nsoState === 'connected' && step === 1) {
      const timer = setTimeout(() => {
        if (status?.nsoState === 'connected') goNext();
      }, 500);
      return () => clearTimeout(timer);
    }
    return undefined;
  }, [status?.nsoState, step]);

  return (
    <div className="setup-body">
      <div className="bg-layer" />
      <div className="setup-head">
        <img className="setup-logo" src={appLogo} alt="" />
        <div>
          <div className="about-name">{appName}</div>
          <div className="about-sub">初始设置 · 步骤 {step + 1} / 3：{stepTitles[step]}</div>
        </div>
      </div>
      <mdui-linear-progress max={3} value={step + 1} />
      <div className="setup-step">
        {step === 0 ? (
          <div>
            <h3 className="section-title">选择采集卡设备</h3>
            <div className="form-grid">
              <div className="form-field">
                <mdui-select label="摄像头 / 采集卡" value={videoDevice?.id || ''} ref={deviceRef} name="videoDevice">
                  <mdui-menu-item value="">未选择</mdui-menu-item>
                  {videoDevices.map((device) => <mdui-menu-item key={device.id} value={device.id}>{deviceLabel(device)}</mdui-menu-item>)}
                </mdui-select>
              </div>
              <div className="form-field">
                <div className="select-icon-row">
                  <mdui-select label="音频录制设备" value={audioDevice?.id || ''} ref={deviceRef} name="audioDevice">
                    <mdui-menu-item value="">不录制音频</mdui-menu-item>
                    {audioDevices.map((device) => <mdui-menu-item key={device.id} value={device.id}>{deviceLabel(device)}</mdui-menu-item>)}
                  </mdui-select>
                  <mdui-button-icon disabled={loadingDevices} ref={reloadRef}>
                    <mdui-icon dangerouslySetInnerHTML={{ __html: iconSvg('refresh') }} />
                  </mdui-button-icon>
                </div>
                {loadingDevices ? <mdui-linear-progress indeterminate className="device-loading" /> : null}
              </div>
              <div className="form-field">
                <mdui-select label="录制分辨率" value={value ? resolutionKey(value.width, value.height) : ''} ref={sizeRef} name="width">
                  {resolutions.map((item) => <mdui-menu-item key={resolutionKey(item.width, item.height)} value={resolutionKey(item.width, item.height)}>{resolutionText(item.width, item.height)}</mdui-menu-item>)}
                </mdui-select>
              </div>
              <div className="form-field">
                <mdui-select label="录制帧率" value={String(value?.fps ?? defaultSettings.fps)} ref={fpsRef} name="fps">
                  {sizes.map((item) => <mdui-menu-item key={String(item)} value={String(item)}>{item} fps</mdui-menu-item>)}
                </mdui-select>
              </div>
              <div className="form-field form-field-wide">
                <div className="form-switch">
                  <span>垂直翻转画面</span>
                  <mdui-switch checked={Boolean(value?.flipVertical)} ref={switchRef} name="flipVertical" />
                </div>
              </div>
              <div className="form-field form-field-wide">
                <div className="select-icon-row">
                  <mdui-text-field label="视频保存目录" value={value?.saveDir || ''} readonly placeholder="默认保存到 ~/.splatoon3record/videos" />
                  <mdui-button-icon ref={pickRef}>
                    <mdui-icon dangerouslySetInnerHTML={{ __html: iconSvg('folder') }} />
                  </mdui-button-icon>
                </div>
              </div>
            </div>
            {videoDevices.length ? (
              <div className="bind-info">已检测到 {videoDevices.length} 个视频设备，分辨率与帧率按期望值请求采集卡协商。</div>
            ) : (
              <div className="bind-info">未检测到视频设备，请确认采集卡已连接后点击刷新按钮重试，或先跳过此步骤。</div>
            )}
            <div className="setup-actions">
              <mdui-button variant="filled" onClick={goNext}>下一步</mdui-button>
            </div>
          </div>
        ) : null}
        {step === 1 ? (
          <div>
            <h3 className="section-title">绑定 Nintendo 账号</h3>
            <NsoApiNotice />
            <div className="bind-info">点击下方按钮登录 Nintendo 账号并授权鱿鱼圈 3 数据读取，登录成功后应用才能检测对局结果。</div>
            <div className="setup-actions">
              <mdui-button variant="filled" onClick={() => void window.recordApi.openNsoLogin()}>登录 Nintendo 账号</mdui-button>
              <mdui-button variant="tonal" onClick={() => void window.recordApi.clearNsoLogin()}>清空账户凭证数据后登录</mdui-button>
            </div>
            <div className="status-grid">
              <StateRow label="当前状态" state={status?.nsoState} />
            </div>
            {status?.nsoState === 'error' && status?.nsoError ? <div className="bind-info">{status.nsoError}</div> : null}
            {status?.nsoState === 'connecting' ? (
              <div className="bind-info">
                <mdui-linear-progress indeterminate className="connect-loading" />
                已获取授权，正在登录并获取凭证，请稍候…
              </div>
            ) : null}
            {status?.nsoState !== 'connected' && status?.nsoState !== 'connecting' ? <div className="bind-info">完成 Nintendo 账号登录授权后才能进入下一步。</div> : null}
            <div className="setup-actions">
              <mdui-button variant="text" onClick={goBack}>上一步</mdui-button>
              <mdui-button variant="filled" disabled={status?.nsoState !== 'connected'} onClick={goNext}>下一步</mdui-button>
            </div>
          </div>
        ) : null}
        {step === 2 ? (
          <div>
            <h3 className="section-title">绑定 QQBot</h3>
            <div className="bind-info">绑定后可将对局录像推送到你的 QQ。点击按钮获取二维码，并使用创建机器人的 QQ 扫码授权。</div>
            <div className="setup-actions">
              <mdui-button variant="filled" onClick={() => void window.recordApi.startQqLogin()}>获取绑定机器人二维码</mdui-button>
            </div>
            {qrImage ? (
              <div className="qr-box">
                <img className="qr-image" src={qrImage} alt="QQBot 绑定二维码" />
              </div>
            ) : null}
            <div className="status-grid">
              <StateRow label="当前状态" state={status?.qqState} />
              <div className="status-row">
                <span className="status-label">推送用户</span>
                <span className="status-value">{status?.qqOwner ? '已绑定' : '未绑定'}</span>
              </div>
            </div>
            {status?.qqState === 'connected' && !status.qqOwner ? <div className="bind-info">请在 QQBot 私聊中发送 /bind 绑定用户后再完成初始设置。</div> : null}
            {finishError ? <div className="bind-info" role="alert">{finishError}</div> : null}
            <div className="setup-actions">
              <mdui-button variant="text" onClick={goBack}>上一步</mdui-button>
              <mdui-button variant="filled" disabled={!qqReady} onClick={() => void finishSetup()}>完成并进入应用</mdui-button>
            </div>
          </div>
        ) : null}
      </div>
      <img className="mascot" src={characterImg} alt="" />
    </div>
  );
}

export { setupApp as SetupApp };

function stateRow(props: { label: string; state?: string }): ReactElement {
  return (
    <div className="status-row">
      <span className="status-label">{props.label}</span>
      <span className="status-value">{stateNames[props.state || 'unbound'] || '未绑定'}</span>
    </div>
  );
}

const StateRow = stateRow;

function nameOf(event: Event): string {
  const current = event.currentTarget as HTMLElement | undefined;
  const target = event.target as HTMLElement | undefined;
  return current?.getAttribute('name') || target?.getAttribute('name') || target?.closest?.('mdui-select')?.getAttribute('name') || '';
}

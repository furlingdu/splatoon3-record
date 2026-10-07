import { snackbar } from 'mdui/functions/snackbar.js';
import type { ReactElement } from 'react';
import { appName, authorName, avatarUrl, projectUrl, projectVersion, projectName } from '../../shared/constants.js';
import type { AppStatus, CaptureDevice, RuntimeInfo } from '../../shared/types.js';
import { listDevices } from '../lib/device.js';
import { liveView } from '../lib/live.js';
import { matchDevice } from '../../shared/capture.js';
import { iconSvg } from '../lib/icons.js';
import appLogo from '../assets/appIcon.png';
import abxyLogo from '../assets/abxy.png';

const projectRepo = projectUrl.replace('https://github.com/', '');
const nsoRepo = 'Cypas/splatoon3-nso';
const nxapiRepo = 'samuelthomas2774/nxapi';

function aboutPage(props: { status?: AppStatus }): ReactElement {
  const copyInfo = async (): Promise<void> => {
    try {
      const [runtime, devices] = await Promise.all([window.recordApi.getRuntimeInfo(), listDevices(props.status?.settings.videoDevice)]);
      const text = diagnosticText(props.status, runtime, devices);
      await window.recordApi.copyText(text);
      snackbar({ message: '设备信息已复制，请通过项目主页反馈。' });
    } catch {
      snackbar({ message: '设备信息复制失败，请稍后重试。' });
    }
  };
  return (
    <div className="page-body">
      <h2 className="page-title">关于</h2>

      <div className="about-card">
        <div className="about-block">
          <img className="about-logo" src={appLogo} />
          <div>
            <div className="about-name">{appName}</div>
            <div className="about-sub">{projectName} Ver.{projectVersion}</div>
          </div>
        </div>
        <p className="about-intro">
          一款斯普拉遁3录制机，通过采集卡自动采集整局录像，并通过 QQBot 推送。
        </p>
        <div className="status-actions">
          <mdui-button variant="filled" onClick={() => void copyInfo()}>复制设备信息</mdui-button>
        </div>
      </div>

      <div className="about-card">
        <div className="about-block">
          <img className="about-avatar" src={avatarUrl} alt={authorName} />
          <div>
            <div className="about-name">{authorName}</div>
            <div className="about-sub">作者</div>
          </div>
        </div>
        <p className="about-intro">斯普拉遁3录制机作者，梦想是把巨齿刮水刀打到十星！</p>
        <p className="about-intro">喜欢我的话，欢迎关注项目主页。</p>
        <div className="status-actions">
          <mdui-button variant="tonal" onClick={() => void window.recordApi.openLink(projectUrl)}>
            <mdui-icon slot="icon" dangerouslySetInnerHTML={{ __html: iconSvg('link') }} />
            项目主页
          </mdui-button>
        </div>
      </div>

      <div className="about-card">
        <div className="about-block">
          <img className="about-avatar" src={abxyLogo} />
          <div>
            <div className="about-name">ABXY</div>
            <div className="about-sub">乐队</div>
          </div>
        </div>
        <p className="about-intro">
          这是一支由四名成员组成的乐队，他们以朗朗上口的电子音乐和主唱脉子的歌声在音乐排行榜上掀起热潮。在演唱会上，他们让复古游戏机与音乐联动，并通过自身发光进行表演，这使得他们收获了很高的人气。收录的歌声使用了大量的后期修音，所以现场表演经常是对口型假唱。
        </p>
        <p className="about-intro">作者是ABXY小粉丝~~</p>
      </div>

      <div className="about-card">
        <div className="about-name">项目致谢</div>
        <p className="about-intro">
          本项目的 NSO 登录与 SplatNet 3 数据接入参考了开源项目 {nsoRepo} 的实现，在此致谢。
        </p>
        <p className="about-intro">
          NSO 登录 Token 加密依赖 {nxapiRepo} 所公开的 nxapi-znca-api 接口。请注意，当涉及到NSO登录时，你的id_token会被发送到nxapi-znca-api服务以获取必要的校验参数。id_token仅包含账号标识与有效期，不含密码，仅用于完成登录。
        </p>
        <div className="status-actions">
          <mdui-button variant="tonal" onClick={() => void window.recordApi.openLink(projectUrl)}>
            <mdui-icon slot="icon" dangerouslySetInnerHTML={{ __html: iconSvg('link') }} />
            GitHub：{projectRepo}
          </mdui-button>
          <mdui-button variant="tonal" onClick={() => void window.recordApi.openLink(`https://github.com/${nsoRepo}`)}>
            <mdui-icon slot="icon" dangerouslySetInnerHTML={{ __html: iconSvg('link') }} />
            GitHub：{nsoRepo}
          </mdui-button>
          <mdui-button variant="tonal" onClick={() => void window.recordApi.openLink(`https://github.com/${nxapiRepo}`)}>
            <mdui-icon slot="icon" dangerouslySetInnerHTML={{ __html: iconSvg('link') }} />
            GitHub：{nxapiRepo}
          </mdui-button>
        </div>
      </div>

      <div className="about-card">
        <div className="about-name">为什么登录需要经过 nxapi-znca-api?</div>
        <p className="about-intro">
          Nintendo 在登录服务的登录请求中要求携带一个由官方 NSO App 内置算法生成的校验参数，该算法无法在第三方应用中复现，因此登录时需要把 Nintendo 签发的 id_token 提交给公开的 nxapi-znca-api 服务换取这个参数。id_token 只包含账号标识与有效期，不含密码，仅用于完成登录。
        </p>
      </div>
    </div>
  );
}

function diagnosticText(status: AppStatus | undefined, runtime: RuntimeInfo, devices: CaptureDevice[]): string {
  const video = devices.filter((item) => item.kind === 'video').map((item) => item.name).join('、') || '未检测到';
  const audio = devices.filter((item) => item.kind === 'audio').map((item) => item.name).join('、') || '未检测到';
  const selected = matchDevice(devices, 'video', status?.settings.videoDevice);
  const selectedAudio = matchDevice(devices, 'audio', status?.settings.audioDevice);
  const gpuStatus = Object.entries(runtime.gpuStatus).map(([key, value]) => `${key}=${value}`).join(', ') || '无';
  const live = liveView();
  return [
    'Splatoon3 Record 设备反馈信息',
    `应用版本：${runtime.appVersion}`,
    `Electron：${runtime.electronVersion}`,
    `Chromium：${runtime.chromeVersion}`,
    `Node：${runtime.nodeVersion}`,
    `系统：${runtime.platform} ${runtime.arch} ${runtime.osRelease}`,
    `GPU：${runtime.gpu.join('、') || '未获取'}`,
    `硬件加速：${runtime.hardwareAcceleration ? '已启用' : '未启用'}`,
    `GPU 功能：${gpuStatus}`,
    `显示器：${runtime.displays.join('、') || '未获取'}`,
    `采集卡：${video}`,
    `已选采集卡：${selected?.name || '未选择'}`,
    `采集卡能力上限：${selected?.maxWidth || '未知'}x${selected?.maxHeight || '未知'} @ ${selected?.maxFps || '未知'} fps`,
    `采集卡原生规格：${selected?.nativeWidth || '未知'}x${selected?.nativeHeight || '未知'} @ ${selected?.nativeFps || '未知'} fps`,
    `音频设备：${audio}`,
    `已选音频设备：${selectedAudio?.name || '未选择'}`,
    `实际画幅：${status?.streamWidth || 0}x${status?.streamHeight || 0}`,
    `实际帧率：${status?.streamFps || 0} fps`,
    `采集格式：${status?.streamFormat || '未知'}`,
    `采集音频：${status?.streamAudio ? '有' : '无'}`,
    `硬件解码档位：${status?.hwAccel || '未启用或未知'}`,
    `归档编码器：${status?.encoder || '未知'}`,
    `直播编码器：${live.codec || '未开播'}`,
    `推理设备：${live.device || '未启动'}`,
    `直播状态：${status?.liveState || '未知'}`,
    `直播地址端口：${status?.liveOptions.port || '未知'}`,
    `推理状态：${status?.settings.blurNickname ? '已开启' : '未开启'}`,
  ].join('\n');
}

export { aboutPage as AboutPage };

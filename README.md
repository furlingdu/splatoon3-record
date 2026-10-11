# Splatoon3 Record

[![CI](https://github.com/furlingdu/splatoon3-record/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/furlingdu/splatoon3-record/actions/workflows/ci.yml)
[![License: AGPL-3.0-only](https://img.shields.io/badge/license-AGPL--3.0--only-blue.svg)](LICENSE)

Splatoon3 Record 是一款面向 Splatoon 3 的本地录制、直播与对局归档工具。程序通过采集卡持续获取画面，依据 Nintendo Switch Online 返回的真实对局结束时间和持续时间裁剪整局录像并归档到本地，和 QQBot 压制后推送。

[介绍视频](https://www.bilibili.com/video/BV1vfar6dEg6/)

[QQ 交流群](https://qun.qq.com/universal-share/share?ac=1&authKey=wP%2BIo%2Fag%2FtzGZgvS9OA0s1ue0Vba8ViQ%2BxHWB9ZVh8S9Fop%2Foykdj4%2FaZYgQRojO&busi_data=eyJncm91cENvZGUiOiIxMTA5MDk5NzE2IiwidG9rZW4iOiJQd29BYnVXRmF6MkFMNE1SSFNCbGNrY3RBYk1rY2ZsT1M0VTZiS0I3RHdQWk1wVXdYWlh0ckFIby96RGljaXRmIiwidWluIjoiMzY0ODE5MjMxMSJ9&data=CfvQydD4zMNoeY472UFhNDBtWtMRsgkpiv30vsGcO3ph9ICf5Dh0Qk5-gaId-E1wFnEi_Gf_WdZM-tvdzQZPpA&svctype=4&tempid=h5_group_info)

## 功能

- 通过采集卡录制画面与声音，自动捕获Splatoon3画面
- 按对局自动裁剪录像
- 提供本机 HTTP 直播页，可直接作为 OBS 浏览器源使用
- 直播链路支持昵称检测和打码模糊
- 通过 QQBot 完成绑定、录制控制、状态查询、最近对局和视频推送

## 运行要求

- Node.js 24 或更高版本
- 可用的采集卡或摄像头，以及音频采集设备
- Nintendo Switch Online 登录需要访问 Nintendo 服务及项目配置的 NSO 接口
- QQBot 推送需要在本机完成机器人绑定

## 采集后端

Windows 上默认使用 DirectShow 采集后端。部分采集卡只在 NV12 或 YUY2 模式下输出 2K 以上分辨率，Chromium 的 DirectShow 后端不支持 NV12，可在设置页打开「开启NV12、YUY2采集支持」改走 Media Foundation 后端，重启应用后生效，重启后分辨率与帧率选项会按新后端重新检测。Media Foundation 后端原生支持 NV12 与 YUY2，并在内部统一转换为 I420 后交给录制与直播链路。

`.env` 按当前工作目录、可执行文件同目录、数据目录的顺序取第一个存在的文件，可参考仓库根目录的 `.env.example`。

## 开发

```bash
npm install
npm run typecheck
npm run lint
npm run test:unit
npm run test:integration
npm run build
```

### 测试

```bash
npm run test:ui
npm run test:capture
npm run dist:win
npm run test:packaged
```

构建安装包时使用：

```bash
npm run dist:win
npm run dist:mac
npm run dist:linux
```

## 登录与 znca-api

为获取到您的Nintendo Switch Online数据，程序将要求登录您的Nintendo账户。由于Nintendo限制，在登录过程中会涉及到使用第三方Nintendo Switch Online Api以实现加密包体获取，你的 Nintendo 账号 id_token 将被发送到第三方 API（[nxapi-znca-api](https://github.com/samuelthomas2774/nxapi-znca-api)）用于完成令牌校验。

请注意，由于涉及到了第三方Api进行操作，该操作可能存在部分风险或稳定性较差，开发者不对账户安全性进行保证。但请放心，id_token并不会泄露您的账户。您的Nintendo Switch Online账户数据将会被加密保存至本地。

本项目的 NSO 登录与 SplatNet 3 数据接入参考了开源项目 [Cypas/splatoon3-nso](https://github.com/Cypas/splatoon3-nso) 的实现，在此致谢。

## 反馈

设备相关的故障请在关于页点击「复制设备信息」，连同问题描述一起提交 issue。

本项目自有代码采用 AGPL-3.0-only；第三方组件、字体、图片、模型和 FFmpeg 仍受各自许可约束。

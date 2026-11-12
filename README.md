# Splatoon3 Record

[![Mobile](https://github.com/furlingdu/splatoon3-record/actions/workflows/mobile.yml/badge.svg?branch=main)](https://github.com/furlingdu/splatoon3-record/actions/workflows/mobile.yml)
[![License: AGPL-3.0-only](https://img.shields.io/badge/license-AGPL--3.0--only-blue.svg)](LICENSE)

Splatoon3 Record 是一款面向 Splatoon 3 的本地录制、直播与对局归档工具。程序通过采集卡持续获取画面，依据 Nintendo Switch Online 返回的真实对局结束时间和持续时间裁剪整局录像并归档到本地，和 QQBot 压制后推送。

[介绍视频](https://www.bilibili.com/video/BV1vfar6dEg6/)

[QQ 交流群](https://qun.qq.com/universal-share/share?ac=1&authKey=wP%2BIo%2Fag%2FtzGZgvS9OA0s1ue0Vba8ViQ%2BxHWB9ZVh8S9Fop%2Foykdj4%2FaZYgQRojO&busi_data=eyJncm91cENvZGUiOiIxMTA5MDk5NzE2IiwidG9rZW4iOiJQd29BYnVXRmF6MkFMNE1SSFNCbGNrY3RBYk1rY2ZsT1M0VTZiS0I3RHdQWk1wVXdYWlh0ckFIby96RGljaXRmIiwidWluIjoiMzY0ODE5MjMxMSJ9&data=CfvQydD4zMNoeY472UFhNDBtWtMRsgkpiv30vsGcO3ph9ICf5Dh0Qk5-gaId-E1wFnEi_Gf_WdZM-tvdzQZPpA&svctype=4&tempid=h5_group_info)

## 功能

- 通过采集卡录制画面与声音，自动捕获 Splatoon3 画面
- 按对局自动裁剪录像并归档
- 提供 RTMP 直播推流与 RTMP 输入，可配合 OBS 等推流软件使用
- 直播链路支持昵称检测和打码模糊
- 通过 QQBot 完成绑定、录制控制、状态查询、最近对局和视频推送

## 性能与延迟

- 预览始终按采集设备的原始分辨率、原始帧率直通显示，不做缩放和后处理；窗口不可见时降为 5fps 心跳，重新可见后立即恢复原始帧率。
- 录制时间戳直接使用采集设备提供的帧时间戳，不再把线程到达时间当作播放时间戳，避免音画漂移。
- 画面识别通过 DirectML 在 GPU 上推理（同一模型 CPU 为 116ms、GPU 为 10ms 量级），只有 DirectML 不可用时才回退 CPU，实际后端会写入日志。
- 归档编码顺序为硬件 HEVC → 硬件 H.264 → CPU（libx265）。

## 运行要求

- Windows 10/11、macOS、Linux，或 Android / iOS 移动设备
- 可用的采集卡或摄像头，以及音频采集设备
- Nintendo Switch Online 登录需要访问 Nintendo 服务及项目配置的 NSO / znca 接口
- QQBot 推送需要在本机完成机器人绑定

## 更新

「更新」页面会自动检查 GitHub Release 并按当前系统与架构挑选安装包，下载过程中显示进度，下载完成后由用户确认再启动安装程序。页面提供两个开关：「网络加速」开启后通过 `.env` 中 `UPDATE_PROXY_PREFIX` 配置的加速源前缀获取更新包（默认 `https://gh-proxy.com/`），失败时回退直连；「自动检查更新」开启后启动应用时会在后台检查并在发现新版本时提示。

`.env` 按当前工作目录、可执行文件同目录、数据目录的顺序取第一个存在的文件，可参考仓库根目录的 `.env.example`。

## 开发

需要 Flutter 3.8+ / Dart 3.8+。各平台还需要对应的原生工具链：

- Windows：Visual Studio 2022「使用 C++ 的桌面开发」工作负载
- Linux：GTK3、ALSA、libmpv、ninja 等开发包
- macOS / iOS：Xcode
- Android：Android SDK

获取依赖并做静态检查：

```bash
flutter pub get
flutter analyze
```

测试文件使用 `*Test.dart` 命名（不是 Flutter 默认的 `*_test.dart`），需要显式指定：

```bash
flutter test test/nsoTest.dart test/domainTest.dart test/uiTest.dart test/mobileTest.dart
```

构建前先准备 FFmpeg 资源：

```bash
# Windows
pwsh ./tool/fetchFFmpeg.ps1 -Target windows-x64

# macOS / Linux
bash tool/fetchFFmpeg.sh macos-arm64
bash tool/fetchFFmpeg.sh linux-x64
```

构建应用与安装包：

```bash
flutter build windows --release
flutter build macos --release
flutter build linux --release
flutter build apk --release --split-per-abi
flutter build ios --release --no-codesign
```

Windows 安装包使用 Inno Setup：

```powershell
& "C:\Program Files (x86)\Inno Setup 6\ISCC.exe" setup\setup.iss
```

CI 使用 `.github/workflows/mobile.yml`；在 Actions 中手动运行 `Mobile` 工作流并选择 `target`（`windows` / `all` 等）即可构建对应安装包。

## 登录与 znca-api

为获取到您的Nintendo Switch Online数据，程序将要求登录您的Nintendo账户。由于Nintendo限制，在登录过程中会涉及到使用第三方Nintendo Switch Online Api以实现加密包体获取，你的 Nintendo 账号 id_token 将被发送到第三方 API（[nxapi-znca-api](https://github.com/samuelthomas2774/nxapi-znca-api)）用于完成令牌校验。

请注意，由于涉及到了第三方Api进行操作，该操作可能存在部分风险或稳定性较差，开发者不对账户安全性进行保证。但请放心，id_token并不会泄露您的账户。您的Nintendo Switch Online账户数据将会被加密保存至本地。

本项目的 NSO 登录与 SplatNet 3 数据接入参考了开源项目 [Cypas/splatoon3-nso](https://github.com/Cypas/splatoon3-nso) 的实现，在此致谢。

## 反馈

设备相关的故障请在关于页点击「复制设备信息」，连同问题描述一起提交 issue。

## 许可证

本项目自有代码采用 AGPL-3.0-only；第三方组件、字体、图片、模型和 FFmpeg 仍受各自许可约束。

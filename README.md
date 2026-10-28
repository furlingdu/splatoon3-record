# Splatoon3 Record

Flutter/Dart 的 Splatoon 3 采集、缓存与归档工具，覆盖桌面与移动端。

## 构建

```powershell
pwsh tool/Fetch.ps1
pwsh tool/Check.ps1
pwsh tool/Test.ps1
pwsh tool/Build.ps1
pwsh tool/Package.ps1
```

产物位于 `dist/Splatoon3Record3.0.0X64Setup.exe`。

## 数据目录

沿用 `~/.splatoon3record`。首次启动会备份 `config.json`、`secrets.json`、`matches`、`thumbs`、`backgrounds` 到 `Backup/<时间>`。

旧版 Windows `secrets.json` 使用 Electron safeStorage 加密，可以通过 DPAPI/OSCrypt 导入。旧版视频绝对路径不迁移、不重写。

## 目录

- `lib/config`：路径、端口、编码参数、NSO/QQ 地址和版本常量
- `lib/app`：启动、状态、窗口和按流程拆分的业务编排
- `lib/media/capture`：采集桥接、FFmpeg 参数和录制/直播编排
- `lib/media`：FFmpeg 编码服务、昵称检测与打码
- `windows/runner/capture`：Media Foundation 原生采集、低延迟预览和原始帧投递
- `lib/nso`：Nintendo 登录、Coral 和 SplatNet
- `lib/qq`：QQBot 绑定、网关、命令和上传
- `lib/store`：配置、归档、日志、旧凭证迁移
- `lib/ui`：Material 3 界面、页面和控件
- `tool`：验证、测试、构建和打包脚本

## 平台

五端都用系统原生接口取帧，FFmpeg 只负责编码与后期：

- Windows：Media Foundation 原生采集，预览为 Flutter 外部纹理，包内 `ffmpeg.exe` 编码，`ffplay.exe` 仅用于声音返听。
- macOS：`packages/macos_capture` 用 AVFoundation 取 NV12 帧写入 ffmpeg stdin，`FlutterTexture` 预览；音频由 `AVCaptureAudioDataOutput` 转 s16le 写入 FIFO，作为 ffmpeg 第二路输入。
- Linux：`packages/linux_capture` 用 V4L2 mmap 取帧（NV12/YUYV），转 NV12 后写入 ffmpeg stdin；音频由 ALSA 采集后写入 FIFO。
- Android：`flutter_ffi_uvc` 走 libuvc + MediaCodec 原生采集与硬件编码分段 MP4；音频由 `AudioRecord` 原生录制为 AAC 伴轨，再用 `MediaExtractor + MediaMuxer` 无损合流。不使用系统相机，也不使用 Camera2。
- iOS/iPadOS：`packages/mobile_capture` 用 AVFoundation 采集 iPadOS 17+ UVC 设备，`AVCaptureMovieFileOutput` 录制同一文件内的音视频，`AVAssetExportSession` 导出 MP4；不枚举内置相机。

FFmpeg 按构建目标架构下载，不跨架构打包：

```bash
pwsh tool/FetchFFmpeg.ps1 -Target windows-x64
bash tool/FetchFFmpeg.sh macos-arm64
bash tool/FetchFFmpeg.sh linux-x64
```

## 移动端

Android、iPhone 与 iPad 共用一套响应式界面：手机窄屏默认收起侧栏菜单，平板与桌面按宽度在抽屉和固定栏之间切换，列表、状态卡片与操作按钮随屏幕宽度调整列数和内边距。

移动端只支持 USB 采集卡（UVC），不提供系统相机，也没有直播功能。移动端具备完整采集录制链路：采集卡实际档位枚举、预览、按屏幕刷新率渲染、分段录制、对局裁剪、缩略图、打码与 QQBot 推送；Android 采集卡音频走原生 AAC 音轨并合流为单个 MP4，iOS 由 AVFoundation 直接写入。初次配置必须完成 NSO 与 QQBot 登录后才能继续。`assets/tools` 只在桌面平台打包。

```bash
flutter build apk --release --split-per-abi
flutter build ios --release --no-codesign
```

iOS 产物为未签名 app，需要自行签名后再安装。`.github/workflows/mobile.yml` 会构建五端工件：Windows 安装包、macOS arm64、Linux x64、Android arm64/armv7 APK 与 iOS 未签名 IPA。


## 说明

UI 使用 Material 3 复刻旧版 MDUI 的深色桌面布局，复用了旧版位图、图标语义、字体和 ONNX 模型。Windows 采集链路为 Media Foundation 原生取帧、共享内存预览、FFmpeg 原始帧编码；macOS/Linux 为 AVFoundation/V4L2 原生取帧后写入 FFmpeg 编码。

当前已实现：

- NSO 浏览器 OAuth、Coral 加密登录、SplatNet GraphQL 对局拉取
- 缓存分段裁剪、自动归档、缩略图
- ONNX 昵称检测与归档打码
- QQBot 扫码绑定、命令、分片上传与自动推送
- Media Foundation 低延迟预览、独立预览窗口
- 桌面 RTMP 采集/直播、无损转发；移动端不提供直播
- GitHub Release 更新下载与安装
- 旧 Electron 版检测与静默卸载、数据备份与凭证迁移

实时逐帧昵称打码仍待独立的实时媒体处理层实现。


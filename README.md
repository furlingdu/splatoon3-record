# Splatoon3 Record

Flutter/Dart 桌面版 Splatoon 3 采集、缓存、归档与直播工具。

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

Windows 使用 Media Foundation 直接采集视频，预览由原生 RGBA 帧通过 Flutter 外部纹理直接显示；随包 `ffmpeg.exe` 只负责最终编码、分段封装、推流、裁剪和归档打码，`ffplay.exe` 只用于声音返听。macOS/Linux 使用系统 `ffmpeg` 采集与录制，不提供原生实时预览；构建使用 `tool/Build.sh`。macOS 的 URL Scheme 已写入 `Info.plist`，Windows 由安装器注册 `npf71b963c1b7b6d119`。

## 说明

UI 使用 Material 3 复刻旧版 MDUI 的深色桌面布局，复用了旧版位图、图标语义、字体和 ONNX 模型。Windows 采集链路为 Media Foundation 原生取帧、共享内存预览、FFmpeg 原始帧编码；macOS/Linux 使用 V4L2/AVFoundation 设备后端。

当前已实现：

- NSO 浏览器 OAuth、Coral 加密登录、SplatNet GraphQL 对局拉取
- 缓存分段裁剪、自动归档、缩略图
- ONNX 昵称检测与归档打码
- QQBot 扫码绑定、命令、分片上传与自动推送
- Media Foundation 低延迟预览、独立预览窗口
- RTMP 采集/直播、无损转发
- GitHub Release 更新下载与安装
- 旧 Electron 版检测与静默卸载、数据备份与凭证迁移

实时逐帧昵称打码仍待独立的实时媒体处理层实现。


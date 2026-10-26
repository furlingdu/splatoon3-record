# Splatoon3 Record 工程规则

## 项目边界

旧工程位于 `D:\Develop\splatoon3record`，只允许读取。禁止修改、格式化、清理、构建或运行会写入旧工程的命令。需要参考旧代码时只读；需要复用图片、字体、模型时复制到本项目。

新工程位于 `D:\Develop\splatoon3-record`。所有新代码、测试、脚本、安装器和构建产物只写入这里。

## 命名规则

所有自有函数、方法、变量、参数、字段、类、枚举、常量和脚本文件名使用 UpperCamelCase。每个单词首字母大写，不使用下划线或连字符连接单词。

示例：

- `GetStatus`
- `StartRecord`
- `PushMatch`
- `CaptureDevice`
- `PreferredEncoder`

禁止：

- `GetUserLoginDataAndUserDataForApi`，应改为 `GetUserData`
- `CaptureDeviceManagerHelper`
- `StatusPageWidgetBuilder`
- `DoSomethingForTheUserWhenReady`
- `Util`、`Helper`、`Manager`、`Processor`、`Handler` 等泛化后缀

文件名同样使用 UpperCamelCase，例如 `StatusPage.dart`、`CaptureService.dart`、`Setup.iss`。测试文件命名 `StatusPageTest.dart`。

目录名全部使用小写单词，多个单词用下划线连接，例如 `lib/app`、`lib/config`、`lib/media/capture`、`assets/images`、`third_party`、`testdata`。Flutter 生成的 `macos/Runner`、`macos/Flutter`、`Runner.xcodeproj` 等固定目录保持模板原名。

语言、Flutter 框架、构建工具强制要求的名称不受上述规则约束，包括 Dart 的 `main()`、`build()`、`initState()`、`dispose()` 等生命周期覆盖，`pubspec.yaml`、`analysis_options.yaml`、`CMakeLists.txt`、平台 runner 工具生成文件名，以及 JSON 数据键、HTTP 字段、URL、MethodChannel 字符串和第三方 API。私有成员允许语言要求的 `_` 前缀。

专有名词保留官方大小写，不受 UpperCamelCase 单词拆分约束，例如 `FFmpeg`、`FFplay`、`ONNX`、`NSO`、`SplatNet`、`QQBot`、`GitHub`、`DirectShow`、`MediaFoundation`。

## 注释规则

全部自有代码、测试、构建脚本、安装脚本和配置文件不写注释。包括 Dart、C++、Objective-C、PowerShell、Python、CMake、YAML、Inno Setup。

许可证文本只放 `LICENSE` 和 `third_party/Licenses/`，不在每个源文件放版权注释。

`tool/Check.ps1` 必须执行注释与命名检查，失败时禁止打包。

## 架构规则

- Flutter/Dart 负责 UI、状态、配置、归档、NSO、QQBot、更新、文件管理和归档打码编排。
- Windows 使用 Media Foundation 原生采集，独占采集设备并按帧读取 NV12；预览通过 Flutter 外部纹理直接显示 RGBA 帧，不经过 FFmpeg、H.264 或 UDP。
- FFmpeg CLI 只负责最终编码与输出：分段录制、直播推流、裁剪和归档打码，不参与实时取帧或实时预览。
- 原始 NV12 帧通过本地管道交给 FFmpeg 编码；录制线程与预览线程都不得阻塞采集线程，队列满时丢弃旧帧而不是阻塞采集。
- macOS/Linux 使用 FFmpeg 设备后端完成录制，暂不提供原生实时预览；RTMP 模式由 FFmpeg 接收输入。
- ONNX Runtime 通过 Dart 插件运行昵称检测模型，检测在 isolate/后台任务中执行，不在 UI 帧回调中运行。
- 当前未引入独立 `media_core`；实时逐帧打码仍属于待实现能力。
- 不引入 Electron、Node 运行时、libobs 或额外状态管理框架。
- 不在 UI isolate 做逐帧处理，不把业务状态复制到原生层。
- 新增依赖前先确认桌面平台支持、许可证、维护状态和实际必要性。

## 数据兼容

用户数据根目录固定为 `~/.splatoon3record`。必须保留：

- `config.json` 未知字段
- `matches/*.json` 与 `rawData`
- 归档视频绝对路径
- `handledIds` 的 `accountId:matchId` 语义
- 日志、缩略图、背景、旧凭证文件

任何迁移不得删除用户视频或归档。旧 `secrets.json` 失败时只提示重新登录，不覆盖。

## 目录约定

- `lib/config/Config.dart`：路径、端口、编解码参数、NSO/QQ 服务地址和版本常量。
- `lib/app/AppController.dart`：只保留状态、启动、导航和共享方法。
- `lib/app/flow/`：按 NSO、QQ、采集、对局、更新、平台拆分的流程扩展。
- `lib/media/capture`、`lib/media/ffmpeg`、`lib/media/nickname`：采集桥接与参数、FFmpeg 编码服务、昵称检测/打码。
- `windows/runner/capture`：Media Foundation 设备枚举、低延迟取帧、RGBA 预览、共享内存和 FFmpeg 原始帧写入。
- `lib/nso`、`lib/qq`、`lib/store`、`lib/ui`：协议、持久化和界面。
- `windows/`、`linux/`、`macos/`：Flutter 官方桌面 runner 目录，不手工改名。
- `test/`、`tool/`、`assets/`、`setup/`、`dist/`：测试、脚本、资源、安装器和产物。

## 验证命令

```powershell
pwsh tool/Fetch.ps1
pwsh tool/Build.ps1
pwsh tool/Test.ps1
pwsh tool/Check.ps1
pwsh tool/Package.ps1
```

Windows 最终产物输出到 `dist`。macOS/Linux 使用 `tool/Build.sh` 和 CI 构建。


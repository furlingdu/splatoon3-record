# Splatoon3 Record

[![CI](https://github.com/furlingdu/splatoon3-record/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/furlingdu/splatoon3-record/actions/workflows/ci.yml)
[![License: AGPL-3.0-only](https://img.shields.io/badge/license-AGPL--3.0--only-blue.svg)](LICENSE)

Splatoon3 Record 是一款面向 Splatoon 3 的本地录制、直播与对局归档工具。程序通过采集卡持续获取画面，将录制分成可独立解析的 MP4 分段，再依据 Nintendo Switch Online 返回的真实对局结束时间和持续时间裁剪整局录像。对局可以归档到本地，也可以由 QQBot 压制后推送。

## 功能

- 通过采集卡录制画面与声音，支持分辨率、帧率、垂直翻转和三档恒定质量录制
- 按真实对局时间从缓存分段中裁剪录像，不依赖文件创建时间推断比赛时间
- 统一归档占地、蛮颓、X、活动、私房和鲑鱼跑等 NSO 返回的对局类型
- 提供本机 HTTP 直播页，可直接作为 OBS 浏览器源使用
- 直播链路支持昵称检测和柔和模糊，原始录制与本地归档保持不变
- 相册支持逐帧昵称打码，打码成品与原视频分开保存
- 通过 QQBot 完成绑定、录制控制、状态查询、最近对局和视频推送
- Windows、macOS 和 Linux 使用 Electron Builder 构建本地安装包

## 运行要求

- Node.js 24 或更高版本
- 可用的采集卡或摄像头，以及可选的音频采集设备
- 构建时需要下载对应平台的 FFmpeg；当前下载脚本未读取 `HTTP_PROXY` 或 `HTTPS_PROXY`，网络受限时可先把对应平台的 FFmpeg 放入 `bin/`
- 昵称打码需要仓库内的 `runtime/models/spld_v2_nickname.onnx`
- Nintendo Switch Online 登录需要访问 Nintendo 服务及项目配置的 NSO 接口
- QQBot 推送需要在本机完成机器人绑定

## 开发

```bash
npm ci
npm run typecheck
npm run lint
npm run test:unit
npm run test:integration
npm run build
```

UI 测试、采集冒烟和打包冒烟需要 Chromium、Electron、真实 FFmpeg 或对应平台的安装包：

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

macOS 安装包在 macOS arm64 runner 上构建，Windows 安装包为 x64 NSIS，Linux 安装包为 x64 AppImage。构建不发布 GitHub Release。三平台打包矩阵仅在第三方资源再分发审核完成且仓库变量 `THIRD_PARTY_ASSETS_CLEARED` 设为 `true` 后运行，上传经过打包冒烟验证的 Actions artifact；该变量未设置时，CI 通过只代表测试任务通过，不代表三平台构建成功。

## 配置

程序运行时数据位于 `~/.splatoon3record/`。配置文件和密钥不会写入仓库。可以复制 `.env.example` 为 `.env`，按需填写推送编码器、推送体积、直播端口、NSO 后端和公开项目信息。

录制缓存与分段时长由程序固定管理，不提供修改入口。录制质量使用 18、22、28 三档，质量调整从下一个分段开始生效。

## 数据与隐私

Nintendo Switch Online session、token 和 QQBot AppSecret 保存在本机用户数据目录。系统加密可用时使用 Electron safeStorage 加密；不可用时当前实现仅以 Base64 编码保存，不能视为加密，请保护该目录并避免在不可信设备上配置账号。昵称检测只在本机执行，不会启动独立推理进程，不会把原始采集画面写入渲染进程的文件系统。启用 NSO 登录时，登录流程可能依照页面提示向配置的第三方 NSO 接口提交 Nintendo 签发的 id_token，以换取登录所需的校验参数；请在使用前确认你接受该网络路径。

## 授权与第三方组件

本项目自有代码采用 AGPL-3.0-only，详见 [LICENSE](LICENSE)。运行时模型、字体、界面图片、FFmpeg 构建和 npm 依赖可能各自适用不同许可；重新分发安装包前请逐项核对其来源、许可和归属。`runtime/models/` 中的模型仅作为项目运行时资源，未经授权不得替换为其他来源的模型。

## 版本

当前版本为 `2.0.0`。GitHub Actions 在推送和 Pull Request 时执行类型检查、代码检查、单元测试、集成测试与 Chromium UI 冒烟；确认第三方资源授权后才启用 Windows、macOS 和 Linux 的打包矩阵。

## 反馈

设备相关的故障请在关于页点击「复制设备信息」，连同问题描述一起提交 issue。复制内容包括采集卡能力、GPU、显示器、硬件加速状态与打码推理后端，不包含账号凭据。

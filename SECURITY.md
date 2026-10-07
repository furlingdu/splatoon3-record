# 安全策略

## 报告漏洞

请使用仓库 Security 页面上的「Report a vulnerability」私下提交，不要开公开 issue。提交时请说明受影响的版本、复现方式与影响范围。

## 敏感数据说明

- Nintendo Switch Online 的 session 与 token、QQBot 的 AppSecret 保存在本机用户数据目录 `~/.splatoon3record/`，不随仓库分发，也不写入日志。
- 系统加密可用时使用 Electron safeStorage 加密；不可用时当前实现只做 Base64 编码保存，不能视为加密，请保护该目录。
- 启用 NSO 登录后，登录流程会按页面提示把 Nintendo 签发的 id_token 提交给项目配置的 NSO 后端接口以换取校验参数。该接口只处理登录校验，不接收其他账号数据。
- 昵称打码推理只在本机执行，采集画面不会上传到任何服务。
- 关于页「复制设备信息」收集的是版本、GPU、显示器与采集规格，不包含凭据。

## 支持范围

只对默认分支上的最新版本接受安全修复。

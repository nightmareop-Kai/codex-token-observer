# Codex Token Observer 0.2.1 — Mist for Mac

Mac 新版默认使用 **Mist 原生雾面界面**。点击浮窗右上角调色盘 `Appearance`，可在 `Mist` 与原来的 `Classic` 之间切换；选择会自动保存。

## 本次更新

- **Mac**：Mist 跟随系统深浅色，使用系统字体、蓝色今日数字与柔和底板；保留前导零、数字滚动和超额红色提示。
- **Mac**：右上角、右键与菜单栏菜单都可切换外观。切换不影响统计、项目展开或隐藏状态。未保存过外观选择时默认 Mist，已有其他设置继续保留。
- **Windows**：同版本重新构建并测试，继续使用原有 WPF 界面；本次不包含 Mist 或外观切换功能。
- 本次不更改 Token 统计口径、五分钟采样间隔、数据库或账号登录状态。

## 下载与安装

- **Mac · Apple Silicon · macOS 14+**：下载 `Codex-Token-Observer-0.2.1-macos-arm64.zip`，解压后将应用放入“应用程序”。需要本机 `/usr/bin/python3` 可运行。
- **Windows 11 · x64**：下载 `Codex-Token-Observer-0.2.1-windows-x64.zip`，完整解压后运行 `CodexTokenObserver.exe`；已包含 Python 和 .NET，无需另装运行环境。
- 升级前退出旧版，再替换应用。不要下载自动生成的 Source code ZIP 作为安装包。
- 两端均为桌面应用，不是 iPhone/iPad 应用。Windows 仍为预览版。

升级保留原有账本：Mac 位于 `~/Library/Application Support/Codex Token Observer/`，Windows 位于 `%LOCALAPPDATA%\Codex Token Observer\`。安装包不含开发者的账号、统计账本或会话日志，新用户从自己的首次初始化开始统计。

## 使用边界与安全

Mac 为 ad-hoc 签名、未经过 Apple 公证；Windows 未做商业代码签名。请核对下载地址与随包 SHA256，遵循公司 IT 安装策略，不要关闭系统安全保护。

Token 数值来自本机 Codex 活动，不等同于 API 账单或完整账号历史用量。每周额度依赖已有登录状态的官方 Codex CLI；额度不可用不影响本地计数。Windows 不自动读取 WSL 或远程会话。

隐藏浮窗不会停止后台统计；通过菜单栏或系统托盘中的 `Show Window` 恢复。

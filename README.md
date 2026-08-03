# Codex Token Observer

本地优先的 macOS Codex Token 桌面观察器，显示 `TODAY` 和 `TOTAL`，并使用机械里程表式数字动画。

![Codex Token Observer](docs/hardware-panel-visual-baseline.png)

## 系统要求

- macOS 14或更高版本
- Apple Silicon Mac（当前预编译包为arm64）
- 本机已安装并使用Codex桌面应用
- Python 3（当前原型通过系统Python运行本地采集器）

应用不需要OpenAI API Key，也不会上传会话内容或Token统计。详见 [`PRIVACY.md`](PRIVACY.md)。

## V1 数据口径

- `TODAY`：本机当地时间当天 00:00 起、且不早于首次初始化时间的 Codex Token 活动量。
- `TOTAL`：本机从首次初始化开始累计的 Codex Token 活动量。
- 数据来自本机 `~/.codex/sessions/**/*.jsonl` 中 Codex 写入的 `token_count` 事件。
- 每条事件只计一次；程序停止期间产生的新事件会在下次启动时补记。
- 不追回首次初始化以前的历史 Token。

这里的 Token 是 Codex 报告的活动量，不等同于费用、剩余额度或 API 账单。

## 运行

本项目只依赖 Python 标准库，建议 Python 3.11+。

```bash
python3 -m codex_token_counter.cli init
python3 -m codex_token_counter.cli status
python3 -m codex_token_counter.cli watch
```

从仓库根目录运行时，需要把 `src` 加入模块路径：

```bash
PYTHONPATH=src python3 -m codex_token_counter.cli init
PYTHONPATH=src python3 -m codex_token_counter.cli watch
```

本机已经初始化过后，可以随时查看当前累计值：

```bash
PYTHONPATH=src python3 -m codex_token_counter.cli status
```

默认数据库位于项目内的 `data/token_counter.sqlite3`。可以使用 `--db` 指定其他位置。

## macOS 桌面浮窗

构建并打开原生桌面观察器：

```bash
chmod +x desktop-observer/build-app.sh
desktop-observer/build-app.sh
open "dist/Codex Token Observer.app"
```

应用默认固定在桌面右下角并始终置顶，Token 更新时数字会滚动变化。窗口可以直接拖动；右键可切换到左下角、右下角或退出。浮窗会自动启动统计后台，不需要额外打开终端。

应用的运行数据库位于 `~/Library/Application Support/Codex Token Observer/token_counter.sqlite3`。

## 给朋友安装

从GitHub Release或本项目的 `release/` 目录下载zip，解压后将应用拖入“应用程序”。当前开发包使用临时签名，尚未经过Apple公证；正式公开发布前应完成Developer ID签名和公证。

## 生成分享包

```bash
chmod +x desktop-observer/package-release.sh
desktop-observer/package-release.sh 0.1.0
```

脚本会生成arm64应用zip和SHA-256校验文件。构建过程不会打包本机数据库或Codex会话日志。

## 当前边界

这个原型通过读取 Codex 本地会话日志验证统计逻辑。正式产品阶段需要评估更稳定的 App Server 事件接入；目前 App Server 协议已经确认存在 `thread/tokenUsage/updated`，但独立进程不能直接假定能够订阅桌面应用已经运行的线程。

详细口径见 [`docs/v1-data-contract.md`](docs/v1-data-contract.md)。

## 许可证

本项目采用 [MIT License](LICENSE)。

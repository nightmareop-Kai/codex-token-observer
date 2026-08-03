# V1 数据契约

## 产品显示值

### TODAY

本机当地日期中，自 00:00 起且不早于首次初始化时间的 `token_count` 事件之
`last_token_usage.total_tokens` 总和。

### TOTAL

自首次初始化时间起，所有已确认且去重后的 `token_count` 事件之
`last_token_usage.total_tokens` 总和。

## 事件来源

当前本地验证版读取：

```text
~/.codex/sessions/**/*.jsonl
```

目标事件结构：

```json
{
  "type": "event_msg",
  "payload": {
    "type": "token_count",
    "info": {
      "last_token_usage": {
        "input_tokens": 100,
        "cached_input_tokens": 80,
        "output_tokens": 20,
        "reasoning_output_tokens": 0,
        "total_tokens": 120
      }
    }
  }
}
```

正式集成候选为 Codex App Server 的 `thread/tokenUsage/updated` 通知，但必须先解决
如何订阅桌面应用已运行线程的问题，不能把独立启动的 App Server 当成同一事件源。

## 去重与恢复

- 唯一事件键由会话文件绝对路径、字节偏移、时间戳和 Token 数共同生成。
- SQLite 主键保证同一事件最多计入一次。
- 每个会话文件保存已扫描字节位置，正常轮询只读取追加内容。
- 程序停止期间产生的事件，会在下次启动后补记。
- 文件截断时游标回到文件开头，但事件主键仍防止历史记录重复。

## 数据边界

- 不追回首次初始化前的历史事件。
- 当前值代表 Codex 报告的 Token 活动量，不代表费用或剩余额度。
- TODAY 按运行电脑的本地时区归属日期。
- 硬件只显示电脑发送的快照；SQLite 是 V1 唯一可信账本。


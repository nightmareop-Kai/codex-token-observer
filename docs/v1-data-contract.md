# V1 数据契约

## 产品显示值

界面、菜单、提示和可访问标签统一使用英文；项目名称保留 Codex 中的原文（包括中文），不翻译。

### TODAY

本机当地日期中，自 00:00 起且不早于首次初始化时间的 `token_count` 事件之
`last_token_usage.total_tokens` 总和。

### TOTAL

自首次初始化时间起，所有已确认且去重后的 `token_count` 事件之
`last_token_usage.total_tokens` 总和。

### PROJECT · TOP 3

按 Codex 会话 `session_meta.payload.cwd` 的完整工作目录聚合，自首次初始化时间起计算
各项目累计 Token 与今日 Token，并显示今日消耗最高的三个项目。界面优先使用 Codex 侧栏中与
该目录匹配的项目名称，不使用聊天任务标题；未匹配时回退到目录最后一级。原始完整路径仍是统计
身份，改显示名称不修改历史 Token，不将不同路径的同名项目合并。无法取得 `cwd` 的记录归入 `UNKNOWN`。

项目名称在每次采样时重新读取：优先只读查询 Codex 本地 `state_5.sqlite` 中的 `projects` 和
`project_roots`；该来源不可用时回退 `.codex-global-state.json` 的项目名称字段。只匹配完整目录，
不猜测父目录或工作树归属，也不修改 Codex 的项目配置。此内部元数据格式可能随 Codex 版本变化，
无法读取时保留目录名显示及正常计数。长名称悬停可查看全名和原始目录。

每个项目都有两项真实统计：`TOTAL` 为该项目累计消耗，`TODAY` 为该项目在本机当地日期
00:00 起的消耗。整个列表按 `TODAY` 降序排列；今日值相同时按 `TOTAL` 降序，再按名称、
完整路径稳定排序。项目的 `TODAY` 与全局 `TODAY` 使用同一次采样时间，跨午夜后的下一次
采样会更新为新一天的数值；当天没有事件时为零，累计值保持不变。用于主面板视觉测试的
固定基数不会计入项目统计。

桌面数据流的 `projects` 数组包含全部已统计的项目，按上述今日排名输出。默认浮窗只显示
前三项的 `TODAY`；点击 `PROJECTS` 或右侧 `ALL N` 展开滚动列表，前三项显示 `TODAY` 与 `TOTAL`，其余项
只显示 `TOTAL`。展开后右侧显示 `COLLAPSE · N`，再点收起。展开不会切换到累计排名，也不会删除未显示的统计字段。
格式如下；`total` 和 `today` 均为整数 Token 数：

```json
{"name":"example","path":"/work/example","total":1250000,"today":42000}
```

### WEEKLY REMAINING（每周剩余额度）

通过已登录的 Codex CLI 的 App Server `account/rateLimits/read` 读取主 `codex` 额度桶，
按 `windowDurationMins = 10080` 识别每周窗口（可能位于 `primary` 或 `secondary`）。
不混入 Spark 等独立额度桶，也不把本机 Token 总数当作账号额度分母。

- 显示 `clamp(100 − current_percent, 0, 100)`，即当前窗口剩余比例，不是固定 Token 余额。
- 系统或手动重置后，在下一次成功采样时跟随服务报告的当前余额恢复；不叠加旧用量，不显示累计估算前缀。
- 历史 carry 保留为本地协议兼容数据，不用于余额、填充长度、颜色或耗尽警示。
- 读取失败显示上次值及 `STALE`，从未取得有效数据时显示 `—`；未知不能当作 0%。
- 填充长度按剩余比例；颜色按当前已用比例从绿色过渡到黄色、红色。余额耗尽才将 Token 有效数字提示为红色，重置后恢复。Today 和 Total 不随额度重置清零。
- 软件只读取额度，不消费重置次数。桌面采样间隔为 300 秒，额度随采样刷新。

官方字段说明见 [Codex App Server](https://learn.chatgpt.com/docs/app-server#6-rate-limits-chatgpt)。

### 采样、动画与窗口层级

桌面观察器启动时采样一次，之后每 300 秒扫描本地会话并刷新快照。采样确认的数值变化
使用约 3–5 秒的先快后慢滚动动画，抵达目标值后停止；没有新数值时不重播。动画中的
中间数字是呈现插值，不是额外的 Token 事件，不写回账本。

`Follow Codex / ChatGPT` 默认开启，只根据原生应用的前台状态调整浮窗层级：Codex 或
ChatGPT 在前台时置顶，其他应用在前台时退回普通窗口层级。关闭跟随可恢复常驻置顶。
手动隐藏（`Hide Window`）优先于前台跟随，应用切换不会重新显示已隐藏的浮窗；隐藏时后台仍按相同间隔
继续采样，可通过 `Show Window` 重新显示。窗口跟随不会改变事件来源，也不统计 ChatGPT 会话的 Token。

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

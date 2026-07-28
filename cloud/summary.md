2026-07-28 19:35:24 CST

# What changed

- `/command/poll` 的有指令和无指令响应都会返回毫秒级 `serverTime`。
- `/sync/push` 会对连续的未来估算时间整体回锚到可信接收时间，同时保留原来的
  五分钟间隔。
- 立即采样回填也会限制明显超前的估算时间。

# Why

部分网络会屏蔽 NTP 的 UDP 123 端口。ESP32 现在可直接从已经成功建立的 HTTPS
轮询响应取得时间，不再因 NTP 失败而阻断采样。云端回锚同时阻止旧的 UTC+8
编译时钟估算把历史记录显示到未来。

# Safe to modify

- `ESTIMATED_TIME_FUTURE_TOLERANCE_MS` 可按允许的网络和调度偏差调整。
- `serverTime` 可继续添加到其他成功响应，不影响旧客户端。

# Risky areas

- 连续估算记录必须整体平移，不能逐条压到接收时刻，否则会破坏采样间隔。
- 不要移除 `(device_id, sequence)` 主键幂等性；ESP32 的即时读数可能同时通过
  `/command/respond` 和 `/sync/push` 到达。

# Assumptions and constraints

- `serverTime` 使用 Unix 毫秒，固件在写入系统时钟前转换为秒。
- 已部署到 `plant-talk-sync` 云函数，实时 `/command/poll` 响应确认字段存在。

# Suggested next improvement

- 为时间回锚次数和 ESP32 定时上传失败次数增加可查询的监控指标。

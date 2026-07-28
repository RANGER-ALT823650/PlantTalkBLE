2026-07-28 19:35:24 CST

# History Overview 传感器详情下拉云同步

## What changed

- `DetailView` 的下拉刷新先调用 `CloudSyncService.sync(database:)`，再重新查询
  日汇总，因此 Web 或 ESP32 通过云端写入的传感器记录可在当前页面收敛。
- 任务被取消时不再继续发起页面重载。

## Why

原来的 `.refreshable` 只重查本机 SQLite。即使 ESP32 已经通过 Wi-Fi 把五分钟
读数写到云端，详情页下拉也不会主动拉取这些记录，看起来就像 iOS 同步失效。

## Safe to modify

- 同步完成后的本地查询、加载提示和错误文案可以独立调整。
- 其他详情 Tab 可复用相同的“先云同步、后查询”顺序。

## Risky areas

- 不要把本地查询移到云同步之前，否则本次手势仍可能展示旧快照。
- 不要在 `DetailView` 创建另一套同步服务或数据库实例；必须继续使用共享服务和
  当前环境中的 `PlantDatabase`。

## Assumptions and constraints

- 云同步 URL、鉴权令牌和设备 ID 已在 App 设置中配置。
- 本次按要求只修改源代码，没有构建、启动或验证 iOS App。

## Suggested next improvement

- 在传感器详情页显示最近一次云同步摘要或错误，让下拉后的结果更可诊断。

# ESP32 历史数据批次完整性修复

## What changed

- ESP32 在每批结束包中声明本批实际发送的记录数、首序号和末序号。
- iOS 收到结束包后才校验整批数据；只有数量、首序号、末序号和中间连续性全部相符，才写入 SQLite 并回复 ACK。
- 批次不完整时不推进本地游标，下次同步仍从原游标请求，因此不会把“后半批”误当成完整数据。
- 新增单元测试和默认关闭的真机 BLE 集成测试。

## Why

原协议的结束包只告诉 iOS “最后一条是什么”。如果一批 64 条中前几个 BLE notification 丢失，iOS 可能把剩下的后缀提交并越过丢失数据。新增的批次声明让 iOS 能区分 BLE 传输丢包和 ESP32 Flash 中本来就不存在的序号。

## Safe to modify

- 每次请求的上限可以调整，但必须同时保证 ESP32 发送上限、结束包记录数字段和 iOS 校验上限一致。
- 错误文案、测试超时时间和同步状态显示可独立调整。

## Risky areas

- `HistoryTransferProtocol.BatchEnd` 的字节布局必须与固件保持完全一致。
- 不能在 SQLite 事务成功前发 ACK，否则断电或写库失败会再次造成永久跳过。
- 新 iOS 端会拒绝缺少批次完整性字段的旧固件，所以部署顺序必须是先升级 ESP32，再安装新 App。

## Assumptions and constraints

- 协议仍为 20 字节、版本 1；本次复用了结束包中原保留的字节。
- ESP32 因断电没有采集到数据时，只会出现时间间隔，不会造成本批内序号不连续，因此不会触发无限重试。
- Flash 滚动覆盖或损坏导致的源端序号跳号可以被接受，前提是 ESP32 声明的首末范围与 iOS 实际收到的范围一致。

## Suggested next improvements

- 增加一个可视化的“批次重传次数”诊断指标，便于区分环境干扰与设备采样中断。
- 如果未来需要支持旧固件和新固件长期混用，将此布局升为明确的协议版本 2，并增加能力协商。

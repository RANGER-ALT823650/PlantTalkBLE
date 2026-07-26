# 迁移状态

更新时间：2026-07-26（第二次审计，含真机反馈）
基准文档：仓库根目录 `鸿蒙移植提示词.md`（平台约束见其 §12）

## 一、总体进度定位

按 `鸿蒙移植提示词.md` §11 的九个交付阶段对照：

| 阶段 | 状态 | 说明 |
|---|---|---|
| 1 脚手架 + 设计系统 | 基本完成 | 缺图标资源与材质封装 |
| 2 数据层 + BLE | **协议层完整，落库全线不通** | 见「二、致命问题」 |
| 3 静态界面 | 骨架完成，细节粗糙 | 见「四、视觉缺口」 |
| 4 P0 动画 | 三页转场基本到位；Orb 仍是占位 | |
| 5 文本对话 + LLM | **未开始** | 无 chat client、无 SSE、无对话持久化 |
| 6 P1 动画 | 几乎未开始 | |
| 7 实时语音 | 未开始 | 无 WebSocket、无 PCM 采集/播放 |
| 8 记忆注入 + P2 细节 + 触觉 | 未开始 | `memory/` 目录不存在 |
| 9 云同步 | 未开始 | |

代码量：ArkTS 约 7093 行（29 个 `.ets`），对应 iOS 业务代码约 20000 行（不含测试）。

计划外完成项：**AI 生图**（`ai/PlantImageGenerationClient.ets`、`data/GeneratedImageStore.ets`、
`pages/GeneratedImageGalleryPage.ets`、`components/PlantArtworkEditorOverlay.ets`、
`components/ZoomableImagePreview.ets`），对应 iOS 较新的千问图像编辑功能。这是目前**唯一接通的网络功能**。

构建状态：`build_project` BUILD SUCCESSFUL（API 20 编译，兼容 API 12），仅有
`Function may throw exceptions` 类 WARN。**构建成功不代表功能可用。**

## 二、致命问题（阻塞主链路，必须先修）

### F1 relationalStore 用了仅向量数据库支持的 API → 一张表都没建出来

`data/RelationalHistoryRepository.ets` 的事务与 SQL 执行整体建立在
`beginTrans()` / `execute(sql, txId, args)` / `commit(txId)` / `rollback(txId)` 上。
官方约束明确：**这四个 API 仅支持向量数据库**，而 `StoreConfig`（:26-31）未设 `vector`，
是普通 RDB。

失败链：
1. `prepareSchema` 在 `beginTrans()`（:213）即抛异常（预期 801 Capability not supported）；
2. `DatabaseSchema.CREATE_STATEMENTS` 的 8 张表 + 6 个索引全部未创建；
3. 异常经 `open()`（:34）冒泡到 `pages/Index.ets:123`，被降级成一句 toast
   「BLE 数据库初始化失败」，用户只看到蓝牙按钮点不动；
4. 即使事务可用，`execute('SELECT changes()')`（:147）与
   `execute('SELECT COALESCE(MAX(last_sequence),0) ...')`（:172）也必然失败 ——
   `execute` 不支持查询语句。

修复方向（详见 `鸿蒙移植提示词.md` §12.1 的正确写法）：
- `beginTransaction()` / `executeSql(sql, args)` / `commit()` / `rollBack()`；
- 查询一律 `querySql` + ResultSet + `close()`；
- 「是否真的插入」改用 `insert()` 返回 rowId（-1 表示 UNIQUE 冲突未插入），
  不再依赖 `SELECT changes()`；
- `PRAGMA foreign_keys = ON`（:33）从 `executeSql` 改为 `execute`；
- 鸿蒙**不支持外键级联**，schema 里 5 处 `ON DELETE CASCADE` 需在 DAO 层手写级联删除。

### F2 对话与消息零持久化，发送消息无任何效果

`ai_conversations` / `ai_messages` / `ai_message_tool_invocations` /
`ai_memory_message_sequences` / `ai_message_images` 五张表**只出现在建表字符串里**
（`data/DatabaseSchema.ets:33-85`），全工程无任何 INSERT/SELECT，也没有 Repository。

- `pages/Index.ets:504` 的 `onSend` 是空实现 `(_message: string) => {}`；
- `pages/TextConversationPage.ets:101` 的 `messages` 是 `@Prop`，但 `Index.ets:501-508`
  构造时根本没传；文件自身注释（:94-96）也承认持久化未接线；
- `pages/HistoryOverviewPage.ets:169,180` 的「文字对话」「实时语音」两个 tab
  是硬编码空状态。

对照 iOS `PlantDatabase.swift`，缺失的持久化 API：`createConversation`(:496)、
`allConversations`(:526)、`chatMessages`(:554)、`saveChatMessage`(:669)、
`memoryHistoryMessages`(:611)、`deleteChatTurn`(:738)、`deleteConversation`(:771)。

### F3 主题设置不持久化，重启即丢

`entryability/EntryAbility.ets:10` 在 `onCreate` 里无条件
`AppStorage.setOrCreate('appTheme', 'blue')`，`pages/AppSettingsPage.ets` 只改
`AppStorage`（不落盘）。结果：用户切换主题后重启回到蓝色。`reduceMotion` 同样。

## 三、严重问题

| # | 问题 | 位置 |
|---|---|---|
| S1 | `sensor_readings` 只写不读；iOS 的 6 个查询 API（`sensorSummary`/`sensorSeries`/`historySummaryByDate`/`historyReadings`/`latestHistoricalReading`/`deleteAllHistory`）全缺失，`HistoryRepository` 只暴露 3 个方法 | `data/HistoryRepository.ets:3-13` |
| S2 | 数据库开在页面 `aboutToAppear`，而非 `EntryAbility.onCreate` 单例 | `pages/Index.ets:60`、`entryability/EntryAbility.ets:9` |
| S3 | `aboutToAppear` 丢弃 async Promise 且无 `.catch`，前置 await 失败会静默跳过 BLE 初始化 | `pages/Index.ets:61` |
| S4 | 并发初始化窗口：`bleRuntimeInitializationStarted` 在 4 个 await 之后才置位，与 `toggleBluetooth` 竞态，可能重复 `getRdbStore` | `pages/Index.ets:82-89, 438-449` |
| S5 | RdbStore 永不关闭，无 `onWindowStageDestroy` | 全工程无 `store.close()` |
| S6 | `BusinessError.code` 被折叠成中文文案，真机无法定位（801 就是这么被藏住的）；另有 9 处 `catch (_error)` 静默返回 null/[] | `data/RelationalHistoryRepository.ets:228,245-253`；`GeneratedImageStore.ets`、`PlantArtworkStore.ets` |
| S7 | `store.version` 在事务外读写，且与建表非原子 | `data/RelationalHistoryRepository.ets:207,219-220` |
| S8 | `getColumnIndex` 返回值未校验 -1 | `data/RelationalHistoryRepository.ets:50,71` |
| S9 | 后续阶段所需权限未声明：`MICROPHONE`、`CAMERA` | `entry/src/main/module.json5:15-29` |

## 四、视觉缺口（用户反馈「前端很丑」的具体原因）

1. **图标全部是 Unicode 字符与 emoji**，工程内零图标资源、零 `SymbolGlyph`：
   - 工具栏 `◷`（时钟）、`ᛒ`（蓝牙，实为北欧卢恩字母）、`⚙`；
   - 交互 `↑` `×` `‹` `›` `+` `✎` `✓`；
   - 传感器 `🌡` `💧` `◉` `☀`（`components/HomeDashboard.ets:104,116,126,146`）；
   - 空状态 `⌁` `▤` `≋` `▧`（`pages/HistoryOverviewPage.ets`、`TextConversationPage.ets:72`）。
   → 应改为 `SymbolGlyph` + Symbol 资源，或 SVG/`Path`。
2. **`backgroundBlurStyle` 全工程出现 0 次**。iOS 所有 `.ultraThinMaterial` 被替换为
   `surface_translucent` 半透明纯色，层次感消失。
3. **聊天气泡无尾巴**。`components/ChatBubble.ets:40` 只有 `borderRadius(18)` 矩形；
   iOS `ChatBubbleShape`（`TextConversationView.swift:3944-4064`）的尾巴与动态圆角
   `min(18, max(10, h*0.28))` 均未实现。
4. 等宽数字用 `fontFamily('monospace')` 近似（`components/SensorMetricCard.ets:51`），
   非 `fontFeature("tnum")`。
5. 深浅色资源仅 13 个语义色（`resources/base|dark/element/color.json`），
   iOS 侧系统动态色种类更多，部分层级只能复用。

## 五、动画现状（全工程仅 9 处 `animateTo`；`Canvas`、`geometryTransition` 各 0 次）

| 编号 | 项目 | 状态 | 备注 |
|---|---|---|---|
| B1 | 语音 Orb | **占位** | `components/DiffuseOrbFallback.ets` 为 3 层同心圆 + 无限缩放。4×4 mesh / Oklab 混白 / 30FPS 顶点扰动 / 音频包络均未实现。另：`ORB_SOFTENING`（:18-23）第 5/9/10 项与提示词 §6-B1 给定数组不一致；`OrbActivity`（:8-10）写成 1.34/1.62/2.5，规范值为 0.34/0.62/1.0（疑似整体 +1） |
| B2 | 三页横滑转场 | **基本到位** | 阈值 0.33 / 预测 0.5 / `responsiveSpringMotion(0.32,0.9)` 均对齐（`pages/Index.ets:376-418`）。偏差：`moveTo` 按钮触发用 `springMotion(0.35,1.0)`，规范为 `.smooth(0.35)`；三页始终挂载在同一 `Stack`，屏幕外的历史页 `Tabs` 持续渲染 |
| B3 | 消息飞行 | **未做** | 等几何稳定、飞行插值、`MessageFlightOverlay` 全无 |
| B4 | 文字页动画 | **部分/走形** | 附件菜单用 `Curve.EaseInOut` 420ms（`TextConversationPage.ets:526`），规范为 `spring(0.42,0.82)`；「思考中」是 3 个静态圆（:399-401），无 180ms 跳动；媒体形变、附件转移、图片预览转场、流式打字 80ms flush、工具调用展开均未做 |
| B5 | Dashboard 展开 | **基本到位** | `springMotion(0.42,1.0)` / 420ms / reduceMotion 200ms（`HomeDashboard.ets:89-95`），插画宽度比 0.38/0.66 对齐；缺进场 transition（`.move+.scale+.opacity`） |
| P2 | 卡片按压 | **已实现** | `scale 0.96 + opacity 0.85 + 150ms EaseInOut`（`SensorMetricCard.ets:72-74`） |
| P2 | 图表 / 相机 / 插画编辑手势 | **未做** | 无 `SensorChartSheet` 对应实现 |

关于 `pages/Index.ets:328-352, 401-418` 中 `duration: 0` 配 spring 曲线：
**这不是缺陷**。ArkUI 在 `springMotion` / `responsiveSpringMotion` / `interpolatingSpring`
曲线下忽略 `duration`，时长由曲线参数决定。

## 六、已落盘且质量达标的部分

- **BLE 协议层**（`ble/PlantBleProtocol.ets`、`ble/HistorySyncCore.ets`、
  `ble/PlantBleManager.ets`，共 1392 行）：服务与三个 Characteristic UUID、
  实时包 16 字节 / 历史包 20 字节小端解析、CRC-8/ATM（多项式 0x07、初值 0、跳过 byte3）、
  四条控制命令、批次完整性校验、批内序号连续性、损坏批次拒绝锁存、
  「落库成功才 ACK」时序、`remainingCount > 0 && durableSequence < newestSequence`
  才请求下一批。字段级与 iOS `HistoryTransferProtocol.swift`、`PlantReading.swift`、
  `PlantBluetoothManager.swift` 做过静态对照。
- **AI 配置持久化**（`ai/AIConfigurationStore.ets`）：URL/model/systemPrompt/voice/prompt 走
  `preferences` + `flush()`；三个 API Key 走 `@kit.AssetStoreKit`
  （`DEVICE_UNLOCKED` + `SYNC_TYPE.NEVER` + `OVERWRITE`）。**这是全工程质量最高的一段，
  可作为其它持久化的范式。**
- **数据库 schema**：8 张表 + 6 个索引，表/列与 iOS 八次 GRDB 迁移的终态逐列对齐
  （`sensor_readings` 9 列完全一致）。问题在执行 API，不在 DDL 文本。
- **响应式布局**：按实时窗口宽高计算，未写死 iPhone 尺寸；折叠屏展开态与平板下三页空间模型成立。

## 七、验证状态（诚实标注）

已做：
- iOS 源码逐字段静态对照（协议、模型、schema）。
- 纯协议代码用 iOS 金标准字节向量做 Node/TypeScript 冒烟测试。
- schema 语句在内存 SQLite 中执行通过。
- `build_project` 在 DevEco Studio + API 20 SDK 下 BUILD SUCCESSFUL。

未做 / 不成立：
- **真机数据库读写从未成功验证**。第一版 MIGRATION_STATUS 声称的「数据库成功提交后才产生 ACK」
  仅是代码结构成立，运行时因 F1 从未跑通。
- 未连接真实 Plant Sensor 验证通知订阅、增量同步与 ACK 时序。
- 未与 iOS 真机做逐像素 / 逐帧并排验收。
- 未抓取真机 `hilog` 确认 F1 的实际 `BusinessError.code`（推断为 801，来源为
  SDK `@ohos.data.relationalStore.d.ts` 声明与官方 API 约束表，非运行时实测）。
- 未做 UI 意图校验（`verify_ui`）。

## 八、建议的下一步顺序（按「收益 / 工作量」排序）

1. **修 relationalStore 事务与查询 API**（F1，约半天）。不修则 BLE 1392 行协议代码全是死的，
   收益最大。同时把初始化搬到 `EntryAbility.onCreate` 单例（S2-S4）、保留原始
   `BusinessError.code`（S6）、补 `getColumnIndex` 校验（S8）。修完在真机抓 `hilog`
   确认建表与写入。
2. **补对话持久化 + 文本 LLM**（F2 + 阶段 5，约 2-3 天）。`ConversationRepository`
   对齐 `PlantDatabase.swift:496/554/669/738/771`；`OpenAICompatibleClient` 走 SSE 流式。
   这是 App 主功能，当前完全空缺。
3. **视觉三件套**（约 1-2 天，「变好看」性价比最高）：图标换 `SymbolGlyph`/SVG、
   补 `backgroundBlurStyle`、`ChatBubble` 用 `Path` 补尾巴与动态圆角。不触碰数据流。
4. **主题持久化**（F3，约 1 小时）。
5. **补 `sensor_readings` 查询 API + 历史页/图表**（S1 + 阶段 3 剩余）。
6. **P1 动画**（阶段 6）：思考三点 180ms、附件菜单 spring(0.42,0.82)、
   媒体形变用 `geometryTransition`、消息飞行。
7. **Orb mesh 渲染器**（阶段 4 剩余）放最后。XComponent + GLSL 双三次插值是整个移植最重的一块，
   但当前占位不阻塞任何功能，且 `orb-playground.html` 已验证着色器路线可行。

# Plant Talk for HarmonyOS

这是 `ios/PlantTalkBLE` 的原生 HarmonyOS Stage/ArkTS 移植工程，迁移基准为仓库根目录的
`鸿蒙移植提示词.md`，交互与数据语义以 iOS 源码为最终权威。

## 当前状态速览（2026-07-26）

工程可编译打包（`build_project` BUILD SUCCESSFUL），但**主链路尚未跑通**：

- ✅ BLE 协议层完整（UUID、16/20 字节包、CRC-8/ATM、四条命令、同步状态机、ACK 时序）
- ✅ AI 配置持久化（`preferences` + `AssetStoreKit` 存 API Key）
- ✅ 三页横滑转场、Dashboard 展开、传感器卡片按压
- ✅ AI 生图（计划外完成，当前唯一接通的网络功能）
- ⛔ **数据库落库全线不通**：relationalStore 用了仅向量库支持的事务 API，建表即失败
- ⛔ **对话与消息零持久化**：表建了但无任何读写，发送消息无效果
- ⛔ 文本 LLM、实时语音、长期记忆、云同步、图表、相机均未开始
- ⚠️ 图标全为 Unicode/emoji、无毛玻璃、气泡无尾巴 —— 观感与 iOS 差距的主因
- ⚠️ Orb 为三层同心圆占位，mesh/Oklab/音频联动未实现

**构建成功 ≠ 功能可用。** 完整诊断、逐条证据与修复顺序见
[MIGRATION_STATUS.md](./MIGRATION_STATUS.md)。

## 开发前必读

1. `鸿蒙移植提示词.md` **§12 鸿蒙平台 API 约束与已踩过的坑** —— relationalStore 事务 API、
   `execute`/`executeSql` 的查询限制、外键不级联、spring 曲线忽略 `duration`、
   `AppStorage` 不持久化等。第一轮移植在这些点上翻过车。
2. 同文档 §4（设计系统）、§5（动画原语映射）、§6（动画参数清单）—— 参数照抄，不许「大概」。
3. 写完 `.ets` 先 `arkts_check`，再 `build_project`；阶段收尾抓一次真机 `hilog`
   确认没有被 catch 吞掉的 `BusinessError.code`。

## 在 DevEco Studio 中打开

1. 安装 DevEco Studio 与配套 HarmonyOS SDK。
2. 以本目录 `harmony/PlantTalk` 为工程根目录打开。
3. 工程目标 API 20，最低兼容 API 12。
4. 配置自动签名（真机安装/推送必需），选择手机或折叠屏真机，构建 `entry` 模块。

## 目录结构

```
entry/src/main/ets/
  ai/          AI 配置（preferences + AssetStoreKit）、生图客户端
  audio/       音频→视觉驱动器（Orb 电平/包络计算，未接真实 PCM）
  ble/         协议编解码、历史同步状态机、GATT 连接管理
  components/  Dashboard、传感器卡、气泡、Orb 占位、图片预览、插画编辑
  data/        schema、历史仓储、生图库、插画存储
  entryability/
  model/       数据模型
  pages/       Index（三页容器）、历史、文字对话、设置、AI 设置、AI 图库
  theme/       6 套强调色 + 设计 token
```

尚未创建的目录（对应未开始的阶段）：`animation/`（动画常量集中管理）、
`memory/`（长期记忆注入）。

## 下一阶段（按收益/工作量排序，详见 MIGRATION_STATUS.md 第八节）

1. 修 relationalStore 事务与查询 API，初始化搬到 `EntryAbility.onCreate` 单例，
   真机验证建表与历史写入。
2. 补对话持久化 + OpenAI 兼容 SSE 流式文本对话。
3. 视觉三件套：`SymbolGlyph`/SVG 图标、`backgroundBlurStyle`、气泡 `Path` 尾巴。
4. 主题与 reduceMotion 落盘 `preferences`。
5. 补 `sensor_readings` 查询 API、历史列表与图表。
6. P1 动画（思考三点、附件菜单 spring、媒体形变 `geometryTransition`、消息飞行）。
7. Orb mesh 渲染器（XComponent + GLSL 双三次插值，参照 `orb-playground.html`）。

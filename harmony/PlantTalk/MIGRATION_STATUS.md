# 迁移状态

更新时间：2026-07-23

## 已落盘

### 工程与视觉基础

- 原生 Stage 模型、`entry` 模块、应用图标和中/英文无关的基础资源。
- 亮/暗色语义色，以及 blue、green、yellow、pink、orange、purple 六套强调色。
- 页面按实时窗口宽高计算，不写死 iPhone 尺寸；根容器在手机、折叠屏展开态和平板尺寸下
  都能保持三页空间模型。折痕避让与双栏历史页尚未做专项适配。

### 页面

- 首页 Dashboard：工具栏、输入框、3:4 插画占位、2×2 传感器卡片、Orb fallback。
- 历史页：传感器、文字对话、实时语音三个底部标签及空状态。
- 文字对话页：初始用户消息、思考态、附件菜单、输入器和背景光晕。
- 设置页：主题选择、减弱动态效果、AI 设置入口。
- AI 设置页：文本模型、Realtime 和系统 Prompt 的字段结构。

### 动画与手势

- Dashboard 展开：420 ms；减弱动态效果时 200 ms。
- 三页横滑：`PanGesture(distance: 12)`。
- 完成阈值：页面宽度 0.33；预测阈值：页面宽度 0.5。
- 手势落定：`responsiveSpringMotion(0.32, 0.9)`。
- 按钮切页：350 ms；减弱动态效果时 200 ms。
- 转场期间暂停 Orb 动效并屏蔽主页交互。

### BLE 与数据语义

- 服务及三个 Characteristic UUID 与 iOS 一致。
- 实时包 16 字节、历史包 20 字节，小端解析。
- CRC-8/ATM：多项式 `0x07`、初始值 `0`、跳过第 3 字节。
- 历史请求、ACK、校时、立即采样四条命令。
- 批次完整性校验、批内序号连续性和损坏批次拒绝锁存。
- 数据库成功提交后才产生 ACK；终止空批次也必须先提交再 ACK。
- 只有 `remainingCount > 0 && durableSequence < newestSequence` 才请求下一批。
- 新安装数据库 schema 和 Repository/Writer 边界。

## 已验证

- 与 iOS `HistoryTransferProtocol.swift`、`PlantReading.swift` 和
  `PlantBluetoothManager.swift` 做过逐字段静态对照。
- 纯协议代码使用 iOS 金标准字节向量做 Node/TypeScript 冒烟测试。
- 全部 schema 语句已在内存 SQLite 中执行，建表成功且外键检查无错误。
- 工程 JSON/JSON5 资源做过机器解析检查。

## 尚未声称完成

- 本机没有 DevEco Studio、HarmonyOS SDK、Hvigor、HDC 或 Java，因此尚未执行 ArkTS
  编译、HAP 打包、模拟器启动与真机安装。
- HarmonyOS BLE Central/GATT 平台适配、动态权限和 relationalStore DAO 尚未接入。
- 主题与“减弱动态效果”目前只接到进程内 AppStorage，Preferences 持久化尚未接入。
- Orb 仍为分层圆形 fallback；4×4 mesh、Oklab 混白、30 FPS 顶点扰动、音频包络未实现。
- fallback 在转场/减弱动态效果下会视觉静止，但无限动画控制器的真正取消与省电要由最终
  mesh renderer 完成。
- 文本 SSE、工具调用、长期记忆、Qwen Realtime、PCM 采集/播放、相机/相册未实现。
- 当前页面是第一轮结构对齐，尚未进行 iOS 与鸿蒙真机逐像素/逐帧并排验收。

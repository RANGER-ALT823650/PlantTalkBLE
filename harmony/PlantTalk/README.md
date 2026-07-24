# Plant Talk for HarmonyOS

这是 `ios/PlantTalkBLE` 的原生 HarmonyOS Stage/ArkTS 移植工程，迁移基准为仓库根目录的
`鸿蒙移植提示词.md`，交互与数据语义以 iOS 源码为最终权威。

## 当前里程碑

- Stage 工程、资源和 6 套主题色已建立。
- 首页、历史、文字对话、设置与 AI 设置页面已建立。
- 根页面保留“历史 ← 主页 → 文字对话”的空间关系，并录入原版横滑阈值和弹簧参数。
- BLE 实时/历史 16/20 字节协议、CRC-8/ATM、控制命令和历史同步状态机已迁移。
- 新安装数据库的最终 schema 与数据访问接口已定义。
- Orb 目前是明确标记的视觉 fallback，最终会替换为 XComponent/GLSL 4×4 mesh 实现。

详细范围与验证状态见 [MIGRATION_STATUS.md](./MIGRATION_STATUS.md)。

## 在 DevEco Studio 中打开

1. 安装 DevEco Studio 与其配套的 HarmonyOS SDK。
2. 以本目录 `harmony/PlantTalk` 为工程根目录打开。
3. 安装/选择可编译 API 20 的 SDK；工程目标为 API 20，最低兼容版本为 API 12。
4. 配置自动签名，选择手机或折叠屏真机，构建 `entry` 模块。

当前工程没有写入虚构的签名、SDK 路径或“已验证”的平台 BLE 代码。

## 下一阶段

1. 在可用 SDK 上修正编译器报告并完成 HAP 首次安装。
2. 接入 `@kit.ConnectivityKit` 的 BLE Central/GATT 生命周期与权限。
3. 接入 `@kit.ArkData` relationalStore，保证“记录 + 游标”单事务提交。
4. 连接真实 Plant Sensor，验证通知订阅、历史增量同步与 ACK 时序。
5. 以 iOS OrbTuningLab 为基准实现 P0 mesh Orb，并在折叠/展开两种窗口尺寸上调帧。

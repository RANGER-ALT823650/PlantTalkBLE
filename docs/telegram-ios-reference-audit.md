# Telegram iOS 源码对照审计

更新日期：2026-07-10

## 参考范围

- 官方仓库：[`TelegramMessenger/Telegram-iOS`](https://github.com/TelegramMessenger/Telegram-iOS)
- 检查提交：[`6e370e06d147b091b07903071cb1b8a22152492d`](https://github.com/TelegramMessenger/Telegram-iOS/commit/6e370e06d147b091b07903071cb1b8a22152492d)
- 提交日期：2026-06-05
- 本地只读稀疏检出：`/tmp/telegram-ios-reference`
- Plant Talk 对照文件：`Software build preference.md`、`ContentView.swift`、`TextConversationView.swift`

Telegram iOS 是基于 UIKit、AsyncDisplayKit/Texture、自定义列表和手工布局的大型工程。本次只吸收适用于 Plant Talk 的交互与状态管理机制，没有引入 Telegram 模块，也没有逐段复制其实现。

## 偏好逐项检查

| 偏好 | Telegram 对应实现 | 结论 | Plant Talk 处理 |
|---|---|---|---|
| SwiftUI 与可复用组件 | Telegram 将输入面板、气泡、背景、活动状态和消息过渡拆成独立模块，但主要使用 UIKit/ASDisplayNode | 采用组件边界，拒绝框架替换 | 继续使用小型 SwiftUI 组件；不引入 AsyncDisplayKit |
| 简洁且不可滚动的主页面 | Telegram 聊天架构没有对应的植物主页面 | 不适用 | 保留 `HomeDashboard` 当前结构 |
| 唯一文字对话入口 | Telegram 由 `ChatControllerNode` 统一拥有输入面板和发送链 | 已符合 | 保留主页面输入框到唯一 `TextConversationView` 的路径 |
| 指定工具栏位置 | Telegram 导航结构服务于完整即时通讯产品，与本项目工具栏目标不同 | 不适用 | 保留左侧历史、右侧蓝牙和设置 |
| Liquid Glass 与深浅色 | Telegram 使用 `GlassBackgroundContainerView` 和显式主题状态；输入面板按整体暗色外观更新 | 部分参考 | SwiftUI 原生 `glassEffect` 和系统动态颜色更简洁，不替换 |
| 空间连续的发送动画 | Telegram 为消息生成 correlation ID，发送前截取输入背景和文字；目标消息出现后才开始 0.3 秒过渡 | 采用 | 使用稳定 UUID、共享文字源、0.3 秒快速减速曲线和短生命周期过渡状态 |
| 内容自适应气泡 | Telegram 先测量文字，再用内容宽度、内边距和最大可用宽度计算气泡 | 已符合 | 保留固有尺寸 `VStack`、最大可用空间换行和尾部最小留白 |
| 键盘及等待状态 | Telegram 将输入活动和消息内容分离为独立节点，只更新发生变化的节点 | 采用 | 将流式 assistant 从主消息数组隔离，顶部三点思考状态继续独立显示 |
| 以实际参考动态为准 | Telegram 源码和用户录屏均显示：输入快照先保留，背景与文字分层过渡，时间信息稍后淡入 | 采用 | 缩短运动时长，并让时间信息延后淡入 |

## 关键源码证据

1. **稳定 correlation ID 与输入快照**  
   Telegram 在发送前为消息添加 correlation ID，并调用 `makeSnapshotForTransition()` 保存输入面板背景、文字内容、全局位置和滚动偏移，然后注册到消息过渡节点：  
   [`ChatControllerNode.swift#L4985-L5003`](https://github.com/TelegramMessenger/Telegram-iOS/blob/6e370e06d147b091b07903071cb1b8a22152492d/submodules/TelegramUI/Sources/ChatControllerNode.swift#L4985-L5003)  
   [`ChatTextInputPanelNode.swift#L5681-L5709`](https://github.com/TelegramMessenger/Telegram-iOS/blob/6e370e06d147b091b07903071cb1b8a22152492d/submodules/TelegramUI/Components/Chat/ChatTextInputPanelNode/Sources/ChatTextInputPanelNode.swift#L5681-L5709)

2. **目标消息出现后启动专用动画**  
   过渡节点保存 correlation ID；只有列表找到对应目标消息后才调用 `beginAnimation`，避免在目标尺寸和位置尚未确定时猜测终点：  
   [`ChatMessageTransitionNode.swift#L1089-L1130`](https://github.com/TelegramMessenger/Telegram-iOS/blob/6e370e06d147b091b07903071cb1b8a22152492d/submodules/TelegramUI/Sources/ChatMessageTransitionNode.swift#L1089-L1130)

3. **0.3 秒、横纵方向独立缓动**  
   Telegram 的文字消息发送过渡时长为 0.3 秒，并为横向和纵向设置不同的快速减速曲线：  
   [`ChatMessageTransitionNode.swift#L164-L180`](https://github.com/TelegramMessenger/Telegram-iOS/blob/6e370e06d147b091b07903071cb1b8a22152492d/submodules/TelegramUI/Sources/ChatMessageTransitionNode.swift#L164-L180)  
   [`ChatMessageTransitionNode.swift#L527-L559`](https://github.com/TelegramMessenger/Telegram-iOS/blob/6e370e06d147b091b07903071cb1b8a22152492d/submodules/TelegramUI/Sources/ChatMessageTransitionNode.swift#L527-L559)

4. **取消普通插入动画，分层处理背景、文字和状态**  
   Telegram 先取消目标消息节点原有插入动画，再单独处理输入背景、文字和状态信息。输入快照快速淡出，目标文字快速淡入，时间/状态稍后出现：  
   [`ChatMessageBubbleItemNode.swift#L1010-L1042`](https://github.com/TelegramMessenger/Telegram-iOS/blob/6e370e06d147b091b07903071cb1b8a22152492d/submodules/TelegramUI/Components/Chat/ChatMessageBubbleItemNode/Sources/ChatMessageBubbleItemNode.swift#L1010-L1042)  
   [`ChatMessageTextBubbleContentNode.swift#L1736-L1761`](https://github.com/TelegramMessenger/Telegram-iOS/blob/6e370e06d147b091b07903071cb1b8a22152492d/submodules/TelegramUI/Components/Chat/ChatMessageTextBubbleContentNode/Sources/ChatMessageTextBubbleContentNode.swift#L1736-L1761)

5. **气泡宽度由内容和可用宽度共同决定**  
   Telegram 先计算最大内容宽度，再使用实际内容宽度、标题宽度和内边距得到最终气泡尺寸：  
   [`ChatMessageBubbleItemNode.swift#L1938-L1964`](https://github.com/TelegramMessenger/Telegram-iOS/blob/6e370e06d147b091b07903071cb1b8a22152492d/submodules/TelegramUI/Components/Chat/ChatMessageBubbleItemNode/Sources/ChatMessageBubbleItemNode.swift#L1938-L1964)  
   [`ChatMessageBubbleItemNode.swift#L3584-L3605`](https://github.com/TelegramMessenger/Telegram-iOS/blob/6e370e06d147b091b07903071cb1b8a22152492d/submodules/TelegramUI/Components/Chat/ChatMessageBubbleItemNode/Sources/ChatMessageBubbleItemNode.swift#L3584-L3605)

6. **稳定列表 diff 与动画期间的定向更新**  
   Telegram 使用稳定列表合并，只更新变化项；消息仍在过渡时延迟部分内容更新，避免动画中重新布局：  
   [`PreparedChatHistoryViewTransition.swift#L11-L64`](https://github.com/TelegramMessenger/Telegram-iOS/blob/6e370e06d147b091b07903071cb1b8a22152492d/submodules/TelegramUI/Sources/PreparedChatHistoryViewTransition.swift#L11-L64)

## 已实施改进

1. 将后续消息的发送过渡由 0.5 秒弹簧改为 0.3 秒快速减速曲线；首次消息使用相同节奏。
2. 保留稳定 UUID 作为输入文字与目标消息之间的关联标识，过渡清理时间由 560 ms 缩短为 360 ms。
3. 时间信息不再与文字同时突兀出现，而是在目标气泡进入后用 0.25 秒淡入。
4. 新增 `StreamingAssistantState`：流式 token 不再反复修改并筛选整个 `messages` 数组，只刷新当前 assistant 行。
5. 流式回复首段出现时平滑滚动一次；后续 token 使用无动画定位，避免大量 0.2 秒滚动动画互相叠加。
6. 回复完成或中断后，以无动画事务将独立流式消息并入稳定消息数组，保持数据库语义和显示位置不变。

## 未采用或未替换

- **AsyncDisplayKit/Texture 与自定义 ListView**：对 Telegram 的海量消息、媒体和复杂 cell 有价值，但会显著增加 Plant Talk 的依赖、维护成本和 UIKit 桥接，不适合当前规模。
- **手工 CGRect 气泡布局**：Telegram 需要精确处理多媒体、回复、反应和成组消息；Plant Talk 的文字气泡使用 SwiftUI 固有尺寸即可获得更少代码和动态字体支持。
- **完整 Telegram 主题系统**：本项目使用系统语义颜色和原生 Liquid Glass，更自然地适配 iOS 深浅色模式。
- **直接复制 Telegram 代码**：官方 README 明确要求使用源码时遵守相关许可并公开衍生代码。本次只对照公开实现并用 SwiftUI 重新表达所需机制，没有引入 Telegram 源文件。

## 验证

- iPhone 17 / iOS 26.5 模拟器目标：构建成功。
- 现有单元测试：12 项通过，0 失败。
- 尚无 Instruments 或真机帧时间数据，因此“更高效率”的结论属于代码结构证据：每个 token 的数组写入、全量过滤和重复滚动动画已被移除；最终帧率仍应在真机 Release 构建中复测。

# Plant Talk 项目架构分析报告

本报告结合项目实际代码文件，详细分析了 **Plant Talk** 的整体系统架构与工作流程。

---

## 1. 整体架构概述

**Plant Talk** 是一个使人类能够通过语音与植物（拥有个性、传感器数据和视觉感知）进行交互的软硬件结合项目。它的设计体现了 **端云协同**、**低延迟实时交互** 以及 **高安全性** 的原则。

整体架构主要由以下三个层次组成：

1. **硬件与传感器层 (Hardware & Sensors)**
   - 运行在 Arduino 等微控制器上的固件，定期采集土壤湿度与环境光线数据，通过 USB 串口传输给客户端。
2. **前端客户端层 (React SPA Client)**
   - 基于 React、Vite、Zustand 和 Pico.css 构建的单页面应用。它通过 Web Serial API 连接硬件，通过 WebRTC 直接对接 OpenAI Realtime API，并使用 IndexedDB 持久化植物的历史“记忆”（观察记录）。
3. **后端服务层 (Express Server)**
   - 一个轻量级的 Node.js Express 服务。它的核心职责是保管 `OPENAI_API_KEY`（确保 Key 不泄露给浏览器），提供图像分析及观察接口，并为前端 mint（生成）用于 WebRTC 的短期安全 Token。

---

## 2. 系统关系与数据流拓扑图 (Mermaid)

下面是描述该项目各模块关系、数据流动及协议交互的架构图：

```mermaid
graph TD
    %% User and Physical World
    User([User - 用户]) <--> |Webcam, Mic, Audio| Browser["Frontend Client App (Browser)<br/>React / Vite / Zustand"]
    Plant[Physical Plant - 实体植物] --> |Physical Properties| Sensors[Sensors - 传感器]
    Sensors --> |Analog/Digital Signals| Arduino["Arduino MCU<br/>(PlantSensors.ino)"]
    User -.-> |Watering & Care - 浇水养护| Plant

    %% Hardware & Browser Connection
    Arduino --> |Serial over USB (115200 baud)<br/>JSON: moisture, light| BrowserStoreSensors["sensors-store.ts<br/>(Web Serial API)"]

    %% Browser App Internals
    subgraph BrowserClient ["Frontend Client App (React SPA)"]
        BrowserStoreSensors
        BrowserStoreCamera["camera-store.ts<br/>(Webcam Capture)"]
        BrowserStoreMicrophone["microphone-store.ts<br/>(Audio Input)"]
        BrowserStoreUi["ui-mode-store.ts<br/>(Dashboard / Ambient Mode)"]
        BrowserStoreObserver["observer-store.ts<br/>(IndexedDB Memory)"]
        BrowserStoreLoop["observation-loop-store.ts<br/>(Periodic Loop)"]
        BrowserStoreConv["conversation-store.ts<br/>(Voice State Manager)"]
        
        BrowserConnection["realtime-connection.ts<br/>(WebRTC Connection)"]
        BrowserTools["realtime-tools.ts<br/>(Client-side Senses)"]
    end

    %% Backend Server
    subgraph ExpressServer ["Express Backend Server"]
        ServerIndex["index.ts - Express App"]
        ServerObserve["observe.ts - Observation API"]
        ServerRealtime["realtime.ts - WebRTC Token API"]
        ServerOpenAI["openai.ts - OpenAI SDK Client"]
    end

    %% External APIs
    subgraph OpenAICloud ["OpenAI Cloud API"]
        OpenAIVision["GPT-5.4 Vision Models<br/>(Structure Analysis & Stream)"]
        OpenAIRealtime["OpenAI Realtime API<br/>(WebRTC Voice Stream)"]
    end

    %% Connections to Backend
    BrowserStoreLoop --> |"POST /api/observe<br/>(frame, sensors, history)"| ServerIndex
    BrowserStoreConv --> |"POST /api/realtime-token<br/>(mint client secret)"| ServerIndex

    ServerIndex --> |routes request| ServerObserve
    ServerIndex --> |routes request| ServerRealtime
    
    ServerObserve --> |OpenAI client| ServerOpenAI
    ServerRealtime --> |OpenAI client| ServerOpenAI
    
    ServerOpenAI --> |HTTPS Request| OpenAIVision
    ServerOpenAI --> |Mint Token Request| OpenAIRealtime

    %% Realtime Direct WebRTC Connection
    ServerRealtime --> |"return clientSecret (ek_...)"| BrowserStoreConv
    BrowserStoreConv --> |instantiate| BrowserConnection
    BrowserConnection <--> |"WebRTC MediaStream & DataChannel<br/>(audio, JSON events)"| OpenAIRealtime
    
    %% Tools / Senses loop
    OpenAIRealtime -.-> |"server event: function_call<br/>(get_current_sensors)"| BrowserConnection
    BrowserConnection -.-> |execute| BrowserTools
    BrowserTools -.-> |read sensors| BrowserStoreSensors
    BrowserTools -.-> |read memory| BrowserStoreObserver
    BrowserTools -.-> |"return JSON string<br/>(function_call_output)"| BrowserConnection
    BrowserConnection -.-> |"client event: conversation.item.create"| OpenAIRealtime

    %% Loop stores observations
    BrowserStoreLoop --> |commit observation| BrowserStoreObserver
```

---

## 3. 核心层次与文件细化分析

### 3.1 硬件与固件层 (`/arduino`)

- **[PlantSensors.ino](file:///Users/mayifan/Documents/plant_talk_clone/arduino/PlantSensors/PlantSensors.ino)**
  - **传感器数据采集**：连接一个电容式土壤湿度传感器（模拟信号 A0）和一个光敏电阻传感器（数字信号 D8）。
  - **滤波与归一化**：每次采样 16 次求平均以平滑振荡器抖动。通过硬编码的 `AIR_VALUE`（空气中读数）与 `WATER_VALUE`（水中读数）将湿度阻值归一化为 0.0 - 1.0 的浮点数。
  - **串行输出**：以 `115200` 波特率向串口输出一行精简的 JSON：`{"moisture":0.42,"light":1.00}`。
  - **命令交互**：支持通过串口接收指令，如 `interval <ms>`（设置上报频率）、`read`（立即读取）、`calibrate`（进入快速原始 ADC 采样校准模式）以及 `status`（查询当前校准点参数）。

### 3.2 后端服务层 (`/server`)

- **[index.ts](file:///Users/mayifan/Documents/plant_talk_clone/server/index.ts)**
  - 启动 Express 服务，监听端口 `3001`（开发环境下由 Vite 的 `3000` 端口代理 `/api/*` 请求，生产环境下直接托管 `dist/` 静态资源目录）。
  - 配置了高达 `12mb` 的 JSON body 限制以容纳前端上传的 Base64 格式高清摄像头帧。
- **[observe.ts](file:///Users/mayifan/Documents/plant_talk_clone/server/observe.ts)**
  - `POST /api/analyze`：分析单张上传的图片，返回结构化的植物属性（干燥度、可见跨度大小、分枝度、表面质感描述等）。
  - `POST /api/observe`：结合当前传感器值、前置硬件状态摘要和 IndexedDB 中的历史观察日志，调用 Vision 模型做周期性分析。支持**流式传输推理摘要 (stream reasoning summary)**，利用 NDJSON 格式实时向前端吐出模型的思维 delta。
- **[realtime.ts](file:///Users/mayifan/Documents/plant_talk_clone/server/realtime.ts)**
  - `POST /api/realtime-token`：调用 OpenAI API，为前端 WebRTC 链接申请一个有效期为 600 秒的临时客户端密钥 (`client_secret`，以 `ek_` 开头)。
  - **安全核心**：在 mint 密钥时，后端会直接将 `session` 的硬性配置（模型版本、系统级 instructions、允许调用的 tools、转录配置、VAD 语音活动检测配置）绑定在 Token 上。前端浏览器只能使用此 Token 建立连接，无法篡改这些底层配置（防止用户通过前端注入控制 API 造成滥用或篡改植物人格）。
- **[openai.ts](file:///Users/mayifan/Documents/plant_talk_clone/server/openai.ts)**
  - 延迟初始化 OpenAI SDK 客户端。在 API 密钥缺失时会进行警告，但不阻碍 Express 正常引导，增强了开发调试体验。

### 3.3 前端客户端层 (`/src`)

#### 3.3.1 状态管理与数据总线 (Zustand Stores)
前端应用的行为高度状态化，由一系列分工明确的 Zustand 仓库驱动：

1. **[sensors-store.ts](file:///Users/mayifan/Documents/plant_talk_clone/src/stores/plant/sensors-store.ts)**：
   - 使用浏览器 **Web Serial API** (`navigator.serial`) 管理与 Arduino 串口的连接。
   - 解析来自串口的原始 JSON、CSV 或 Key-Value 格式，处理重连机制（支持 USB 热插拔事件检测）与看门狗机制（在数据卡死时触发重连）。
   - 如果未连接硬件，自动降级为手动滑动条 (`fallbackReadings`)，确保应用在纯软件模式下依然可用。
2. **[camera-store.ts](file:///Users/mayifan/Documents/plant_talk_clone/src/stores/plant/camera-store.ts)**：
   - 调用 `getUserMedia` 获取网络摄像头媒体流，管理摄像头状态（就绪、启动中、不支持、错误）。
   - 为多次截图或仪表盘画面预览提供统一的媒体轨道实例。
3. **[observer-store.ts](file:///Users/mayifan/Documents/plant_talk_clone/src/stores/plant/observer-store.ts)**：
   - 将植物的历史观察记录（干燥度、健康趋势、观测文本描述）通过 `idb-keyval` 自动同步持久化到浏览器的 **IndexedDB** 数据库。
   - **Prompt 缩减算法**：为避免漫长的历史记录撑爆 LLM 上下文，设计了 `selectObservationsForPrompt` 算法，在生成 prompt 时提取最近的 5 条记录与时间跨度内均匀稀疏分布的 6 条老记录，既保证了时效性，又保留了长期大趋势的感知，同时节省了 API 费用。
4. **[observation-loop-store.ts](file:///Users/mayifan/Documents/plant_talk_clone/src/stores/plant/observation-loop-store.ts)**：
   - 自动更新循环的控制中枢。当开启自动更新时，在设定的时间间隔内截图并读取当前传感器快照发送到 `/api/observe`。
   - 包含流式解析流推理事件的去重与渲染逻辑。
   - **指数退避重试 (Exponential Backoff)**：监测 429 等速率限制错误，自动暂停自动循环并实施退避时间，防止恶意消耗。
5. **[conversation-store.ts](file:///Users/mayifan/Documents/plant_talk_clone/src/stores/plant/conversation-store.ts)**：
   - 挂载 `RealtimeVoiceConnection`。管理语音交互的全局 UI 状态（静音、说话状态、文字转录对话流、工具活动日志等）。

#### 3.3.2 核心网络组件 (Libraries)

- **[realtime-connection.ts](file:///Users/mayifan/Documents/plant_talk_clone/src/lib/plant/realtime-connection.ts)**
  - 纯原生 JS/TS 实现的 WebRTC 通信类。
  - **协商握手**：首先向 Express 后端申请 `ek_` Token，接着生成本地 SDP Offer 并向 OpenAI WebRTC 入口 `https://api.openai.com/v1/realtime/calls` 发送请求换取 Answer。
  - **语音通道**：将麦克风 AudioTrack 推送至 RTCPeerConnection，并在 `ontrack` 中接收远端（植物）语音并绑定至 `<audio>` 标签。
  - **数据通道**：创建 `oai-events` 数据通道，通过接收 `conversation.item.input_audio_transcription.completed` 等事件实现双向文字转录流，并在空闲时间（60秒无任何说话）后自动挂断连接。
  - **工具拦截执行 (Function Call)**：当听到事件 `response.output_item.done` (类型为 `function_call`) 时，它将在本地拦截并调用 `realtime-tools.ts` 执行。
- **[realtime-tools.ts](file:///Users/mayifan/Documents/plant_talk_clone/src/lib/plant/realtime-tools.ts)**
  - 实现 Realtime API 声明的植物“感官”。
  - `get_current_sensors`：当用户询问植物状态时，模型自动调用该函数，此脚本会越过模型直接读取 `sensors-store.ts` 的当前真实水分与光照，并将其结构化为 JSON 吐回给模型。
  - `get_observation_history`：当用户询问过去的一周情况时，此函数越过模型去读取 `observer-store.ts` 的 IndexedDB 汇总数据。

---

## 4. 关键工作流解析

### 工作流 A：周期性植物观察循环 (Observation Loop)
```
[前端定时触发器] ──> [camera-store: 捕获摄像头帧]
                          │
                          ▼
                     [sensors-store: 读取当前传感器值]
                          │
                          ▼
                     [observer-store: 获取历史记录子集]
                          │
                          ▼
                     [上传 Base64 图像及数据至 /api/observe]
                          │
                          ▼
                     [后端服务: 调用 OpenAI GPT-5.4 Vision API]
                          │
     ┌────────────────────┴────────────────────┐
     ▼ (NDJSON 流式推理阶段)                     ▼ (最终 JSON 输出阶段)
[接收流式推理思考过程 Delta]                 [将本次观察结果存入 IndexedDB 数据库]
     │                                         │
     ▼                                         ▼
[更新仪表盘上的“植物思考中” UI]              [渲染更新植物状态与健康趋势]
```

### 工作流 B：实时语音交互与“心电感应” (Realtime Voice & Tool Use)
```
[用户提问: "George，你渴了吗？"]
      │
      ▼ (由 WebRTC 媒体流音频捕获)
[OpenAI Realtime API 云端]
      │
      ▼ (云端模型决策，判断需要读取传感器数据)
[服务端事件: response.output_item.done (执行函数调用: get_current_sensors)]
      │
      ▼ (通过 WebRTC Data Channel 数据通道送达浏览器)
[浏览器 realtime-tools.ts: 读取 Zustand 传感器状态仓]
      │
      ▼ (返回 JSON 字符串: {"moisturePercent": 42})
[客户端事件: conversation.item.create (提交 function_call_output 结果)]
      │
      ▼ (通过 WebRTC Data Channel 传回 OpenAI 云端)
[OpenAI Realtime: 结合最新的传感器数据上下文生成语音回复]
      │
      ▼ (语音流式音频输出)
[用户听到: "等下，让我感受一下我的根... 噢，42%，太舒服了。水刚刚好。"]
```


---

## 5. 项目架构亮点

1. **隐私与 Key 的隔离保护**：
   - 前端无需加载任何持久的 OpenAI API 密钥。所有的密钥控制均放置在后端 Express 中。即使是实时语音交互（需要直连 OpenAI 以保证超低延迟），也使用后端作为中介动态生成一次性的 `ek_` Ephemeral Token，这是一种标准的生产级安全实践。
2. **纯浏览器端的重度业务逻辑**：
   - 项目将大量的传感器数据管理、历史观测存档（IndexedDB 级）、摄像头控制以及 WebRTC 维护都保留在前端。后端在完成简单的 Token 桥接和 Vision 模型解析转发后，几乎是完全无状态的，极大降低了服务器负担。
3. **极佳的降级体验**：
   - 从 Arduino 硬件、看门狗重连、到无硬件时的手动滑动条模式，代码中做了非常全面的 Fallback（回退）处理，使得项目在有无传感器硬件的场景下均能丝滑运行。

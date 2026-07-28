import SwiftUI
import UIKit

struct AppSettingsView: View {
    let database: PlantDatabase
    let memoryStore: PlantMemoryStore
    @AppStorage("appTheme") private var appTheme: AppTheme = .blue
    @State private var isDeletingHistory = false
    @State private var historyAlert: HistoryAlert?

    private enum HistoryAlert: Identifiable {
        case deleteConfirmation
        case result(String)

        var id: String {
            switch self {
            case .deleteConfirmation:
                "deleteConfirmation"
            case .result:
                "result"
            }
        }
    }

    var body: some View {
        List {
            Section {
                Picker("主题颜色", selection: $appTheme) {
                    ForEach(AppTheme.allCases) { theme in
                        Label {
                            Text(theme.title)
                        } icon: {
                            theme.swatchImage
                        }
                        .tag(theme)
                    }
                }
                .pickerStyle(.menu)

                NavigationLink {
                    AISettingsView(memoryStore: memoryStore)
                } label: {
                    Label("大模型设置", systemImage: "cpu")
                }

                NavigationLink {
                    CloudSyncSettingsView(database: database)
                } label: {
                    Label("云同步设置", systemImage: "cloud")
                }
            }

            Section {
                Button(role: .destructive) {
                    historyAlert = .deleteConfirmation
                } label: {
                    Label("删除全部历史记录", systemImage: "trash")
                }
                .disabled(isDeletingHistory)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
        .alert(item: $historyAlert) { alert in
            switch alert {
            case .deleteConfirmation:
                Alert(
                    title: Text("删除全部历史记录？"),
                    message: Text("全部传感器历史、文字对话、实时语音会话和长期记忆都会被永久删除。"),
                    primaryButton: .destructive(Text("全部删除")) {
                        deleteAllHistory()
                    },
                    secondaryButton: .cancel(Text("取消"))
                )
            case .result(let message):
                Alert(
                    title: Text("历史记录"),
                    message: Text(message),
                    dismissButton: .default(Text("好"))
                )
            }
        }
    }

    private func deleteAllHistory() {
        isDeletingHistory = true
        Task {
            do {
                try await database.deleteAllHistory()
                try await memoryStore.clear()
                // 把这些删除也推给其他端，否则下次同步会从云端拉回来
                await CloudSyncService.shared.sync(database: database)
                historyAlert = .result("全部历史记录已删除。")
            } catch {
                historyAlert = .result("删除失败：\(error.localizedDescription)")
            }
            isDeletingHistory = false
        }
    }
}

@MainActor
struct AISettingsView: View {
    let memoryStore: PlantMemoryStore

    @State private var baseURL: String
    @State private var model: String
    @State private var systemPrompt: String
    @State private var realtimeURL: String
    @State private var realtimeModel: String
    @State private var realtimeVoice: String
    @State private var imageGenURL: String
    @State private var imageGenModel: String
    @State private var imageGenPrompt: String
    @State private var chatAPIKey = ""
    @State private var realtimeAPIKey = ""
    @State private var imageGenAPIKey = ""
    @State private var hasSavedChatAPIKey: Bool
    @State private var hasSavedRealtimeAPIKey: Bool
    @State private var hasSavedImageGenAPIKey: Bool
    @State private var hasLegacySharedAPIKey: Bool
    @State private var isChatAPIKeyVisible = false
    @State private var isRealtimeAPIKeyVisible = false
    @State private var isImageGenAPIKeyVisible = false
    @State private var statusMessage: String?
    @State private var isShowingStatus = false
    @FocusState private var focusedField: SettingsField?

    private enum SettingsField: Hashable {
        case chatAPIKey
        case realtimeAPIKey
        case imageGenAPIKey
        case baseURL
        case model
        case realtimeURL
        case realtimeModel
        case imageGenURL
        case imageGenModel
    }

    private enum APIKeyKind {
        case chat
        case realtime
        case imageGen
    }

    private struct RealtimeVoice: Identifiable {
        let id: String
        let title: String
    }

    private static let qwen35RealtimeVoices: [RealtimeVoice] = [
        .init(id: "Tina", title: "甜甜 Tina"),
        .init(id: "Cindy", title: "林欣宜 Cindy"),
        .init(id: "Liora Mira", title: "清欢 Liora Mira"),
        .init(id: "Sunnybobi", title: "知芝 Sunnybobi"),
        .init(id: "Raymond", title: "林川野 Raymond"),
        .init(id: "Ethan", title: "晨煦 Ethan"),
        .init(id: "Theo Calm", title: "予安 Theo Calm"),
        .init(id: "Serena", title: "苏瑶 Serena"),
        .init(id: "Harvey", title: "厚 Harvey"),
        .init(id: "Maia", title: "四月 Maia"),
        .init(id: "Evan", title: "江晨 Evan"),
        .init(id: "Qiao", title: "小乔妹 Qiao"),
        .init(id: "Momo", title: "茉兔 Momo"),
        .init(id: "Wil", title: "伟伦 Wil"),
        .init(id: "Angel", title: "台普 - 安琪 Angel"),
        .init(id: "Li Cassian", title: "东厂 - 李公公 Li Cassian"),
        .init(id: "Mia", title: "温柔生活博主 - 舒然 Mia"),
        .init(id: "Joyner", title: "喜剧担当 - 阿逗 Joyner"),
        .init(id: "Gold", title: "金爷 Gold"),
        .init(id: "Katerina", title: "卡捷琳娜 Katerina"),
        .init(id: "Ryan", title: "甜茶 Ryan"),
        .init(id: "Jennifer", title: "詹妮弗 Jennifer"),
        .init(id: "Aiden", title: "艾登 Aiden"),
        .init(id: "Mione", title: "敏儿 Mione"),
        .init(id: "Sunny", title: "四川 - 晴儿 Sunny"),
        .init(id: "Dylan", title: "北京 - 晓东 Dylan"),
        .init(id: "Eric", title: "四川 - 程川 Eric"),
        .init(id: "Peter", title: "天津 - 李彼得 Peter"),
        .init(id: "Joseph Chen", title: "阿樸伯 Joseph Chen"),
        .init(id: "Marcus", title: "陕西 - 秦川 Marcus"),
        .init(id: "Li", title: "南京 - 老李 Li"),
        .init(id: "Rocky", title: "粤语 - 阿强 Rocky"),
        .init(id: "Sohee", title: "素熙 Sohee"),
        .init(id: "Lenn", title: "莱恩 Lenn"),
        .init(id: "Ono Anna", title: "小野杏 Ono Anna"),
        .init(id: "Sonrisa", title: "索尼莎 Sonrisa"),
        .init(id: "Bodega", title: "博德加 Bodega"),
        .init(id: "Emilien", title: "埃米尔安 Emilien"),
        .init(id: "Andre", title: "安德雷 Andre"),
        .init(id: "Radio Gol", title: "拉迪奥·戈尔 Radio Gol"),
        .init(id: "Alek", title: "阿列克 Alek"),
        .init(id: "Rizky", title: "阿力 Rizky"),
        .init(id: "Roya", title: "萝雅 Roya"),
        .init(id: "Arda", title: "阿尔达 Arda"),
        .init(id: "Hana", title: "阿幸 Hana"),
        .init(id: "Dolce", title: "多尔切 Dolce"),
        .init(id: "Jakub", title: "雅克 Jakub"),
        .init(id: "Griet", title: "海娜 Griet"),
        .init(id: "Eliška", title: "艾莉卡 Eliška"),
        .init(id: "Marina", title: "玛丽娜 Marina"),
        .init(id: "Siiri", title: "西芮 Siiri"),
        .init(id: "Ingrid", title: "林恩 Ingrid"),
        .init(id: "Sigga", title: "海娜 Sigga"),
        .init(id: "Bea", title: "雅娜 Bea"),
        .init(id: "Chloe", title: "思怡 Chloe")
    ]

    init(memoryStore: PlantMemoryStore) {
        self.memoryStore = memoryStore
        _baseURL = State(initialValue: AISettingsStore.baseURLString)
        _model = State(initialValue: AISettingsStore.model)
        _systemPrompt = State(initialValue: AISettingsStore.systemPrompt)
        _realtimeURL = State(initialValue: AISettingsStore.realtimeURLString)
        _realtimeModel = State(initialValue: AISettingsStore.realtimeModel)
        _realtimeVoice = State(initialValue: AISettingsStore.realtimeVoice)
        _imageGenURL = State(initialValue: AISettingsStore.imageGenURLString)
        _imageGenModel = State(initialValue: AISettingsStore.imageGenModel)
        _imageGenPrompt = State(initialValue: AISettingsStore.imageGenPrompt)
        _hasSavedChatAPIKey = State(initialValue: AISettingsStore.hasChatAPIKey())
        _hasSavedRealtimeAPIKey = State(initialValue: AISettingsStore.hasRealtimeAPIKey())
        _hasSavedImageGenAPIKey = State(initialValue: AISettingsStore.hasImageGenAPIKey())
        _hasLegacySharedAPIKey = State(initialValue: AISettingsStore.hasLegacySharedAPIKey())
    }

    var body: some View {
        Form {
            if hasLegacySharedAPIKey {
                Section {
                    Text("检测到旧版共享 API Key。新版已拆分为“文本分析”和“实时语音”两个独立 Key，旧 Key 不再自动用于请求。请分别重新保存 DeepSeek / 千问 Key。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Button("清除旧版共享 API Key", role: .destructive) {
                        clearLegacySharedAPIKey()
                    }
                }
            }

            Section {
                NavigationLink {
                    MemoryDetailView(memoryStore: memoryStore)
                } label: {
                    Label("记忆", systemImage: "brain.head.profile")
                }
            } header: {
                Text("长期记忆")
            } footer: {
                Text("查看并编辑用户画像、植物档案、重要事件和待跟进事项。每条记录都会显示最近更新时间。")
            }

            Section {
                TextField("https://api.example.com/v1", text: $baseURL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focusedField, equals: .baseURL)

                TextField("模型名称", text: $model)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focusedField, equals: .model)

                HStack {
                    apiKeyInput(
                        placeholder: chatAPIKeyPlaceholder,
                        text: $chatAPIKey,
                        isVisible: isChatAPIKeyVisible,
                        focusedField: .chatAPIKey
                    )

                    Button {
                        isChatAPIKeyVisible.toggle()
                    } label: {
                        Image(systemName: isChatAPIKeyVisible ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(isChatAPIKeyVisible ? "隐藏文本分析 API Key" : "显示文本分析 API Key")
                }

                HStack {
                    Button("保存文本 API Key") {
                        saveAPIKeyOnly(.chat)
                    }
                    .disabled(chatAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    Spacer()

                    Button("从剪贴板粘贴") {
                        pasteAPIKey(.chat)
                    }
                }
                .buttonStyle(.borderless)

                if hasSavedChatAPIKey {
                    Button("清除文本分析 API Key", role: .destructive) {
                        clearAPIKey(.chat)
                    }
                }

                Button("使用千问文本默认配置") {
                    applyQwenTextDefaults()
                }
            } header: {
                Text("文本分析（兼容 OpenAI Chat Completions）")
            } footer: {
                Text("这里保存 DeepSeek、OpenAI、千问兼容接口等文本模型的 API Key，只用于文本分析和文字会话。千问文本接口可使用 https://dashscope.aliyuncs.com/compatible-mode/v1；DeepSeek 可使用 https://api.deepseek.com。")
            }

            Section {
                TextField("wss://…/api-ws/v1/realtime", text: $realtimeURL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focusedField, equals: .realtimeURL)

                TextField("实时模型", text: $realtimeModel)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focusedField, equals: .realtimeModel)

                Picker("音色", selection: $realtimeVoice) {
                    ForEach(Self.qwen35RealtimeVoices) { voice in
                        Text(voice.title)
                            .tag(voice.id)
                    }
                }
                .pickerStyle(.menu)

                HStack {
                    apiKeyInput(
                        placeholder: realtimeAPIKeyPlaceholder,
                        text: $realtimeAPIKey,
                        isVisible: isRealtimeAPIKeyVisible,
                        focusedField: .realtimeAPIKey
                    )

                    Button {
                        isRealtimeAPIKeyVisible.toggle()
                    } label: {
                        Image(systemName: isRealtimeAPIKeyVisible ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(isRealtimeAPIKeyVisible ? "隐藏实时语音 API Key" : "显示实时语音 API Key")
                }

                HStack {
                    Button("保存实时 API Key") {
                        saveAPIKeyOnly(.realtime)
                    }
                    .disabled(realtimeAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    Spacer()

                    Button("从剪贴板粘贴") {
                        pasteAPIKey(.realtime)
                    }
                }
                .buttonStyle(.borderless)

                if hasSavedRealtimeAPIKey {
                    Button("清除实时语音 API Key", role: .destructive) {
                        clearAPIKey(.realtime)
                    }
                }

                Button("使用 qwen3.5 Omni 实时默认配置") {
                    applyQwenRealtimeDefaults()
                }
            } header: {
                Text("实时语音对话（千问 / 百炼）")
            } footer: {
                Text("这里必须保存百炼 DASHSCOPE_API_KEY，只用于 qwen3.5-omni-flash-realtime，不会覆盖 DeepSeek 文本 Key。百炼推荐使用包含业务空间 ID 的 WebSocket 地址。")
            }

            Section {
                TextField("https://dashscope.aliyuncs.com/…/generation", text: $imageGenURL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focusedField, equals: .imageGenURL)

                TextField("生图模型（如 qwen-image-edit）", text: $imageGenModel)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focusedField, equals: .imageGenModel)

                HStack {
                    apiKeyInput(
                        placeholder: imageGenAPIKeyPlaceholder,
                        text: $imageGenAPIKey,
                        isVisible: isImageGenAPIKeyVisible,
                        focusedField: .imageGenAPIKey
                    )

                    Button {
                        isImageGenAPIKeyVisible.toggle()
                    } label: {
                        Image(systemName: isImageGenAPIKeyVisible ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(isImageGenAPIKeyVisible ? "隐藏生图 API Key" : "显示生图 API Key")
                }

                HStack {
                    Button("保存生图 API Key") {
                        saveAPIKeyOnly(.imageGen)
                    }
                    .disabled(imageGenAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    Spacer()

                    Button("从剪贴板粘贴") {
                        pasteAPIKey(.imageGen)
                    }
                }
                .buttonStyle(.borderless)

                if hasSavedImageGenAPIKey {
                    Button("清除生图 API Key", role: .destructive) {
                        clearAPIKey(.imageGen)
                    }
                }

                Button("使用千问图像编辑默认配置") {
                    applyQwenImageGenDefaults()
                }
            } header: {
                Text("AI 生图（千问图像编辑 / 图生图）")
            } footer: {
                Text("根据当前植物图片生成新图，走 DashScope multimodal-generation 同步接口。模型可填 qwen-image-edit、qwen-image-edit-plus 等。生图 API Key 留空时会自动复用上方实时语音的 DASHSCOPE_API_KEY。")
            }

            Section {
                TextEditor(text: $imageGenPrompt)
                    .frame(minHeight: 120)
            } header: {
                Text("默认生图提示词")
            } footer: {
                Text("在植物图片编辑页点“AI 生图”时的默认提示词。可在编辑页右上角展开输入框临时自定义，不会覆盖此默认值。")
            }

            Section {
                TextEditor(text: $systemPrompt)
                    .frame(minHeight: 180)
            } header: {
                Text("系统 Prompt（植物人格）")
            } footer: {
                Text("每次请求都会把此 Prompt 作为 system 消息发送。传感器实时数据会作为另一条 system 上下文加入。")
            }

            Section {
                Button("保存设置") {
                    save()
                }
                .frame(maxWidth: .infinity)
            } footer: {
                Text("保存设置会保存 URL、模型、Prompt，以及当前输入框中非空的 API Key。空的 API Key 输入框表示不修改已保存 Key。")
            }
        }
        .navigationTitle("大模型设置")
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        .alert("大模型设置", isPresented: $isShowingStatus) {
            Button("好", role: .cancel) {}
        } message: {
            Text(statusMessage ?? "")
        }
    }

    @ViewBuilder
    private func apiKeyInput(
        placeholder: String,
        text: Binding<String>,
        isVisible: Bool,
        focusedField field: SettingsField
    ) -> some View {
        if isVisible {
            TextField(placeholder, text: text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textContentType(.password)
                .focused($focusedField, equals: field)
        } else {
            SecureField(placeholder, text: text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textContentType(.password)
                .focused($focusedField, equals: field)
        }
    }

    private var chatAPIKeyPlaceholder: String {
        hasSavedChatAPIKey ? "已保存；输入新 Key 可覆盖" : "文本模型 API Key / sk-..."
    }

    private var realtimeAPIKeyPlaceholder: String {
        hasSavedRealtimeAPIKey ? "已保存；输入新 Key 可覆盖" : "DASHSCOPE_API_KEY / sk-..."
    }

    private var imageGenAPIKeyPlaceholder: String {
        hasSavedImageGenAPIKey ? "已保存；输入新 Key 可覆盖" : "留空则复用实时语音 Key"
    }

    private func save() {
        let trimmedBaseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsedURL = URL(string: trimmedBaseURL),
              let scheme = parsedURL.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              parsedURL.host != nil else {
            showStatus(AIConfigurationError.invalidBaseURL.localizedDescription)
            return
        }
        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            showStatus(AIConfigurationError.missingModel.localizedDescription)
            return
        }
        let trimmedRealtimeURL = realtimeURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsedRealtimeURL = URL(string: trimmedRealtimeURL),
              let realtimeScheme = parsedRealtimeURL.scheme?.lowercased(),
              ["ws", "wss"].contains(realtimeScheme),
              parsedRealtimeURL.host != nil else {
            showStatus(AIConfigurationError.invalidRealtimeURL.localizedDescription)
            return
        }
        guard !realtimeModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            showStatus(AIConfigurationError.missingRealtimeModel.localizedDescription)
            return
        }
        guard !realtimeVoice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            showStatus(AIConfigurationError.missingVoice.localizedDescription)
            return
        }
        let trimmedImageGenURL = imageGenURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedImageGenURL.isEmpty {
            guard let parsedImageGenURL = URL(string: trimmedImageGenURL),
                  let imageGenScheme = parsedImageGenURL.scheme?.lowercased(),
                  ["http", "https"].contains(imageGenScheme),
                  parsedImageGenURL.host != nil else {
                showStatus(AIConfigurationError.invalidImageGenURL.localizedDescription)
                return
            }
        }

        do {
            AISettingsStore.savePreferences(
                baseURL: trimmedBaseURL,
                model: model,
                systemPrompt: systemPrompt,
                realtimeURL: trimmedRealtimeURL,
                realtimeModel: realtimeModel,
                realtimeVoice: realtimeVoice,
                imageGenURL: trimmedImageGenURL.isEmpty
                    ? AISettingsStore.defaultImageGenURL
                    : trimmedImageGenURL,
                imageGenModel: imageGenModel,
                imageGenPrompt: imageGenPrompt
            )

            var savedKeys: [String] = []
            if !chatAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try AISettingsStore.saveChatAPIKey(chatAPIKey)
                chatAPIKey = ""
                hasSavedChatAPIKey = true
                savedKeys.append("文本分析 API Key")
            }
            if !realtimeAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try AISettingsStore.saveRealtimeAPIKey(realtimeAPIKey)
                realtimeAPIKey = ""
                hasSavedRealtimeAPIKey = true
                savedKeys.append("实时语音 API Key")
            }
            if !imageGenAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try AISettingsStore.saveImageGenAPIKey(imageGenAPIKey)
                imageGenAPIKey = ""
                hasSavedImageGenAPIKey = true
                savedKeys.append("生图 API Key")
            }

            focusedField = nil
            if savedKeys.isEmpty {
                showStatus("设置已保存。API Key 未变更。")
            } else {
                showStatus("设置已保存，并已更新\(savedKeys.joined(separator: "、"))。")
            }
        } catch {
            showStatus(error.localizedDescription)
        }
    }

    private func saveAPIKeyOnly(_ kind: APIKeyKind) {
        do {
            switch kind {
            case .chat:
                try AISettingsStore.saveChatAPIKey(chatAPIKey)
                chatAPIKey = ""
                hasSavedChatAPIKey = true
                focusedField = nil
                showStatus("文本分析 API Key 已保存到本机 Keychain。")
            case .realtime:
                try AISettingsStore.saveRealtimeAPIKey(realtimeAPIKey)
                realtimeAPIKey = ""
                hasSavedRealtimeAPIKey = true
                focusedField = nil
                showStatus("实时语音 API Key 已保存到本机 Keychain。")
            case .imageGen:
                try AISettingsStore.saveImageGenAPIKey(imageGenAPIKey)
                imageGenAPIKey = ""
                hasSavedImageGenAPIKey = true
                focusedField = nil
                showStatus("生图 API Key 已保存到本机 Keychain。")
            }
        } catch {
            showStatus(error.localizedDescription)
        }
    }

    private func pasteAPIKey(_ kind: APIKeyKind) {
        guard let pasted = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines),
              !pasted.isEmpty else {
            showStatus("剪贴板里没有可粘贴的 API Key。")
            return
        }

        switch kind {
        case .chat:
            chatAPIKey = pasted
            focusedField = .chatAPIKey
        case .realtime:
            realtimeAPIKey = pasted
            focusedField = .realtimeAPIKey
        case .imageGen:
            imageGenAPIKey = pasted
            focusedField = .imageGenAPIKey
        }
    }

    private func applyQwenTextDefaults() {
        baseURL = "https://dashscope.aliyuncs.com/compatible-mode/v1"
        model = "qwen-plus"
    }

    private func applyQwenRealtimeDefaults() {
        realtimeURL = AISettingsStore.defaultRealtimeURL
        realtimeModel = AISettingsStore.defaultRealtimeModel
        realtimeVoice = AISettingsStore.defaultRealtimeVoice
    }

    private func applyQwenImageGenDefaults() {
        imageGenURL = AISettingsStore.defaultImageGenURL
        imageGenModel = "qwen-image-edit"
    }

    private func clearAPIKey(_ kind: APIKeyKind) {
        do {
            switch kind {
            case .chat:
                try AISettingsStore.deleteChatAPIKey()
                chatAPIKey = ""
                hasSavedChatAPIKey = false
                showStatus("文本分析 API Key 已从本机 Keychain 清除。")
            case .realtime:
                try AISettingsStore.deleteRealtimeAPIKey()
                realtimeAPIKey = ""
                hasSavedRealtimeAPIKey = false
                showStatus("实时语音 API Key 已从本机 Keychain 清除。")
            case .imageGen:
                try AISettingsStore.deleteImageGenAPIKey()
                imageGenAPIKey = ""
                hasSavedImageGenAPIKey = false
                showStatus("生图 API Key 已从本机 Keychain 清除。")
            }
        } catch {
            showStatus(error.localizedDescription)
        }
    }

    private func clearLegacySharedAPIKey() {
        do {
            try AISettingsStore.deleteLegacySharedAPIKey()
            hasLegacySharedAPIKey = false
            showStatus("旧版共享 API Key 已清除。请分别保存文本分析和实时语音 API Key。")
        } catch {
            showStatus(error.localizedDescription)
        }
    }

    private func showStatus(_ message: String) {
        statusMessage = message
        isShowingStatus = true
    }
}

struct CloudSyncSettingsView: View {
    let database: PlantDatabase
    @AppStorage("plant_talk_cloud_sync_url") private var syncURL: String = ""
    @AppStorage("plant_talk_cloud_sync_token") private var syncToken: String = ""
    @AppStorage(PlantRemoteSampling.deviceIDDefaultsKey) private var remoteDeviceID: String = ""
    @StateObject private var syncService = CloudSyncService.shared

    var body: some View {
        Form {
            Section {
                TextField("https://<FC域名>.fcapp.run", text: $syncURL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            } header: {
                Text("阿里云 FC 函数公网 URL")
            } footer: {
                Text("在函数计算 FC 3.0 控制台的【触发器管理】中复制 HTTP 触发器的公网 URL。")
            }

            Section {
                SecureField("鉴权密钥 (x-auth-token)", text: $syncToken)
            } header: {
                Text("同步密钥")
            } footer: {
                Text("云端已强制校验 AUTH_TOKEN。请填写与 FC 环境变量 AUTH_TOKEN 完全一致的值，否则所有同步请求都会被拒绝。")
            }

            Section {
                TextField(PlantRemoteSampling.fallbackDeviceID, text: $remoteDeviceID)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            } header: {
                Text("远程采样设备 ID")
            } footer: {
                // 这个值不能沿用蓝牙的设备标识：蓝牙那个是 CoreBluetooth 分配的
                // peripheral UUID，只有 iOS 知道，ESP32 无从得知。两端必须约定
                // 同一个字符串，否则指令投给了一个设备、硬件在另一个设备名下轮询。
                Text("必须与 ESP32 固件 CloudConfig.h 里的 PLANT_CLOUD_DEVICE_ID 完全一致，远程采样才能送达。留空则使用 \(PlantRemoteSampling.fallbackDeviceID)。")
            }

            Section {
                Button {
                    Task {
                        await syncService.sync(database: database)
                    }
                } label: {
                    HStack {
                        Label(syncService.isSyncing ? "正在同步…" : "立即同步全部数据", systemImage: "arrow.triangle.2.circlepath")
                        if syncService.isSyncing {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(syncURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || syncService.isSyncing)

                if let lastSyncedAt = syncService.lastSyncedAt {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("上次同步成功")
                            Spacer()
                            Text(lastSyncedAt.formatted(date: .abbreviated, time: .shortened))
                                .foregroundStyle(.secondary)
                        }
                        if let summary = syncService.lastSyncSummary {
                            Text(summary)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(.caption)
                }

                if let lastError = syncService.lastError {
                    Text("同步失败: \(lastError)")
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                if let lastWarning = syncService.lastWarning {
                    Text(lastWarning)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
        .navigationTitle("云同步设置")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationStack {
        AISettingsView(memoryStore: PlantMemoryStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("plant-memory-preview.json")
        ))
    }
}

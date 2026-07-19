import SwiftUI
import UIKit

enum AppTheme: String, CaseIterable, Identifiable {
    case blue
    case green
    case yellow
    case pink
    case orange
    case purple

    var id: Self { self }

    var title: String {
        switch self {
        case .blue: "蓝色"
        case .green: "绿色"
        case .yellow: "黄色"
        case .pink: "粉色"
        case .orange: "橙色"
        case .purple: "紫色"
        }
    }

    private var uiColor: UIColor {
        switch self {
        case .blue: .systemBlue
        case .green: .systemGreen
        case .yellow: .systemYellow
        case .pink: .systemPink
        case .orange: .systemOrange
        case .purple: .systemPurple
        }
    }

    var color: Color {
        Color(uiColor: uiColor)
    }

    var swatchImage: Image {
        let circleSize = CGSize(width: 16, height: 16)
        let size = CGSize(width: 26, height: 16)
        let image = UIGraphicsImageRenderer(size: size).image { _ in
            uiColor.setFill()
            UIBezierPath(ovalIn: CGRect(origin: .zero, size: circleSize)).fill()
        }
        return Image(uiImage: image).renderingMode(.original)
    }
}

@main
struct PlantTalkBLEApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("appTheme") private var appTheme: AppTheme = .blue
    @State private var bluetooth: PlantBluetoothManager
    private let database: PlantDatabase
    private let aiClient: OpenAICompatibleClient
    private let memoryStore: PlantMemoryStore
    private let memoryOrganizer: PlantMemoryLaunchOrganizer

    init() {
        do {
            let database = try PlantDatabase.makeDefault()
            let aiClient = OpenAICompatibleClient.live()
            let memoryStore = try PlantMemoryStore.makeDefault()
            self.database = database
            self.aiClient = aiClient
            self.memoryStore = memoryStore
            self.memoryOrganizer = PlantMemoryLaunchOrganizer(
                database: database,
                memoryStore: memoryStore,
                client: aiClient
            )
            _bluetooth = State(initialValue: PlantBluetoothManager(database: database))
        } catch {
            fatalError("无法初始化 Plant Talk：\(error.localizedDescription)")
        }
    }

    var body: some Scene {
        WindowGroup {
#if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--image-preview-harness") {
                TextConversationImageInteractionPreview()
                    .tint(appTheme.color)
                    .accentColor(appTheme.color)
            } else {
                liveRootView
            }
#else
            liveRootView
#endif
        }
    }

    private var liveRootView: some View {
        ContentView(
            bluetooth: bluetooth,
            database: database,
            aiClient: aiClient,
            memoryStore: memoryStore
        )
        .tint(appTheme.color)
        .accentColor(appTheme.color)
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            await memoryOrganizer.organizeWhenActive()
        }
    }
}

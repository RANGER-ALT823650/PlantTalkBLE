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
    @AppStorage("appTheme") private var appTheme: AppTheme = .blue
    @State private var bluetooth: PlantBluetoothManager
    private let database: PlantDatabase
    private let aiClient = OpenAICompatibleClient.live()

    init() {
        do {
            let database = try PlantDatabase.makeDefault()
            self.database = database
            _bluetooth = State(initialValue: PlantBluetoothManager(database: database))
        } catch {
            fatalError("无法初始化 Plant Talk 数据库：\(error.localizedDescription)")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView(
                bluetooth: bluetooth,
                database: database,
                aiClient: aiClient
            )
            .tint(appTheme.color)
            .accentColor(appTheme.color)
        }
    }
}

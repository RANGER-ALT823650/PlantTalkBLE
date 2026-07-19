// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "PlantTalkToolSimulation",
    platforms: [.macOS(.v14)],
    products: [
        .executable(
            name: "plant-talk-deepseek-simulation",
            targets: ["PlantTalkToolSimulation"]
        )
    ],
    dependencies: [
        .package(
            url: "https://github.com/groue/GRDB.swift.git",
            from: "7.11.1"
        )
    ],
    targets: [
        .executableTarget(
            name: "PlantTalkToolSimulation",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift")
            ],
            path: "ios/PlantTalkBLE",
            exclude: [
                "AISettingsView.swift",
                "AnimationDemoView.swift",
                "CameraCaptureView.swift",
                "ContentView.swift",
                "ConversationListView.swift",
                "DayDetailView.swift",
                "DetailView.swift",
                "HistoryOverviewView.swift",
                "HistoryTransferProtocol.swift",
                "Info.plist",
                "PlantBluetoothManager.swift",
                "PlantArtworkView.swift",
                "PlantTalkBLEApp.swift",
                "PreviewAudio",
                "QwenRealtimeConversation.swift",
                "RealtimeAudioIO.swift",
                "RealtimeConversationHistoryView.swift",
                "RealtimeConversationSheet.swift",
                "SensorChartSheet.swift",
                "TextConversationView.swift"
            ],
            sources: [
                "AIConfiguration.swift",
                "ChatModels.swift",
                "DeepSeekToolSimulationMain.swift",
                "OpenAICompatibleClient.swift",
                "PlantBluetoothManagerCLISimulationStub.swift",
                "PlantConversationBinding.swift",
                "PlantDataTools.swift",
                "PlantDatabase.swift",
                "PlantReading.swift"
            ]
        )
    ]
)

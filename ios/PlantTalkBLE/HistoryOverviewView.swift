import SwiftUI
import UIKit

struct HistoryOverviewView: View {
    let database: PlantDatabase
    let onContinueTextConversation: (AIConversation, [ChatMessage]) -> Void
    let onContinueRealtimeConversation: (AIConversation, [ChatMessage]) -> Void
    let onDetailPresentationChanged: (Bool) -> Void
    let onApplyGeneratedImageToPlantCard: (UIImage) -> Void
    @State private var selectedTab: HistoryTab = .sensor

    var body: some View {
        TabView(selection: $selectedTab) {
            DetailView(
                database: database,
                onDetailPresentationChanged: onDetailPresentationChanged
            )
                .tag(HistoryTab.sensor)
                .tabItem {
                    Label("传感器", systemImage: "sensor.tag.radiowaves.forward")
                }

            ConversationListView(
                database: database,
                onContinueConversation: onContinueTextConversation,
                onDetailPresentationChanged: onDetailPresentationChanged
            )
                .tag(HistoryTab.textConversation)
                .tabItem {
                    Label("文字对话", systemImage: "text.bubble")
                }

            RealtimeConversationHistoryView(
                database: database,
                onContinueConversation: onContinueRealtimeConversation,
                onDetailPresentationChanged: onDetailPresentationChanged
            )
                .tag(HistoryTab.realtimeConversation)
                .tabItem {
                    Label("实时语音", systemImage: "waveform")
                }

            GeneratedImageGalleryView(
                onApplyToPlantCard: onApplyGeneratedImageToPlantCard
            )
                .tag(HistoryTab.generatedImages)
                .tabItem {
                    Label("AI 图片", systemImage: "photo.on.rectangle")
                }
        }
        .scrollIndicators(.hidden, axes: .vertical)
    }
}

private enum HistoryTab: Hashable {
    case sensor
    case textConversation
    case realtimeConversation
    case generatedImages
}

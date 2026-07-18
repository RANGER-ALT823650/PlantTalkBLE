import SwiftUI

struct HistoryOverviewView: View {
    let database: PlantDatabase
    @State private var selectedTab: HistoryTab = .sensor

    var body: some View {
        TabView(selection: $selectedTab) {
            DetailView(database: database)
                .tag(HistoryTab.sensor)
                .tabItem {
                    Label("传感器", systemImage: "sensor.tag.radiowaves.forward")
                }

            ConversationListView(database: database)
                .tag(HistoryTab.textConversation)
                .tabItem {
                    Label("文字对话", systemImage: "text.bubble")
                }

            RealtimeConversationHistoryView(database: database)
                .tag(HistoryTab.realtimeConversation)
                .tabItem {
                    Label("实时语音", systemImage: "waveform")
                }
        }
        .scrollIndicators(.hidden, axes: .vertical)
    }
}

private enum HistoryTab: Hashable {
    case sensor
    case textConversation
    case realtimeConversation
}

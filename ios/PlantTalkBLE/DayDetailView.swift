import SwiftUI

/// Shows all sensor readings for a single calendar day.
/// Pushed via NavigationLink from either today's or a past day's summary row.
struct DayDetailView: View {
    let database: PlantDatabase
    let date: Date

    @State private var readings: [HistoryReading] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var readingPendingDeletion: HistoryReading?
    @State private var deletionErrorMessage: String?

    var body: some View {
        Group {
            if isLoading {
                ProgressView("正在读取…")
            } else if let errorMessage {
                ContentUnavailableView(
                    "无法读取记录",
                    systemImage: "exclamationmark.triangle",
                    description: Text(errorMessage)
                )
            } else if readings.isEmpty {
                ContentUnavailableView(
                    "当天无记录",
                    systemImage: "tray",
                    description: Text("该日没有传感器数据。")
                )
            } else {
                List(Array(readings.enumerated()), id: \.element.databaseID) { item in
                    HistoryReadingRow(
                        reading: item.element,
                        itemNumber: item.offset + 1,
                        showDate: false
                    )
                    .contextMenu {
                        Button("删除", systemImage: "trash", role: .destructive) {
                            readingPendingDeletion = item.element
                        }
                    }
                }
                .refreshable {
                    await loadReadings()
                }
            }
        }
        .navigationTitle(formattedTitle)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await loadReadings()
        }
        .confirmationDialog(
            "删除这条传感器记录？",
            isPresented: readingDeletionConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                if let readingPendingDeletion {
                    deleteReading(readingPendingDeletion)
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("这条传感器数据会被永久删除。")
        }
        .alert("删除失败", isPresented: deletionErrorPresented) {
            Button("好", role: .cancel) {}
        } message: {
            Text(deletionErrorMessage ?? "无法删除传感器记录。")
        }
    }

    private var formattedTitle: String {
        sensorHistoryDayTitle(date)
    }

    private func loadReadings() async {
        do {
            readings = try await database.historyReadings(for: date)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private var readingDeletionConfirmationPresented: Binding<Bool> {
        Binding(
            get: { readingPendingDeletion != nil },
            set: { if !$0 { readingPendingDeletion = nil } }
        )
    }

    private var deletionErrorPresented: Binding<Bool> {
        Binding(
            get: { deletionErrorMessage != nil },
            set: { if !$0 { deletionErrorMessage = nil } }
        )
    }

    private func deleteReading(_ reading: HistoryReading) {
        readingPendingDeletion = nil
        guard let id = reading.databaseID else {
            deletionErrorMessage = "无法确定这条传感器记录的数据库编号。"
            return
        }

        Task {
            do {
                try await database.deleteHistoryReading(id: id)
                readings.removeAll { $0.databaseID == id }
            } catch {
                deletionErrorMessage = error.localizedDescription
            }
        }
    }
}

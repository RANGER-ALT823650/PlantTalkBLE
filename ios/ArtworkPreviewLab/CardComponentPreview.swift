import SwiftUI

/// 复刻 PlantArtworkView.swift 里 #Preview("植物卡片组件") 的内容：
/// 空状态下的植物卡片占位组件，居中展示。
struct CardComponentPreview: View {
    var body: some View {
        PlantArtworkPlaceholder(artwork: nil)
            .frame(width: 220)
            .padding(40)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(uiColor: .systemBackground))
    }
}

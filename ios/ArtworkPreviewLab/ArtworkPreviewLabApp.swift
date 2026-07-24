import SwiftUI

// MARK: - 植物图片预览实验台
//
// 把 PlantArtworkView.swift 里那几个原本只能在 Xcode Canvas 里看的
// #Preview 直接打包成一个可装真机的独立 App。用的都是仓库里真实的
// PlantArtworkView.swift / AIConfiguration.swift / PlantImageGenerationClient.swift，
// 所以真机上看到的效果与生产代码 100% 一致。
// ======================================================================

@main
struct ArtworkPreviewLabApp: App {
    var body: some Scene {
        WindowGroup {
            ArtworkPreviewLab()
        }
    }
}

struct ArtworkPreviewLab: View {
    var body: some View {
        TabView {
            GenerationMaskPreview()
                .tabItem {
                    Label("生图蒙版", systemImage: "sparkles")
                }

            PlantArtworkEditorPreview()
                .tabItem {
                    Label("图片编辑", systemImage: "crop")
                }

            CardComponentPreview()
                .tabItem {
                    Label("卡片组件", systemImage: "leaf.fill")
                }
        }
    }
}

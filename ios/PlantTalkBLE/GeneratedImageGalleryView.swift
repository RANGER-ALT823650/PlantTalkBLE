import SwiftUI
import UIKit

@MainActor
struct GeneratedImageGalleryView: View {
    let onApplyToPlantCard: (GeneratedPlantImage) -> Void
    let onDeleteGeneratedImage: (String) -> Void

    @State private var images: [GeneratedPlantImage] = []
    @State private var isLoading = true
    @State private var imagePendingDeletion: GeneratedPlantImage?
    @State private var imagePreviewItem: ZoomableImagePreviewItem?
    @State private var imagePreviewProgress: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let columns = [
        GridItem(.flexible(), spacing: GeneratedImageGalleryLayout.spacing),
        GridItem(.flexible(), spacing: GeneratedImageGalleryLayout.spacing)
    ]

    var body: some View {
        Group {
            if isLoading {
                ProgressView("正在读取 AI 图片…")
            } else if images.isEmpty {
                ContentUnavailableView(
                    "还没有 AI 生成图片",
                    systemImage: "sparkles",
                    description: Text("在植物图片编辑页使用“AI 生图”后，结果会出现在这里。")
                )
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: GeneratedImageGalleryLayout.spacing) {
                        ForEach(images) { item in
                            galleryCell(item)
                        }
                    }
                    .padding(GeneratedImageGalleryLayout.padding)
                }
                .refreshable {
                    reloadImages()
                }
            }
        }
        .task {
            reloadImages()
            isLoading = false
        }
        .onAppear {
            guard !isLoading else { return }
            reloadImages()
        }
        .overlay {
            if let imagePreviewItem {
                ZoomableImagePreviewOverlay(
                    item: imagePreviewItem,
                    progress: imagePreviewProgress,
                    onDismiss: dismissImagePreview
                )
                .transition(.identity)
            }
        }
        .alert(
            "删除这张 AI 图片？",
            isPresented: deletionConfirmationPresented
        ) {
            Button("删除", role: .destructive) {
                if let imagePendingDeletion {
                    deleteImage(imagePendingDeletion)
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("删除后无法恢复。")
        }
    }

    private func galleryCell(_ item: GeneratedPlantImage) -> some View {
        let sourceID = item.id

        return GeometryReader { proxy in
            let side = proxy.size.width

            Button {
                presentImagePreview(
                    item.image,
                    sourceID: sourceID,
                    sourceFrame: proxy.frame(in: .global)
                )
            } label: {
                Group {
                    if imagePreviewItem?.id == sourceID {
                        Color.clear
                    } else {
                        Image(uiImage: item.image)
                            .resizable()
                            .scaledToFill()
                    }
                }
                .frame(width: side, height: side)
                .clipShape(RoundedRectangle(
                    cornerRadius: GeneratedImageGalleryLayout.cornerRadius,
                    style: .continuous
                ))
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button("复用到植物卡片", systemImage: "leaf") {
                    applyToPlantCard(item)
                }
                Button("删除", systemImage: "trash", role: .destructive) {
                    imagePendingDeletion = item
                }
            }
            .accessibilityLabel("AI 生成图片")
            .accessibilityHint("轻点放大，长按可复用到植物卡片或删除")
        }
        .aspectRatio(1, contentMode: .fit)
    }

    private func reloadImages() {
        images = GeneratedPlantImageStorage.loadAll()
    }

    private var deletionConfirmationPresented: Binding<Bool> {
        Binding(
            get: { imagePendingDeletion != nil },
            set: { if !$0 { imagePendingDeletion = nil } }
        )
    }

    private func applyToPlantCard(_ item: GeneratedPlantImage) {
        onApplyToPlantCard(item)
    }

    private func deleteImage(_ item: GeneratedPlantImage) {
        imagePendingDeletion = nil
        if imagePreviewItem?.id == item.id {
            dismissImagePreviewImmediately()
        }
        images.removeAll { $0.id == item.id }
        GeneratedPlantImageStorage.delete(id: item.id)
        onDeleteGeneratedImage(item.id)
    }

    private func presentImagePreview(
        _ image: UIImage,
        sourceID: String,
        sourceFrame: CGRect
    ) {
        guard imagePreviewItem == nil, !sourceFrame.isEmpty else { return }

        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            imagePreviewProgress = 0
            imagePreviewItem = ZoomableImagePreviewItem(
                id: sourceID,
                image: image,
                sourceFrame: sourceFrame,
                sourceCornerRadius: GeneratedImageGalleryLayout.cornerRadius
            )
        }

        Task { @MainActor in
            await Task.yield()
            guard imagePreviewItem?.id == sourceID else { return }
            withAnimation(imagePreviewAnimation) {
                imagePreviewProgress = 1
            }
        }
    }

    private func dismissImagePreview() {
        guard let sourceID = imagePreviewItem?.id else { return }
        // `.smooth` has a visual spring tail. Keep the overlay alive until that
        // tail is fully removed so its last rendered frame matches the source.
        withAnimation(
            imagePreviewAnimation,
            completionCriteria: .removed
        ) {
            imagePreviewProgress = 0
        } completion: {
            guard imagePreviewItem?.id == sourceID,
                  imagePreviewProgress <= 0.001 else { return }
            dismissImagePreviewImmediately()
        }
    }

    private func dismissImagePreviewImmediately() {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            imagePreviewItem = nil
            imagePreviewProgress = 0
        }
    }

    private var imagePreviewAnimation: Animation {
        reduceMotion
            ? .easeInOut(duration: 0.18)
            : .smooth(duration: 0.42)
    }
}

private enum GeneratedImageGalleryLayout {
    static let spacing: CGFloat = 12
    static let padding: CGFloat = 16
    static let cornerRadius: CGFloat = 18
}

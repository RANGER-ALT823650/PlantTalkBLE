import SwiftUI
import UIKit

struct ZoomableImagePreviewItem: Identifiable {
    let id: String
    let image: UIImage
    let sourceFrame: CGRect
    let sourceCornerRadius: CGFloat
}

/// Frame-morphing fullscreen image preview used by chat bubbles and the AI
/// image gallery. Progress 0 keeps the image over the source frame; progress 1
/// settles it into an aspect-fit presentation.
struct ZoomableImagePreviewOverlay: View {
    let item: ZoomableImagePreviewItem
    let progress: CGFloat
    let onDismiss: () -> Void

    var body: some View {
        GeometryReader { proxy in
            let overlayFrame = proxy.frame(in: .global)
            let sourceFrame = item.sourceFrame.offsetBy(
                dx: -overlayFrame.minX,
                dy: -overlayFrame.minY
            )
            let destinationFrame = previewFrame(in: proxy)
            let currentFrame = interpolatedFrame(
                from: sourceFrame,
                to: destinationFrame,
                progress: progress
            )
            let destinationCorner = previewCornerSize(
                previewFrame: destinationFrame,
                proxy: proxy
            )
            let currentCorner = CGSize(
                width: interpolate(
                    item.sourceCornerRadius,
                    destinationCorner.width,
                    progress
                ),
                height: interpolate(
                    item.sourceCornerRadius,
                    destinationCorner.height,
                    progress
                )
            )

            ZStack {
                Color.clear

                Image(uiImage: item.image)
                    .resizable()
                    .scaledToFill()
                    .frame(
                        width: max(currentFrame.width, 1),
                        height: max(currentFrame.height, 1)
                    )
                    .clipShape(ZoomableImageMorphShape(
                        cornerWidth: currentCorner.width,
                        cornerHeight: currentCorner.height
                    ))
                    .position(x: currentFrame.midX, y: currentFrame.midY)
                    .accessibilityLabel("图片预览")
                    .accessibilityHint("轻点关闭预览")
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onDismiss)
        }
        .ignoresSafeArea()
    }

    private func previewFrame(in proxy: GeometryProxy) -> CGRect {
        let horizontalInset = proxy.size.width * 0.06
            + max(proxy.safeAreaInsets.leading, proxy.safeAreaInsets.trailing)
        let verticalInset = proxy.size.height * 0.06
            + max(proxy.safeAreaInsets.top, proxy.safeAreaInsets.bottom)
        let availableSize = CGSize(
            width: max(proxy.size.width - horizontalInset * 2, 0),
            height: max(proxy.size.height - verticalInset * 2, 0)
        )
        let imageSize = aspectFitSize(item.image.size, inside: availableSize)
        return CGRect(
            x: (proxy.size.width - imageSize.width) / 2,
            y: (proxy.size.height - imageSize.height) / 2,
            width: imageSize.width,
            height: imageSize.height
        )
    }

    private func aspectFitSize(_ source: CGSize, inside bounds: CGSize) -> CGSize {
        guard source.width > 0,
              source.height > 0,
              bounds.width > 0,
              bounds.height > 0 else { return .zero }
        let scale = min(bounds.width / source.width, bounds.height / source.height)
        return CGSize(width: source.width * scale, height: source.height * scale)
    }

    private func previewCornerSize(
        previewFrame: CGRect,
        proxy: GeometryProxy
    ) -> CGSize {
        guard proxy.size.width > 0, proxy.size.height > 0 else { return .zero }
        let screenCorner = screenCornerSize(in: proxy)
        return CGSize(
            width: (screenCorner.width / proxy.size.width) * previewFrame.width,
            height: (screenCorner.height / proxy.size.height) * previewFrame.height
        )
    }

    private func screenCornerSize(in proxy: GeometryProxy) -> CGSize {
        if #available(iOS 26, *) {
            let insets = proxy.containerCornerInsets
            let cornerSize = CGSize(
                width: [
                    insets.topLeading.width,
                    insets.topTrailing.width,
                    insets.bottomLeading.width,
                    insets.bottomTrailing.width
                ].max() ?? 0,
                height: [
                    insets.topLeading.height,
                    insets.topTrailing.height,
                    insets.bottomLeading.height,
                    insets.bottomTrailing.height
                ].max() ?? 0
            )
            if cornerSize.width > 0, cornerSize.height > 0 {
                return cornerSize
            }
        }

        let screenMinimum = min(proxy.size.width, proxy.size.height)
        let radius = min(
            max(proxy.safeAreaInsets.top * 0.72, screenMinimum * 0.06),
            screenMinimum * 0.14
        )
        return CGSize(width: radius, height: radius)
    }

    private func interpolatedFrame(
        from source: CGRect,
        to destination: CGRect,
        progress: CGFloat
    ) -> CGRect {
        CGRect(
            x: interpolate(source.minX, destination.minX, progress),
            y: interpolate(source.minY, destination.minY, progress),
            width: interpolate(source.width, destination.width, progress),
            height: interpolate(source.height, destination.height, progress)
        )
    }

    private func interpolate(
        _ start: CGFloat,
        _ end: CGFloat,
        _ progress: CGFloat
    ) -> CGFloat {
        start + ((end - start) * min(max(progress, 0), 1))
    }
}

private struct ZoomableImageMorphShape: Shape {
    var cornerWidth: CGFloat
    var cornerHeight: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(cornerWidth, cornerHeight) }
        set {
            cornerWidth = newValue.first
            cornerHeight = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        Path(
            roundedRect: rect,
            cornerSize: CGSize(
                width: min(max(cornerWidth, 0), rect.width / 2),
                height: min(max(cornerHeight, 0), rect.height / 2)
            ),
            style: .continuous
        )
    }
}

import PhotosUI
import SwiftUI
import UIKit

struct PlantArtwork {
    let image: UIImage
    let scale: CGFloat
    let normalizedOffset: CGSize
}

struct PlantArtworkDraft: Identifiable {
    let id = UUID()
    let artwork: PlantArtwork
}

enum PlantArtworkCrop {
    static let minimumScale: CGFloat = 1
    static let maximumScale: CGFloat = 6

    static func clampedScale(_ scale: CGFloat) -> CGFloat {
        min(maximumScale, max(minimumScale, scale))
    }

    static func pointOffset(from normalizedOffset: CGSize, in frameSize: CGSize) -> CGSize {
        CGSize(
            width: normalizedOffset.width * frameSize.width,
            height: normalizedOffset.height * frameSize.height
        )
    }

    static func normalizedOffset(from pointOffset: CGSize, in frameSize: CGSize) -> CGSize {
        guard frameSize.width > 0, frameSize.height > 0 else { return .zero }
        return CGSize(
            width: pointOffset.width / frameSize.width,
            height: pointOffset.height / frameSize.height
        )
    }

    static func maximumOffset(
        imageSize: CGSize,
        frameSize: CGSize,
        scale: CGFloat
    ) -> CGSize {
        guard imageSize.width > 0,
              imageSize.height > 0,
              frameSize.width > 0,
              frameSize.height > 0 else {
            return .zero
        }

        let fillScale = max(
            frameSize.width / imageSize.width,
            frameSize.height / imageSize.height
        )
        let renderedWidth = imageSize.width * fillScale * clampedScale(scale)
        let renderedHeight = imageSize.height * fillScale * clampedScale(scale)
        return CGSize(
            width: max(0, (renderedWidth - frameSize.width) / 2),
            height: max(0, (renderedHeight - frameSize.height) / 2)
        )
    }

    static func clampedOffset(
        _ offset: CGSize,
        imageSize: CGSize,
        frameSize: CGSize,
        scale: CGFloat
    ) -> CGSize {
        let maximum = maximumOffset(
            imageSize: imageSize,
            frameSize: frameSize,
            scale: scale
        )
        return CGSize(
            width: min(maximum.width, max(-maximum.width, offset.width)),
            height: min(maximum.height, max(-maximum.height, offset.height))
        )
    }
}

enum PlantArtworkStorage {
    private struct Metadata: Codable {
        let scale: Double
        let offsetX: Double
        let offsetY: Double
    }

    private static let directoryName = "PlantArtwork"
    private static let imageFileName = "artwork.jpg"
    private static let metadataFileName = "artwork.json"

    static func load() -> PlantArtwork? {
        guard let directoryURL,
              let image = UIImage(contentsOfFile: directoryURL
                .appendingPathComponent(imageFileName).path),
              let metadataData = try? Data(contentsOf: directoryURL
                .appendingPathComponent(metadataFileName)),
              let metadata = try? JSONDecoder().decode(Metadata.self, from: metadataData) else {
            return nil
        }

        return PlantArtwork(
            image: image,
            scale: PlantArtworkCrop.clampedScale(CGFloat(metadata.scale)),
            normalizedOffset: CGSize(
                width: CGFloat(metadata.offsetX),
                height: CGFloat(metadata.offsetY)
            )
        )
    }

    static func save(_ artwork: PlantArtwork?) {
        guard let directoryURL else { return }

        guard let artwork else {
            try? FileManager.default.removeItem(at: directoryURL)
            return
        }

        guard let imageData = artwork.image.jpegData(compressionQuality: 0.92) else { return }
        let metadata = Metadata(
            scale: Double(artwork.scale),
            offsetX: Double(artwork.normalizedOffset.width),
            offsetY: Double(artwork.normalizedOffset.height)
        )

        do {
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )
            try imageData.write(
                to: directoryURL.appendingPathComponent(imageFileName),
                options: .atomic
            )
            try JSONEncoder().encode(metadata).write(
                to: directoryURL.appendingPathComponent(metadataFileName),
                options: .atomic
            )
        } catch {
            // The in-memory artwork remains usable even if local persistence fails.
        }
    }

    private static var directoryURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent(directoryName, isDirectory: true)
    }
}

struct PlantArtworkControl: View {
    @Binding var artwork: PlantArtwork?
    let isDetailsExpanded: Bool
    let onTap: () -> Void

    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var editorDraft: PlantArtworkDraft?
    @State private var isPhotoPickerPresented = false
    @State private var isLoadingImage = false
    @State private var pickerError: PlantArtworkPickerError?

    var body: some View {
        artworkSurface
            .photosPicker(
                isPresented: $isPhotoPickerPresented,
                selection: $selectedPhotoItem,
                matching: .images
            )
            .task(id: selectedPhotoItem) {
                guard let selectedPhotoItem else { return }
                await loadImage(from: selectedPhotoItem)
            }
            .sheet(item: $editorDraft) { draft in
                PlantArtworkEditorView(
                    draft: draft,
                    artwork: $artwork
                )
            }
            .alert(item: $pickerError) { error in
                Alert(
                    title: Text("无法读取图片"),
                    message: Text(error.message),
                    dismissButton: .default(Text("好"))
                )
            }
    }

    private var artworkSurface: some View {
        Button(action: onTap) {
            PlantArtworkPlaceholder(artwork: artwork)
                .overlay {
                    if isLoadingImage {
                        ArtworkLoadingIndicator()
                    }
                }
        }
        .buttonStyle(.plain)
        .contentShape(.interaction, Rectangle())
        .contentShape(.contextMenuPreview, PlantArtworkFrameShape())
        .contextMenu {
            if !isDetailsExpanded {
                artworkMenu
            }
        }
        .geometryGroup()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isDetailsExpanded ? "收起植物状态" : "查看植物状态")
        .accessibilityValue(isDetailsExpanded ? "已展开" : "已收起")
        .accessibilityHint(
            isDetailsExpanded
                ? "显示或隐藏传感器数据"
                : "轻点展开植物状态，长按可以选择植物图片"
        )
        .accessibilityAction(named: "选择植物图片") {
            guard !isDetailsExpanded else { return }
            choosePhoto()
        }
    }

    @ViewBuilder
    private var artworkMenu: some View {
        Button {
            choosePhoto()
        } label: {
            Label(
                artwork == nil ? "从照片图库选择" : "选择新图片",
                systemImage: "photo.on.rectangle"
            )
        }

        if let artwork {
            Button {
                editorDraft = PlantArtworkDraft(artwork: artwork)
            } label: {
                Label("重新调整", systemImage: "crop")
            }

            Button(role: .destructive) {
                self.artwork = nil
            } label: {
                Label("恢复默认插画", systemImage: "arrow.uturn.backward")
            }
        }
    }

    private func choosePhoto() {
        selectedPhotoItem = nil
        isPhotoPickerPresented = true
    }

    @MainActor
    private func loadImage(from item: PhotosPickerItem) async {
        isLoadingImage = true
        defer { isLoadingImage = false }

        do {
            guard let data = try await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data) else {
                throw PlantArtworkPickerError(message: "所选项目不是可用的图片，请重新选择。")
            }
            guard !Task.isCancelled else { return }

            editorDraft = PlantArtworkDraft(
                artwork: PlantArtwork(
                    image: image,
                    scale: 1,
                    normalizedOffset: .zero
                )
            )
        } catch is CancellationError {
            return
        } catch let error as PlantArtworkPickerError {
            pickerError = error
        } catch {
            pickerError = PlantArtworkPickerError(message: error.localizedDescription)
        }
    }
}

private struct PlantArtworkFrameShape: InsettableShape {
    private static let cornerRadiusRatio: CGFloat = 0.14
    private var insetAmount: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let insetRect = rect.insetBy(dx: insetAmount, dy: insetAmount)
        let cornerRadius = max(
            0,
            rect.width * Self.cornerRadiusRatio - insetAmount
        )

        return RoundedRectangle(
            cornerRadius: cornerRadius,
            style: .continuous
        )
        .path(in: insetRect)
    }

    func inset(by amount: CGFloat) -> PlantArtworkFrameShape {
        var copy = self
        copy.insetAmount += amount
        return copy
    }
}

private struct PlantArtworkPickerError: Identifiable, Error {
    let id = UUID()
    let message: String
}

private struct ArtworkLoadingIndicator: View {
    var body: some View {
        Group {
            if #available(iOS 26, *) {
                ProgressView()
                    .controlSize(.large)
                    .padding(18)
                    .glassEffect(.regular, in: .circle)
            } else {
                ProgressView()
                    .controlSize(.large)
                    .padding(18)
                    .background(.ultraThinMaterial, in: Circle())
            }
        }
        .accessibilityLabel("正在读取图片")
    }
}

private struct PlantArtworkPlaceholder: View {
    let artwork: PlantArtwork?

    var body: some View {
        GeometryReader { proxy in
            let shape = PlantArtworkFrameShape()

            ZStack {
                Color(uiColor: .secondarySystemBackground)

                if let artwork {
                    artworkImage(artwork, frameSize: proxy.size)
                } else {
                    Image(systemName: "leaf.fill")
                        .font(.system(size: proxy.size.width * 0.28, weight: .medium))
                        .foregroundStyle(.tint)
                }
            }
            .clipShape(shape)
            .overlay {
                shape.strokeBorder(
                    Color.accentColor.opacity(0.5),
                    lineWidth: 1.5
                )
            }
        }
        .aspectRatio(3 / 4, contentMode: .fit)
    }

    private func artworkImage(_ artwork: PlantArtwork, frameSize: CGSize) -> some View {
        let scale = PlantArtworkCrop.clampedScale(artwork.scale)
        let requestedOffset = PlantArtworkCrop.pointOffset(
            from: artwork.normalizedOffset,
            in: frameSize
        )
        let offset = PlantArtworkCrop.clampedOffset(
            requestedOffset,
            imageSize: artwork.image.size,
            frameSize: frameSize,
            scale: scale
        )

        return Image(uiImage: artwork.image)
            .resizable()
            .scaledToFill()
            .frame(width: frameSize.width, height: frameSize.height)
            .scaleEffect(scale)
            .offset(offset)
    }
}

private struct PlantArtworkEditorView: View {
    let draft: PlantArtworkDraft
    @Binding var artwork: PlantArtwork?

    @State private var scale: CGFloat
    @State private var normalizedOffset: CGSize
    @GestureState private var gestureScale: CGFloat = 1
    @GestureState private var dragTranslation: CGSize = .zero
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(draft: PlantArtworkDraft, artwork: Binding<PlantArtwork?>) {
        self.draft = draft
        _artwork = artwork
        _scale = State(initialValue: PlantArtworkCrop.clampedScale(draft.artwork.scale))
        _normalizedOffset = State(initialValue: draft.artwork.normalizedOffset)
    }

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                let frameWidth = cropFrameWidth(in: proxy.size)
                let frameSize = CGSize(width: frameWidth, height: frameWidth * 4 / 3)

                VStack(spacing: 18) {
                    Spacer(minLength: 12)

                    cropFrame(size: frameSize)

                    adjustmentHint

                    Button(action: resetTransform) {
                        Label("还原位置", systemImage: "arrow.counterclockwise")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .disabled(isAtDefaultTransform)

                    Spacer(minLength: 12)
                }
                .padding(.horizontal, 20)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(Color(uiColor: .systemBackground))
            .navigationTitle("调整植物图片")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        saveArtwork()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(32)
        .interactiveDismissDisabled(hasUnsavedTransformChanges)
    }

    private func cropFrame(size: CGSize) -> some View {
        let effectiveScale = PlantArtworkCrop.clampedScale(scale * gestureScale)
        let baseOffset = PlantArtworkCrop.pointOffset(
            from: normalizedOffset,
            in: size
        )
        let requestedOffset = CGSize(
            width: baseOffset.width + dragTranslation.width,
            height: baseOffset.height + dragTranslation.height
        )
        let effectiveOffset = PlantArtworkCrop.clampedOffset(
            requestedOffset,
            imageSize: draft.artwork.image.size,
            frameSize: size,
            scale: effectiveScale
        )
        let cornerRadius = size.width * 0.14
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        return Image(uiImage: draft.artwork.image)
            .resizable()
            .scaledToFill()
            .frame(width: size.width, height: size.height)
            .scaleEffect(effectiveScale)
            .offset(effectiveOffset)
            .frame(width: size.width, height: size.height)
            .contentShape(Rectangle())
            .gesture(dragGesture(frameSize: size))
            .simultaneousGesture(magnifyGesture(frameSize: size))
            .clipShape(shape)
            .overlay {
                shape.strokeBorder(Color.accentColor.opacity(0.65), lineWidth: 2)
            }
            .shadow(color: .black.opacity(0.12), radius: 18, y: 8)
            .accessibilityLabel("植物图片画框")
            .accessibilityHint("双指缩放图片，拖动来调整画面位置")
    }

    @ViewBuilder
    private var adjustmentHint: some View {
        let label = Label("双指缩放 · 拖动定位", systemImage: "hand.pinch")
            .font(.footnote.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 9)

        if #available(iOS 26, *) {
            label.glassEffect(.regular, in: .capsule)
        } else {
            label.background(.ultraThinMaterial, in: Capsule())
        }
    }

    private var isAtDefaultTransform: Bool {
        abs(scale - 1) < 0.001
            && abs(normalizedOffset.width) < 0.001
            && abs(normalizedOffset.height) < 0.001
    }

    private var hasUnsavedTransformChanges: Bool {
        abs(scale - draft.artwork.scale) > 0.001
            || abs(normalizedOffset.width - draft.artwork.normalizedOffset.width) > 0.001
            || abs(normalizedOffset.height - draft.artwork.normalizedOffset.height) > 0.001
    }

    private func cropFrameWidth(in availableSize: CGSize) -> CGFloat {
        let horizontalLimit = max(1, availableSize.width - 40)
        let verticalLimit = max(1, (availableSize.height - 150) * 3 / 4)
        return min(440, min(horizontalLimit, verticalLimit))
    }

    private func dragGesture(frameSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .updating($dragTranslation) { value, state, _ in
                state = value.translation
            }
            .onEnded { value in
                let baseOffset = PlantArtworkCrop.pointOffset(
                    from: normalizedOffset,
                    in: frameSize
                )
                let requestedOffset = CGSize(
                    width: baseOffset.width + value.translation.width,
                    height: baseOffset.height + value.translation.height
                )
                let clampedOffset = PlantArtworkCrop.clampedOffset(
                    requestedOffset,
                    imageSize: draft.artwork.image.size,
                    frameSize: frameSize,
                    scale: scale
                )
                normalizedOffset = PlantArtworkCrop.normalizedOffset(
                    from: clampedOffset,
                    in: frameSize
                )
            }
    }

    private func magnifyGesture(frameSize: CGSize) -> some Gesture {
        MagnifyGesture(minimumScaleDelta: 0.005)
            .updating($gestureScale) { value, state, _ in
                state = value.magnification
            }
            .onEnded { value in
                scale = PlantArtworkCrop.clampedScale(scale * value.magnification)
                clampCommittedOffset(frameSize: frameSize)
            }
    }

    private func clampCommittedOffset(frameSize: CGSize) {
        let pointOffset = PlantArtworkCrop.pointOffset(
            from: normalizedOffset,
            in: frameSize
        )
        let clampedOffset = PlantArtworkCrop.clampedOffset(
            pointOffset,
            imageSize: draft.artwork.image.size,
            frameSize: frameSize,
            scale: scale
        )
        normalizedOffset = PlantArtworkCrop.normalizedOffset(
            from: clampedOffset,
            in: frameSize
        )
    }

    private func resetTransform() {
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.25)) {
            scale = 1
            normalizedOffset = .zero
        }
    }

    private func saveArtwork() {
        artwork = PlantArtwork(
            image: draft.artwork.image,
            scale: PlantArtworkCrop.clampedScale(scale),
            normalizedOffset: normalizedOffset
        )
        dismiss()
    }
}

private struct PlantArtworkEditorPreview: View {
    @State private var artwork: PlantArtwork?

    var body: some View {
        PlantArtworkEditorView(
            draft: PlantArtworkDraft(
                artwork: PlantArtwork(
                    image: UIImage(systemName: "leaf.fill")!,
                    scale: 1,
                    normalizedOffset: .zero
                )
            ),
            artwork: $artwork
        )
    }
}

#Preview("植物图片编辑") {
    PlantArtworkEditorPreview()
}

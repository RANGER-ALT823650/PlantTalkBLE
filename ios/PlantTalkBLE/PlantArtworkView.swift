import AVFoundation
import PhotosUI
import SwiftUI
import UIKit

struct PlantArtwork {
    let image: UIImage
    let scale: CGFloat
    let normalizedOffset: CGSize
}

// MARK: - Generation mask

/// A single static dot in the generation mask. Every dot shares one color and
/// base radius; only its grid position is stored. The per-frame brush radius
/// boost is recomputed from the traveling center each frame.
private struct MaskDot {
    let position: CGPoint
}

/// The gray dot-field overlay shown on the plant card while an AI image is being
/// generated. A single "brush" center travels along `x = sin(t)`, `y = cos(t)`;
/// the dot nearest the center is enlarged, and dots within the brush circle grow
/// from the edge inward, so the field reads as a brush sweeping over the card.
private struct PlantArtworkGenerationMask: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            DotBrushField(size: proxy.size, reduceMotion: reduceMotion)
        }
        .allowsHitTesting(false)
        .accessibilityElement()
        .accessibilityLabel("正在生成 AI 图片")
    }
}

private struct DotBrushField: View {
    let size: CGSize
    let reduceMotion: Bool

    // A fixed, axis-aligned, very dense grid of uniform dots (single color, so
    // they only stand apart from the mask behind them). Positions never move.
    // Around the traveling center, radii swell from the normal size at the brush
    // edge up to the center dot, which is the largest.
    private static let spacing: CGFloat = 5
    private static let dotRadius: CGFloat = 1.7
    private static let centerDotRadius: CGFloat = 4.5
    private static let brushRadiusRatio: CGFloat = 0.24
    private static let dotColor = Color(white: 0.7)
    private static let maskColor = Color(white: 0.3)

    var body: some View {
        let dots = Self.makeDots(in: size)

        ZStack {
            // Fully opaque wash: the card image is hidden until generation ends.
            Self.maskColor

            if reduceMotion {
                // Static field with the center dot fixed at the middle.
                Canvas { context, canvasSize in
                    Self.draw(
                        dots: dots,
                        center: CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2),
                        in: context
                    )
                }
            } else {
                TimelineView(.animation) { timeline in
                    let t = timeline.date.timeIntervalSinceReferenceDate
                    Canvas { context, canvasSize in
                        Self.draw(
                            dots: dots,
                            center: Self.travelingPoint(at: t, in: canvasSize),
                            in: context
                        )
                    }
                }
            }
        }
    }

    /// The traveling point that anchors the brush. Time is the free variable; X
    /// follows sine and Y follows cosine at slightly different rates, so the swell
    /// sweeps across the fixed grid.
    private static func travelingPoint(at time: TimeInterval, in size: CGSize) -> CGPoint {
        let marginX = size.width * 0.18
        let marginY = size.height * 0.18
        let x = size.width / 2 + sin(time * 0.9) * (size.width / 2 - marginX)
        let y = size.height / 2 + cos(time * 1.3) * (size.height / 2 - marginY)
        return CGPoint(x: x, y: y)
    }

    /// Every dot shares one color. The single grid dot nearest the traveling point
    /// is the largest; within the brush radius, dot radius falls off from the
    /// center outward, reaching the normal radius at the brush edge.
    /// Every dot shares one color. Dots near the continuous traveling point swell
    /// smoothly with a cosine falloff from centerDotRadius at the center down to
    /// dotRadius at the brush edge, avoiding grid-snapping choppiness.
    private static func draw(
        dots: [MaskDot],
        center: CGPoint,
        in context: GraphicsContext
    ) {
        guard !dots.isEmpty else { return }
        let brushRadius = max(
            spacing * 2,
            min(context.clipBoundingRect.width, context.clipBoundingRect.height) * brushRadiusRatio
        )

        for dot in dots {
            let distance = hypot(dot.position.x - center.x, dot.position.y - center.y)
            var radius = dotRadius
            if distance < brushRadius {
                let norm = distance / brushRadius
                let falloff = 0.5 * (1 + cos(.pi * norm))
                radius = dotRadius + (centerDotRadius - dotRadius) * falloff
            }
            let rect = CGRect(
                x: dot.position.x - radius,
                y: dot.position.y - radius,
                width: radius * 2,
                height: radius * 2
            )
            context.fill(Path(ellipseIn: rect), with: .color(dotColor))
        }
    }

    /// A fixed, centered, strictly axis-aligned grid — no jitter, so rows and
    /// columns line up. Dense spacing with a small radius keeps clear gaps.
    private static func makeDots(in size: CGSize) -> [MaskDot] {
        guard size.width > 0, size.height > 0 else { return [] }
        let columns = max(1, Int(size.width / spacing))
        let rows = max(1, Int(size.height / spacing))
        let startX = (size.width - CGFloat(columns - 1) * spacing) / 2
        let startY = (size.height - CGFloat(rows - 1) * spacing) / 2

        var dots: [MaskDot] = []
        dots.reserveCapacity(columns * rows)
        for row in 0..<rows {
            for column in 0..<columns {
                dots.append(MaskDot(position: CGPoint(
                    x: startX + CGFloat(column) * spacing,
                    y: startY + CGFloat(row) * spacing
                )))
            }
        }
        return dots
    }
}

/// Standalone harness for the generation mask. It cycles image → mask → image
/// on a loop so the appear/disappear animation and the traveling center dot can
/// be inspected in isolation. Split into small subviews to keep each expression
/// cheap for the Preview compiler.
struct GenerationMaskPreview: View {
    @State private var isGenerating = false

    private let frameWidth: CGFloat = 260

    var body: some View {
        VStack(spacing: 24) {
            card
            toggle
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemBackground))
    }

    private var card: some View {
        placeholderImage
            .frame(width: frameWidth, height: frameWidth * 4 / 3)
            .overlay {
                if isGenerating {
                    PlantArtworkGenerationMask()
                        .transition(maskTransition)
                }
            }
            .clipShape(PlantArtworkFrameShape())
            .shadow(color: .black.opacity(0.12), radius: 18, y: 8)
    }

    private var placeholderImage: some View {
        LinearGradient(
            colors: [.green.opacity(0.55), .mint, .teal],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .overlay {
            Image(systemName: "leaf.fill")
                .font(.system(size: 88))
                .foregroundStyle(.white.opacity(0.85))
        }
    }

    private var toggle: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.4)) {
                isGenerating.toggle()
            }
        } label: {
            Text(isGenerating ? "显示图片" : "显示蒙版")
                .font(.headline)
        }
        .buttonStyle(.borderedProminent)
    }

    private var maskTransition: AnyTransition {
        .opacity
    }
}

#Preview("生图蒙版动画") {
    GenerationMaskPreview()
}

struct PlantArtworkDraft: Identifiable {
    let id = UUID()
    let artwork: PlantArtwork
}

/// The payload the editor hands back when the user taps "AI 生图": the source
/// image plus the crop transform to reapply to whatever image comes back.
struct PlantArtworkGenerationRequest {
    let image: UIImage
    let prompt: String
    let scale: CGFloat
    let normalizedOffset: CGSize
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
    var imageGenerationClient: PlantImageGenerationClient = .live()

    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var editorDraft: PlantArtworkDraft?
    @State private var isPhotoPickerPresented = false
    @State private var isCameraPresented = false
    @State private var isLoadingImage = false
    @State private var pickerError: PlantArtworkPickerError?
    @State private var isGeneratingImage = false
    @State private var generationTask: Task<Void, Never>?
    @State private var generationError: PlantArtworkPickerError?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
            .fullScreenCover(isPresented: $isCameraPresented) {
                ConversationMediaPanel(
                    source: .camera,
                    onDismiss: { isCameraPresented = false },
                    onAttachments: { attachments in
                        isCameraPresented = false
                        guard let image = attachments.first?.image else { return }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                            editorDraft = PlantArtworkDraft(
                                artwork: PlantArtwork(image: image, scale: 1, normalizedOffset: .zero)
                            )
                        }
                    }
                )
                .ignoresSafeArea()
            }
            .sheet(item: $editorDraft) { draft in
                PlantArtworkEditorView(
                    draft: draft,
                    artwork: $artwork,
                    defaultPrompt: AISettingsStore.imageGenPrompt,
                    onGenerate: startGeneration
                )
            }
            .alert(item: $pickerError) { error in
                Alert(
                    title: Text("无法读取图片"),
                    message: Text(error.message),
                    dismissButton: .default(Text("好"))
                )
            }
            .alert(item: $generationError) { error in
                Alert(
                    title: Text("AI 生图失败"),
                    message: Text(error.message),
                    dismissButton: .default(Text("好"))
                )
            }
            .onDisappear {
                generationTask?.cancel()
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
                .overlay {
                    if isGeneratingImage {
                        PlantArtworkGenerationMask()
                            .clipShape(PlantArtworkFrameShape())
                            .transition(generationMaskTransition)
                    }
                }
        }
        .buttonStyle(.plain)
        .disabled(isGeneratingImage)
        .contentShape(.interaction, Rectangle())
        .contentShape(.contextMenuPreview, PlantArtworkFrameShape())
        .contextMenu {
            if !isDetailsExpanded && !isGeneratingImage {
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

    private var generationMaskTransition: AnyTransition {
        .opacity
    }

    @ViewBuilder
    private var artworkMenu: some View {
        Button {
            capturePhoto()
        } label: {
            Label("拍摄图片", systemImage: "camera")
        }
        .disabled(!UIImagePickerController.isSourceTypeAvailable(.camera))

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

    private func capturePhoto() {
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else { return }
        isCameraPresented = true
    }

    /// Called from the editor's "AI 生图" button. The editor dismisses itself, so
    /// this runs against the home card: the mask blooms in immediately, then the
    /// request runs and swaps in the generated image (keeping the crop transform).
    private func startGeneration(_ request: PlantArtworkGenerationRequest) {
        generationTask?.cancel()
        withAnimation(reduceMotion ? .easeInOut(duration: 0.3) : .easeInOut(duration: 0.4)) {
            isGeneratingImage = true
        }

        generationTask = Task {
            do {
                let configuration = try AISettingsStore.imageGenConfiguration()
                let generated = try await imageGenerationClient.generate(
                    configuration,
                    request.image,
                    request.prompt
                )
                try Task.checkCancellation()
                await MainActor.run {
                    artwork = PlantArtwork(
                        image: generated,
                        scale: request.scale,
                        normalizedOffset: request.normalizedOffset
                    )
                    finishGeneration()
                }
            } catch is CancellationError {
                await MainActor.run { finishGeneration() }
            } catch {
                await MainActor.run {
                    finishGeneration()
                    generationError = PlantArtworkPickerError(message: error.localizedDescription)
                }
            }
        }
    }

    private func finishGeneration() {
        withAnimation(reduceMotion ? .easeInOut(duration: 0.3) : .easeInOut(duration: 0.4)) {
            isGeneratingImage = false
        }
        generationTask = nil
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

struct PlantArtworkPlaceholder: View {
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
    let defaultPrompt: String
    let onGenerate: (PlantArtworkGenerationRequest) -> Void

    @State private var scale: CGFloat
    @State private var normalizedOffset: CGSize
    @State private var isPromptExpanded = false
    @State private var customPrompt = ""
    @GestureState private var gestureScale: CGFloat = 1
    @GestureState private var dragTranslation: CGSize = .zero
    @FocusState private var isPromptFocused: Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        draft: PlantArtworkDraft,
        artwork: Binding<PlantArtwork?>,
        defaultPrompt: String,
        onGenerate: @escaping (PlantArtworkGenerationRequest) -> Void
    ) {
        self.draft = draft
        _artwork = artwork
        self.defaultPrompt = defaultPrompt
        self.onGenerate = onGenerate
        _scale = State(initialValue: PlantArtworkCrop.clampedScale(draft.artwork.scale))
        _normalizedOffset = State(initialValue: draft.artwork.normalizedOffset)
    }

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                let frameWidth = cropFrameWidth(in: proxy.size)
                let frameSize = CGSize(width: frameWidth, height: frameWidth * 4 / 3)

                editorContent(frameSize: frameSize, frameWidth: frameWidth)
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
        .presentationDetents([.fraction(0.822), .large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(32)
        .interactiveDismissDisabled(hasUnsavedTransformChanges)
    }

    private func editorContent(frameSize: CGSize, frameWidth: CGFloat) -> some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(spacing: 20) {
                cropFrameWithControls(size: frameSize, frameWidth: frameWidth)

                HStack(alignment: .center) {
                    resetButton
                    Spacer()
                    adjustmentHint
                    Spacer()
                    generateButton
                }
                .padding(.horizontal, 4)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 24)
        }
        .scrollDismissesKeyboard(.interactively)
        .contentShape(Rectangle())
        .onTapGesture {
            if isPromptExpanded {
                collapsePrompt()
            }
        }
    }

    private func cropFrameWithControls(size: CGSize, frameWidth: CGFloat) -> some View {
        cropFrame(size: size)
            .overlay(alignment: .topTrailing) {
                promptControl(frameWidth: frameWidth)
                    .padding(12)
            }
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

        let imageContent = Image(uiImage: draft.artwork.image)
            .resizable()
            .scaledToFill()
            .frame(width: size.width, height: size.height)
            .scaleEffect(effectiveScale)
            .offset(effectiveOffset)
            .frame(width: size.width, height: size.height)
            .contentShape(Rectangle())

        return imageContent
            .gesture(dragGesture(frameSize: size))
            .simultaneousGesture(magnifyGesture(frameSize: size))
            .clipShape(shape)
            .overlay(
                shape.strokeBorder(Color.accentColor.opacity(0.65), lineWidth: 2)
            )
            .shadow(color: .black.opacity(0.12), radius: 18, y: 8)
            .accessibilityLabel("植物图片画框")
            .accessibilityHint("双指缩放图片，拖动来调整画面位置")
    }

    @ViewBuilder
    private var adjustmentHint: some View {
        if #available(iOS 26, *) {
            Label("双指缩放 · 拖动定位", systemImage: "hand.pinch")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .glassEffect(.regular, in: .capsule)
        } else {
            Label("双指缩放 · 拖动定位", systemImage: "hand.pinch")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .background(.ultraThinMaterial, in: Capsule())
        }
    }

    private var resetButton: some View {
        glassCircleButton(systemName: "arrow.counterclockwise", action: resetTransform)
            .disabled(isAtDefaultTransform)
            .opacity(isAtDefaultTransform ? 0.5 : 1)
            .accessibilityLabel("还原位置")
    }

    private var generateButton: some View {
        glassCircleButton(systemName: "sparkles", tint: .accentColor, action: startGeneration)
            .accessibilityLabel("AI 生图")
            .accessibilityHint("根据当前图片和提示词生成新的植物图片")
    }

    @ViewBuilder
    private func promptControl(frameWidth: CGFloat) -> some View {
        if isPromptExpanded {
            promptEditor(maxWidth: frameWidth - 24)
        } else {
            glassCircleButton(systemName: "text.bubble", action: expandPrompt)
                .accessibilityLabel("自定义生图提示词")
        }
    }

    @ViewBuilder
    private func promptEditor(maxWidth: CGFloat) -> some View {
        Group {
            if #available(iOS 26, *) {
                promptInputField(maxWidth: maxWidth)
                    .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 20))
            } else {
                promptInputField(maxWidth: maxWidth)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
        }
        .transition(.scale(scale: 0.7, anchor: .topTrailing).combined(with: .opacity))
    }

    private func promptInputField(maxWidth: CGFloat) -> some View {
        HStack(alignment: .top, spacing: 8) {
            TextField(
                "自定义生图提示词",
                text: $customPrompt,
                prompt: Text(defaultPrompt),
                axis: .vertical
            )
            .lineLimit(1...4)
            .font(.subheadline)
            .focused($isPromptFocused)
            .submitLabel(.done)
            .onSubmit(collapsePrompt)

            Button(action: collapsePrompt) {
                Image(systemName: "checkmark")
                    .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tint)
            .accessibilityLabel("完成输入")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: maxWidth, alignment: .leading)
    }

    @ViewBuilder
    private func glassCircleButton(
        systemName: String,
        tint: Color? = nil,
        action: @escaping () -> Void
    ) -> some View {
        if #available(iOS 26, *) {
            Button(action: action) {
                Image(systemName: systemName)
                    .font(.headline)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .controlSize(.regular)
            .tint(tint)
        } else {
            Button(action: action) {
                Image(systemName: systemName)
                    .font(.headline)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .foregroundStyle(tint ?? .primary)
            .background(.ultraThinMaterial, in: Circle())
        }
    }

    private func expandPrompt() {
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.28, extraBounce: 0.1)) {
            isPromptExpanded = true
        }
        isPromptFocused = true
    }

    private func collapsePrompt() {
        isPromptFocused = false
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.28, extraBounce: 0.1)) {
            isPromptExpanded = false
        }
    }

    private func startGeneration() {
        let trimmed = customPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = trimmed.isEmpty ? defaultPrompt : trimmed
        onGenerate(PlantArtworkGenerationRequest(
            image: draft.artwork.image,
            prompt: prompt,
            scale: PlantArtworkCrop.clampedScale(scale),
            normalizedOffset: normalizedOffset
        ))
        dismiss()
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
        return min(340, horizontalLimit)
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
        let clamped = PlantArtworkCrop.clampedScale(scale)
        let pointOffset = PlantArtworkCrop.pointOffset(
            from: normalizedOffset,
            in: CGSize(width: 320, height: 426.666)
        )
        let clampedOffset = PlantArtworkCrop.clampedOffset(
            pointOffset,
            imageSize: draft.artwork.image.size,
            frameSize: CGSize(width: 320, height: 426.666),
            scale: clamped
        )

        artwork = PlantArtwork(
            image: draft.artwork.image,
            scale: clamped,
            normalizedOffset: PlantArtworkCrop.normalizedOffset(
                from: clampedOffset,
                in: CGSize(width: 320, height: 426.666)
            )
        )
        dismiss()
    }
}

struct PlantArtworkEditorPreview: View {
    @State private var artwork: PlantArtwork?

    private static var sampleImage: UIImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 600, height: 800))
        return renderer.image { context in
            let cgContext = context.cgContext
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            let colors = [
                UIColor.systemGreen.withAlphaComponent(0.8).cgColor,
                UIColor.systemTeal.withAlphaComponent(0.9).cgColor
            ] as CFArray
            if let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0, 1]) {
                cgContext.drawLinearGradient(
                    gradient,
                    start: CGPoint(x: 0, y: 0),
                    end: CGPoint(x: 600, y: 800),
                    options: []
                )
            }
            if let symbol = UIImage(systemName: "leaf.fill")?.withTintColor(.white, renderingMode: .alwaysOriginal) {
                symbol.draw(in: CGRect(x: 200, y: 300, width: 200, height: 200))
            }
        }
    }

    var body: some View {
        PlantArtworkEditorView(
            draft: PlantArtworkDraft(
                artwork: PlantArtwork(
                    image: Self.sampleImage,
                    scale: 1,
                    normalizedOffset: .zero
                )
            ),
            artwork: $artwork,
            defaultPrompt: AISettingsStore.defaultImageGenPrompt,
            onGenerate: { _ in }
        )
    }
}

/// A responsive camera view using AVFoundation that captures photos instantly on
/// shutter press without showing the system's "Retake / Use Photo" confirmation UI.
struct SystemCameraPicker: View {
    let onImage: (UIImage?) -> Void
    @Environment(\.dismiss) private var dismiss
    @StateObject private var camera = DirectCameraController()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if camera.isReady {
                DirectCameraPreview(session: camera.session)
                    .ignoresSafeArea()
            } else if let error = camera.errorMessage {
                VStack(spacing: 12) {
                    Text("无法启动相机")
                        .font(.headline)
                        .foregroundStyle(.white)
                    Text(error)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.8))
                }
            } else {
                ProgressView()
                    .tint(.white)
            }

            VStack {
                HStack {
                    Button {
                        onImage(nil)
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.title3.weight(.medium))
                            .foregroundStyle(.white)
                            .padding(12)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.top, 54)

                Spacer()

                Button {
                    camera.capturePhoto { image in
                        onImage(image)
                        dismiss()
                    }
                } label: {
                    ZStack {
                        Circle()
                            .stroke(.white, lineWidth: 4)
                            .frame(width: 72, height: 72)
                        Circle()
                            .fill(.white)
                            .frame(width: 60, height: 60)
                    }
                }
                .buttonStyle(.plain)
                .disabled(!camera.isReady)
                .padding(.bottom, 40)
            }
        }
        .onAppear { camera.start() }
        .onDisappear { camera.stop() }
    }
}

private final class DirectCameraController: NSObject, ObservableObject, AVCapturePhotoCaptureDelegate {
    @Published var isReady = false
    @Published var errorMessage: String?

    let session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private let sessionQueue = DispatchQueue(label: "direct.camera.queue")
    private var completion: ((UIImage?) -> Void)?

    func start() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            do {
                self.session.beginConfiguration()
                self.session.sessionPreset = .photo
                guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
                      let input = try? AVCaptureDeviceInput(device: device),
                      self.session.canAddInput(input),
                      self.session.canAddOutput(self.photoOutput) else {
                    DispatchQueue.main.async { self.errorMessage = "请在设置中允许相机权限。" }
                    return
                }
                self.session.addInput(input)
                self.session.addOutput(self.photoOutput)
                self.photoOutput.maxPhotoQualityPrioritization = .speed
                self.session.commitConfiguration()
                self.session.startRunning()

                DispatchQueue.main.async {
                    self.isReady = true
                }
            }
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }

    func capturePhoto(completion: @escaping (UIImage?) -> Void) {
        self.completion = completion
        sessionQueue.async { [weak self] in
            guard let self else { return }
            let settings = AVCapturePhotoSettings()
            settings.photoQualityPrioritization = .speed
            self.photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let image: UIImage?
        if let data = photo.fileDataRepresentation() {
            image = UIImage(data: data)
        } else {
            image = nil
        }
        DispatchQueue.main.async {
            self.completion?(image)
            self.completion = nil
        }
    }
}

private struct DirectCameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> DirectCameraPreviewView {
        let view = DirectCameraPreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: DirectCameraPreviewView, context: Context) {}
}

private final class DirectCameraPreviewView: UIView {
    override class var layerClass: AnyClass {
        AVCaptureVideoPreviewLayer.self
    }

    var previewLayer: AVCaptureVideoPreviewLayer {
        layer as! AVCaptureVideoPreviewLayer
    }
}

#Preview("植物图片编辑") {
    PlantArtworkEditorPreview()
}

#Preview("植物卡片组件") {
    PlantArtworkPlaceholder(artwork: nil)
        .frame(width: 220)
        .padding(40)
}

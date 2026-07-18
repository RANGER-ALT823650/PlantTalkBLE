import AVFoundation
import Combine
import ImageIO
import Photos
import SwiftUI
import UIKit

enum ConversationMediaSource: String, Identifiable {
    case camera
    case photoLibrary

    var id: Self { self }
}

struct ConversationImageAttachment: Identifiable {
    let id: String
    let image: UIImage
}

private enum ConversationPhotoLibraryControlShape {
    case circle
    case capsule
}

private struct ConversationPhotoLibraryControlStyle: ViewModifier {
    let isLiquidGlass: Bool
    let shape: ConversationPhotoLibraryControlShape
    let tint: Color?

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26, *), isLiquidGlass {
            switch shape {
            case .circle:
                content
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .controlSize(.regular)
                    .tint(tint)
            case .capsule:
                content
                    .buttonStyle(.glass)
                    .buttonBorderShape(.capsule)
                    .controlSize(.regular)
                    .tint(tint)
            }
        } else {
            switch shape {
            case .circle:
                content
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.circle)
                    .controlSize(.regular)
                    .tint(tint)
            case .capsule:
                content
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .controlSize(.regular)
                    .tint(tint)
            }
        }
    }
}

@MainActor
struct ConversationMediaPanel: View {
    let source: ConversationMediaSource
    let onDismiss: () -> Void
    let onAttachments: ([ConversationImageAttachment]) -> Void

    var body: some View {
        Group {
            switch source {
            case .camera:
                ConversationCameraPanel(
                    onDismiss: onDismiss,
                    onAttachments: onAttachments
                )
            case .photoLibrary:
                ConversationPhotoLibraryPanel(
                    onDismiss: onDismiss,
                    onAttachments: onAttachments
                )
            }
        }
    }
}

@MainActor
private struct ConversationCameraPanel: View {
    let onDismiss: () -> Void
    let onAttachments: ([ConversationImageAttachment]) -> Void

    @StateObject private var camera = ConversationCameraController()
    @State private var isOptionsExpanded = false

    var body: some View {
        ZStack {
            Color.black

            switch camera.state {
            case .idle, .preparing, .ready, .capturing:
                CameraPreview(session: camera.session)
                    .opacity(camera.state == .idle ? 0 : 1)

                if camera.state == .preparing || camera.state == .idle {
                    ProgressView()
                        .tint(.white)
                        .controlSize(.regular)
                }
            case .unavailable(let message):
                cameraUnavailable(message)
            }

            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(perform: capturePhoto)
                .allowsHitTesting(camera.state == .ready)
                .accessibilityLabel("轻点画面拍照")

            VStack {
                Spacer()
                cameraControls
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
            }
        }
        .task {
            camera.start()
        }
        .onDisappear {
            camera.stop()
        }
    }

    private var cameraControls: some View {
        ZStack(alignment: .bottom) {
            HStack(alignment: .bottom) {
                panelCircleButton(systemName: "chevron.backward", action: onDismiss)
                    .accessibilityLabel("返回")
                Spacer()
                cameraOptions
            }

            Button(action: capturePhoto) {
                ZStack {
                    Circle()
                        .fill(.white.opacity(0.2))
                        .frame(width: 76, height: 76)
                    Circle()
                        .fill(.white)
                        .frame(width: 62, height: 62)
                }
            }
            .buttonStyle(.plain)
            .disabled(camera.state != .ready)
            .opacity(camera.state == .ready ? 1 : 0.55)
            .accessibilityLabel("拍照")
        }
        .frame(height: 76, alignment: .bottom)
    }

    @ViewBuilder
    private var cameraOptions: some View {
        if #available(iOS 26, *) {
            GlassEffectContainer(spacing: 12) {
                cameraOptionsStack
            }
        } else {
            cameraOptionsStack
        }
    }

    private var cameraOptionsStack: some View {
        VStack(spacing: 12) {
            if isOptionsExpanded {
                Group {
                    panelCircleButton(
                        systemName: camera.isFlashEnabled
                            ? "bolt.fill"
                            : "bolt.slash.fill",
                        tint: camera.isFlashEnabled ? .yellow : nil,
                        action: camera.toggleFlash
                    )
                    .disabled(!camera.isFlashAvailable)
                    .accessibilityLabel(camera.isFlashEnabled ? "关闭闪光灯" : "打开闪光灯")

                    panelCircleButton(
                        systemName: "camera.rotate",
                        action: camera.switchCamera
                    )
                    .disabled(!camera.canSwitchCamera)
                    .accessibilityLabel("切换前后摄像头")
                }
                .transition(
                    .move(edge: .bottom)
                        .combined(with: .scale(scale: 0.8, anchor: .bottom))
                        .combined(with: .opacity)
                )
            }

            panelCircleButton(
                systemName: isOptionsExpanded ? "xmark" : "ellipsis",
                action: toggleOptions
            )
            .accessibilityLabel(isOptionsExpanded ? "收起相机选项" : "更多相机选项")
        }
        .animation(.snappy(duration: 0.24, extraBounce: 0.08), value: isOptionsExpanded)
    }

    private func toggleOptions() {
        withAnimation(.snappy(duration: 0.24, extraBounce: 0.08)) {
            isOptionsExpanded.toggle()
        }
    }

    private func capturePhoto() {
        camera.capture { image in
            onAttachments([ConversationImageAttachment(
                id: "camera-\(UUID().uuidString)",
                image: image
            )])
        }
    }

    private func cameraUnavailable(_ message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "camera.fill")
                .font(.system(size: 34))
            Text("相机不可用")
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .foregroundStyle(.white)
        .padding(32)
    }

    @ViewBuilder
    private func panelCircleButton(
        systemName: String,
        tint: Color? = nil,
        action: @escaping () -> Void
    ) -> some View {
        let button = Button(action: action) {
            Image(systemName: systemName)
                .font(.headline)
                .frame(width: 48, height: 48)
        }

        if #available(iOS 26, *) {
            button
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .controlSize(.regular)
                .tint(tint)
        } else {
            button
                .buttonStyle(.plain)
                .foregroundStyle(tint ?? .white)
                .background(.ultraThinMaterial, in: Circle())
        }
    }
}

@MainActor
private struct ConversationPhotoLibraryPanel: View {
    let onDismiss: () -> Void
    let onAttachments: ([ConversationImageAttachment]) -> Void

    @StateObject private var library = ConversationPhotoLibraryController()
    @State private var selectedAssetIDs: [String] = []
    @State private var isPreparingAttachment = false

    private let columns = Array(
        repeating: GridItem(.flexible(minimum: 80), spacing: 3),
        count: 3
    )

    var body: some View {
        ZStack(alignment: .bottom) {
            Color(uiColor: .secondarySystemBackground)

            libraryContent

            libraryControls
                .padding(.horizontal, 24)
                .padding(.bottom, 18)
        }
        .task {
            library.load()
        }
    }

    @ViewBuilder
    private var libraryContent: some View {
        switch library.state {
        case .idle, .loading:
            ProgressView("正在载入照片…")
                .controlSize(.regular)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded:
            if library.assets.isEmpty {
                ContentUnavailableView(
                    "没有照片",
                    systemImage: "photo.on.rectangle",
                    description: Text("系统相册中暂时没有可选图片。")
                )
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 3) {
                        ForEach(library.assets, id: \.localIdentifier) { asset in
                            photoCell(asset)
                        }
                    }
                    .padding(3)
                    // Lets the final row scroll above the floating controls.
                    .padding(.bottom, 76)
                }
                .scrollIndicators(.hidden)
            }
        case .denied:
            ContentUnavailableView {
                Label("无法访问相册", systemImage: "photo.badge.exclamationmark")
            } description: {
                Text("请在系统设置中允许 Plant Talk 访问照片。")
            } actions: {
                Button("打开设置", action: openSettings)
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private func photoCell(_ asset: PHAsset) -> some View {
        let selectionIndex = selectedAssetIDs.firstIndex(of: asset.localIdentifier)

        return Button {
            withAnimation(.easeOut(duration: 0.16)) {
                if let selectionIndex {
                    selectedAssetIDs.remove(at: selectionIndex)
                } else {
                    selectedAssetIDs.append(asset.localIdentifier)
                }
            }
        } label: {
            GeometryReader { proxy in
                ZStack(alignment: .bottomTrailing) {
                    PhotoAssetThumbnail(
                        asset: asset,
                        targetSize: CGSize(
                            width: proxy.size.width * 2,
                            height: proxy.size.width * 2
                        )
                    )
                    .frame(width: proxy.size.width, height: proxy.size.width)
                    .clipped()

                    if let selectionIndex {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 30, height: 30)
                            .overlay {
                                Text("\(selectionIndex + 1)")
                                    .font(.caption.bold())
                                    .foregroundStyle(.white)
                            }
                            .padding(8)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .contentShape(Rectangle())
            }
            .aspectRatio(1, contentMode: .fit)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("选择照片")
        .accessibilityValue(
            selectionIndex.map { "已选择，第\($0 + 1)张" } ?? "未选择"
        )
    }

    @ViewBuilder
    private var libraryControls: some View {
        if #available(iOS 26, *) {
            GlassEffectContainer(spacing: 12) {
                libraryControlsContent(isLiquidGlass: true)
            }
        } else {
            libraryControlsContent(isLiquidGlass: false)
        }
    }

    @ViewBuilder
    private func libraryControlsContent(isLiquidGlass: Bool) -> some View {
        HStack {
            Button(action: onDismiss) {
                Image(systemName: "chevron.backward")
                    .font(.headline)
                    .frame(width: 48, height: 48)
            }
            .modifier(
                ConversationPhotoLibraryControlStyle(
                    isLiquidGlass: isLiquidGlass,
                    shape: .circle,
                    tint: nil
                )
            )
            .accessibilityLabel("返回")

            Spacer()

            Button(action: addSelectedPhotos) {
                Group {
                    if isPreparingAttachment {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Text(selectedAssetIDs.isEmpty ? "添加" : "添加（\(selectedAssetIDs.count)）")
                            .font(.headline)
                    }
                }
                .frame(minWidth: 112, minHeight: 48)
            }
            .modifier(
                ConversationPhotoLibraryControlStyle(
                    isLiquidGlass: isLiquidGlass,
                    shape: .capsule,
                    tint: Color.accentColor
                )
            )
            .disabled(selectedAssetIDs.isEmpty || isPreparingAttachment)
            .accessibilityLabel("添加所选照片")
        }
    }

    private func addSelectedPhotos() {
        let assetsByID = Dictionary(
            uniqueKeysWithValues: library.assets.map {
                ($0.localIdentifier, $0)
            }
        )
        let selectedAssets = selectedAssetIDs.compactMap { assetsByID[$0] }
        guard !selectedAssets.isEmpty else { return }

        isPreparingAttachment = true
        Task {
            var attachments: [ConversationImageAttachment] = []
            attachments.reserveCapacity(selectedAssets.count)

            for asset in selectedAssets {
                let image = await PhotoImageLoader.image(
                    for: asset,
                    targetSize: CGSize(width: 2048, height: 2048),
                    contentMode: .aspectFit
                )
                guard !Task.isCancelled else { return }
                guard let image else { continue }
                attachments.append(ConversationImageAttachment(
                    id: attachmentTransitionID(for: asset),
                    image: image
                ))
            }

            isPreparingAttachment = false
            guard !attachments.isEmpty else { return }
            onAttachments(attachments)
        }
    }

    private func attachmentTransitionID(for asset: PHAsset) -> String {
        "photo-library-\(asset.localIdentifier)"
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

private struct PhotoAssetThumbnail: View {
    let asset: PHAsset
    let targetSize: CGSize

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Color(uiColor: .tertiarySystemFill)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ProgressView()
            }
        }
        .task(id: asset.localIdentifier) {
            image = await PhotoImageLoader.image(
                for: asset,
                targetSize: targetSize,
                contentMode: .aspectFill
            )
        }
    }
}

private enum PhotoImageLoader {
    static func image(
        for asset: PHAsset,
        targetSize: CGSize,
        contentMode: PHImageContentMode
    ) async -> UIImage? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.resizeMode = .fast
            options.isNetworkAccessAllowed = true

            PHImageManager.default().requestImage(
                for: asset,
                targetSize: targetSize,
                contentMode: contentMode,
                options: options
            ) { image, _ in
                continuation.resume(returning: image)
            }
        }
    }
}

private final class ConversationPhotoLibraryController: ObservableObject {
    enum State {
        case idle
        case loading
        case loaded
        case denied
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var assets: [PHAsset] = []

    func load() {
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .authorized, .limited:
            fetchAssets()
        case .notDetermined:
            state = .loading
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { [weak self] status in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if status == .authorized || status == .limited {
                        self.fetchAssets()
                    } else {
                        self.state = .denied
                    }
                }
            }
        default:
            state = .denied
        }
    }

    private func fetchAssets() {
        state = .loading
        let options = PHFetchOptions()
        options.sortDescriptors = [
            NSSortDescriptor(key: "creationDate", ascending: false)
        ]
        let result = PHAsset.fetchAssets(with: .image, options: options)
        var fetched: [PHAsset] = []
        fetched.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in
            fetched.append(asset)
        }
        assets = fetched
        state = .loaded
    }
}

private final class ConversationCameraController: NSObject, ObservableObject,
    AVCapturePhotoCaptureDelegate {
    enum State: Equatable {
        case idle
        case preparing
        case ready
        case capturing
        case unavailable(String)
    }

    let session = AVCaptureSession()

    @Published private(set) var state: State = .idle

    private let photoOutput = AVCapturePhotoOutput()
    private let sessionQueue = DispatchQueue(
        label: "com.example.PlantTalkBLE.conversation-camera",
        qos: .userInitiated
    )
    private var isConfigured = false
    private var captureHandler: ((UIImage) -> Void)?
    private var cameraInput: AVCaptureDeviceInput?
    private var cameraPosition: AVCaptureDevice.Position = .back
    // Accessed only from sessionQueue so a capture always observes the latest choice.
    private var wantsFlash = false

    @Published private(set) var isFlashEnabled = false
    @Published private(set) var isFlashAvailable = false
    @Published private(set) var canSwitchCamera = false

    func start() {
        guard state == .idle else { return }
        state = .preparing

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureAndStart()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if granted {
                        self.configureAndStart()
                    } else {
                        self.state = .unavailable("请在系统设置中允许 Plant Talk 使用相机。")
                    }
                }
            }
        default:
            state = .unavailable("请在系统设置中允许 Plant Talk 使用相机。")
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }

    func capture(onCapture: @escaping (UIImage) -> Void) {
        guard state == .ready else { return }
        state = .capturing
        captureHandler = onCapture

        sessionQueue.async { [weak self] in
            guard let self else { return }
            let settings = AVCapturePhotoSettings()
            settings.photoQualityPrioritization = .speed
            // The current camera may have changed since the control was shown.
            // Verify again immediately before making the photo request.
            settings.flashMode = self.wantsFlash && self.supportsPhotoFlash
                ? .on
                : .off
            self.photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }

    func toggleFlash() {
        sessionQueue.async { [weak self] in
            guard let self, self.supportsPhotoFlash else { return }
            self.wantsFlash.toggle()
            let isFlashEnabled = self.wantsFlash

            DispatchQueue.main.async {
                self.isFlashEnabled = isFlashEnabled
            }
        }
    }

    func switchCamera() {
        guard state != .capturing, canSwitchCamera else { return }

        sessionQueue.async { [weak self] in
            guard let self else { return }
            let nextPosition: AVCaptureDevice.Position = self.cameraPosition == .back
                ? .front
                : .back

            do {
                try self.replaceCameraInput(with: nextPosition)
            } catch {
                DispatchQueue.main.async {
                    self.state = .unavailable(error.localizedDescription)
                }
            }
        }
    }

    private func configureAndStart() {
        sessionQueue.async { [weak self] in
            guard let self else { return }

            do {
                if !self.isConfigured {
                    try self.configureSession()
                    self.isConfigured = true
                }
                if !self.session.isRunning {
                    self.session.startRunning()
                }
                // AVCapturePhotoOutput reports its supported flash modes
                // reliably only after the session is running on real devices.
                self.publishCameraCapabilities()
                DispatchQueue.main.async {
                    self.state = .ready
                }
            } catch {
                DispatchQueue.main.async {
                    self.state = .unavailable(error.localizedDescription)
                }
            }
        }
    }

    private func configureSession() throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .photo

        let input = try makeCameraInput(position: .back)
        guard session.canAddInput(input), session.canAddOutput(photoOutput) else {
            throw ConversationCameraError.configurationFailed
        }
        session.addInput(input)
        session.addOutput(photoOutput)
        // Chat attachments favor a responsive shutter over multi-frame photo
        // processing. Configure this before the session starts to avoid a
        // capture-time render-pipeline rebuild.
        photoOutput.maxPhotoQualityPrioritization = .speed
        let preparedSettings = AVCapturePhotoSettings()
        preparedSettings.photoQualityPrioritization = .speed
        photoOutput.setPreparedPhotoSettingsArray(
            [preparedSettings],
            completionHandler: nil
        )
        cameraInput = input
        cameraPosition = .back
    }

    private func makeCameraInput(
        position: AVCaptureDevice.Position
    ) throws -> AVCaptureDeviceInput {
        guard let device = AVCaptureDevice.default(
            .builtInWideAngleCamera,
            for: .video,
            position: position
        ) else {
            throw ConversationCameraError.unavailable
        }
        return try AVCaptureDeviceInput(device: device)
    }

    private func replaceCameraInput(
        with position: AVCaptureDevice.Position
    ) throws {
        let input = try makeCameraInput(position: position)

        session.beginConfiguration()
        if let currentInput = cameraInput {
            session.removeInput(currentInput)
        }

        guard session.canAddInput(input) else {
            if let cameraInput, session.canAddInput(cameraInput) {
                session.addInput(cameraInput)
            }
            session.commitConfiguration()
            throw ConversationCameraError.configurationFailed
        }

        session.addInput(input)
        cameraInput = input
        cameraPosition = position
        session.commitConfiguration()
        publishCameraCapabilities()
    }

    private func publishCameraCapabilities() {
        let supportsFlash = supportsPhotoFlash
        let supportsFrontCamera = AVCaptureDevice.default(
            .builtInWideAngleCamera,
            for: .video,
            position: .front
        ) != nil
        let supportsBackCamera = AVCaptureDevice.default(
            .builtInWideAngleCamera,
            for: .video,
            position: .back
        ) != nil

        if !supportsFlash {
            wantsFlash = false
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isFlashAvailable = supportsFlash
            if !supportsFlash {
                self.isFlashEnabled = false
            }
            self.canSwitchCamera = supportsFrontCamera && supportsBackCamera
        }
    }

    private var supportsPhotoFlash: Bool {
        guard let cameraInput else { return false }
        return cameraInput.device.hasFlash
            && photoOutput.supportedFlashModes.contains(.on)
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        if let error {
            finishCapture(with: .failure(error))
            return
        }
        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard let data = photo.fileDataRepresentation() else {
                self.finishCapture(
                    with: .failure(ConversationCameraError.invalidImage)
                )
                return
            }
            guard let image = self.makeDisplayReadyAttachment(from: data) else {
                self.finishCapture(
                    with: .failure(ConversationCameraError.invalidImage)
                )
                return
            }
            self.finishCapture(with: .success(image))
        }
    }

    private func makeDisplayReadyAttachment(from data: Data) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: 2048
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            options as CFDictionary
        ) else {
            return nil
        }
        return UIImage(cgImage: image)
    }

    private func finishCapture(with result: Result<UIImage, Error>) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            defer {
                self.captureHandler = nil
            }
            switch result {
            case .success(let image):
                self.state = .ready
                self.captureHandler?(image)
            case .failure(let error):
                self.state = .unavailable(error.localizedDescription)
            }
        }
    }
}

private enum ConversationCameraError: LocalizedError {
    case unavailable
    case configurationFailed
    case invalidImage

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "当前设备没有可用的相机。请在 iPhone 真机上使用此功能。"
        case .configurationFailed:
            "无法启动相机，请稍后重试。"
        case .invalidImage:
            "无法读取刚刚拍摄的照片。"
        }
    }
}

private struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> CameraPreviewView {
        let view = CameraPreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: CameraPreviewView, context: Context) {
        uiView.previewLayer.session = session
    }
}

private final class CameraPreviewView: UIView {
    override class var layerClass: AnyClass {
        AVCaptureVideoPreviewLayer.self
    }

    var previewLayer: AVCaptureVideoPreviewLayer {
        layer as! AVCaptureVideoPreviewLayer
    }
}

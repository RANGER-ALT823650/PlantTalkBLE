import SwiftUI
import UIKit
import XCTest

/// Temporary probe: does an outset clip path let a UIKit-hosted subtree's
/// out-of-region painting survive? Delete once answered.
private struct ProbeOutsetRoundedRectangle: Shape {
    let cornerRadius: CGFloat
    let outsets: EdgeInsets

    func path(in rect: CGRect) -> Path {
        let expanded = CGRect(
            x: rect.minX - outsets.leading,
            y: rect.minY - outsets.top,
            width: rect.width + outsets.leading + outsets.trailing,
            height: rect.height + outsets.top + outsets.bottom
        )
        return Path(
            roundedRect: expanded,
            cornerRadius: cornerRadius,
            style: .continuous
        )
    }
}

/// Paints a blue layer that deliberately overflows its SwiftUI region by the
/// given insets, mimicking how a NavigationStack paints across the full window.
private struct OverdrawRepresentable: UIViewRepresentable {
    let overflow: UIEdgeInsets

    func makeUIView(context: Context) -> OverdrawView {
        let view = OverdrawView()
        view.overflow = overflow
        return view
    }

    func updateUIView(_ uiView: OverdrawView, context: Context) {
        uiView.overflow = overflow
        uiView.setNeedsLayout()
    }
}

private final class OverdrawView: UIView {
    var overflow: UIEdgeInsets = .zero
    private let paint = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        clipsToBounds = false
        paint.backgroundColor = .blue
        addSubview(paint)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        paint.frame = bounds.inset(by: overflow)
    }
}

@MainActor
final class OutsetClipProbeTests: XCTestCase {
    private let windowSize = CGSize(width: 393, height: 852)
    private let topInset: CGFloat = 59
    private let bottomInset: CGFloat = 34

    /// Renders the probe and returns the blue-pixel coverage of the strip that
    /// sits above the safe-area region, i.e. the part a plain clip shears off.
    private func topStripIsPainted<S: Shape>(clip: S) -> Bool {
        let regionHeight = windowSize.height - topInset - bottomInset
        let probe = OverdrawRepresentable(
            overflow: UIEdgeInsets(
                top: -topInset,
                left: 0,
                bottom: -bottomInset,
                right: 0
            )
        )
        .frame(width: windowSize.width, height: regionHeight)
        .clipShape(clip)
        .offset(y: topInset)
        .frame(
            width: windowSize.width,
            height: windowSize.height,
            alignment: .top
        )

        let host = UIHostingController(rootView: probe)
        let window = UIWindow(frame: CGRect(origin: .zero, size: windowSize))
        window.rootViewController = host
        window.isHidden = false
        host.view.frame = CGRect(origin: .zero, size: windowSize)
        window.layoutIfNeeded()
        host.view.layoutIfNeeded()

        let renderer = UIGraphicsImageRenderer(size: windowSize)
        let image = renderer.image { _ in
            window.drawHierarchy(
                in: CGRect(origin: .zero, size: windowSize),
                afterScreenUpdates: true
            )
        }
        return isBlue(image, at: CGPoint(x: windowSize.width / 2, y: 20))
    }

    private func isBlue(_ image: UIImage, at point: CGPoint) -> Bool {
        guard let cgImage = image.cgImage else { return false }
        let scale = image.scale
        let x = Int(point.x * scale)
        let y = Int(point.y * scale)
        var pixel: [UInt8] = [0, 0, 0, 0]
        guard let context = CGContext(
            data: &pixel,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return false }
        context.draw(
            cgImage,
            in: CGRect(x: -x, y: -(cgImage.height - 1 - y), width: cgImage.width, height: cgImage.height)
        )
        return pixel[2] > 150 && pixel[0] < 100
    }

    func testPlainClipShearsTheOutOfRegionStrip() {
        let painted = topStripIsPainted(
            clip: RoundedRectangle(cornerRadius: 55, style: .continuous)
        )
        XCTAssertFalse(painted, "plain clip unexpectedly kept the strip")
    }

    func testOutsetClipKeepsTheOutOfRegionStrip() {
        let painted = topStripIsPainted(
            clip: ProbeOutsetRoundedRectangle(
                cornerRadius: 55,
                outsets: EdgeInsets(
                    top: topInset,
                    leading: 0,
                    bottom: bottomInset,
                    trailing: 0
                )
            )
        )
        XCTAssertTrue(painted, "outset clip failed to keep the strip")
    }
}



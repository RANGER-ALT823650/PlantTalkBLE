import CoreGraphics
import XCTest
@testable import PlantTalkBLE

final class PlantArtworkCropTests: XCTestCase {
    func testAspectFillOnlyAllowsMovementAlongOverflowingAxis() {
        let maximum = PlantArtworkCrop.maximumOffset(
            imageSize: CGSize(width: 400, height: 300),
            frameSize: CGSize(width: 300, height: 400),
            scale: 1
        )

        XCTAssertEqual(maximum.width, 116.666_666, accuracy: 0.001)
        XCTAssertEqual(maximum.height, 0, accuracy: 0.001)
    }

    func testOffsetIsClampedSoTheFrameNeverShowsEmptySpace() {
        let offset = PlantArtworkCrop.clampedOffset(
            CGSize(width: 1_000, height: -1_000),
            imageSize: CGSize(width: 300, height: 400),
            frameSize: CGSize(width: 300, height: 400),
            scale: 2
        )

        XCTAssertEqual(offset.width, 150, accuracy: 0.001)
        XCTAssertEqual(offset.height, -200, accuracy: 0.001)
    }

    func testNormalizedOffsetScalesWithTheFrame() {
        let normalized = CGSize(width: 0.2, height: -0.15)
        let firstFrame = CGSize(width: 300, height: 400)
        let secondFrame = CGSize(width: 180, height: 240)

        let first = PlantArtworkCrop.pointOffset(from: normalized, in: firstFrame)
        let second = PlantArtworkCrop.pointOffset(from: normalized, in: secondFrame)

        XCTAssertEqual(first.width, 60, accuracy: 0.001)
        XCTAssertEqual(first.height, -60, accuracy: 0.001)
        XCTAssertEqual(second.width, 36, accuracy: 0.001)
        XCTAssertEqual(second.height, -36, accuracy: 0.001)
        XCTAssertEqual(
            PlantArtworkCrop.normalizedOffset(from: second, in: secondFrame).width,
            normalized.width,
            accuracy: 0.001
        )
    }
}

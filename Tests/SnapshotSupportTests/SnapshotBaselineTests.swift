import CoreGraphics
import Foundation
import Testing
@testable import SnapshotSupport

@Suite("Snapshot baselines")
struct SnapshotBaselineTests {
    /// A solid image with an optional block of another colour, drawn directly so the fixture does
    /// not depend on the code under test.
    private func image(width: Int = 100, height: Int = 100, changedPixels: Int = 0) -> CGImage {
        var pixels = [UInt8]()
        for index in 0..<(width * height) {
            pixels += index < changedPixels ? [255, 255, 255, 255] : [20, 20, 22, 255]
        }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )!
    }

    @Test("A rendering identical to its baseline matches")
    func identicalMatches() {
        let result = SnapshotBaseline.check(actual: image(), baseline: image())
        #expect(result.verdict == .matches)
        #expect(result.difference == nil)
    }

    @Test("Without a baseline the verdict is missing, never a match")
    func missingBaseline() {
        #expect(SnapshotBaseline.check(actual: image(), baseline: nil).verdict == .missing)
    }

    @Test("A handful of changed pixels, like an antialiasing edge, still matches")
    func tinyChangeMatches() {
        // 10 of 10,000 pixels is 0.1%, under the 0.2% allowance.
        let result = SnapshotBaseline.check(actual: image(changedPixels: 10), baseline: image())
        #expect(result.verdict == .matches)
    }

    @Test("A visible change fails and paints the difference")
    func visibleChangeFails() {
        // 100 of 10,000 pixels is 1%, five times the allowance.
        let result = SnapshotBaseline.check(actual: image(changedPixels: 100), baseline: image())
        guard case .changed(let score) = result.verdict else {
            Issue.record("Expected a change, got \(result.verdict)")
            return
        }
        #expect(score.mismatchedFraction == 0.01)
        #expect(result.difference != nil)
    }

    @Test("A change of size fails even when every pixel would match after scaling")
    func resizedFails() {
        let result = SnapshotBaseline.check(actual: image(width: 50, height: 50), baseline: image())
        guard case .changed(let score) = result.verdict else {
            Issue.record("Expected a change, got \(result.verdict)")
            return
        }
        #expect(!score.sizesMatched)
    }
}

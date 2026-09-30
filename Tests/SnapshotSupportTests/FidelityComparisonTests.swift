import CoreGraphics
import Foundation
import Testing
@testable import SnapshotSupport

@Suite("Fidelity comparison")
struct FidelityComparisonTests {
    /// A solid image, drawn directly so the fixture does not depend on the code under test.
    private func solid(red: UInt8, green: UInt8, blue: UInt8, width: Int = 4, height: Int = 4) -> CGImage {
        var pixels = [UInt8]()
        for _ in 0..<(width * height) { pixels += [red, green, blue, 255] }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )!
    }

    @Test("Identical images score as a full match")
    func identicalImagesMatch() {
        let image = solid(red: 30, green: 30, blue: 32)
        let score = FidelityComparison.compare(image, with: image).score
        #expect(score.mismatchedFraction == 0)
        #expect(score.meanDelta == 0)
        #expect(score.sizesMatched)
    }

    @Test("A difference inside the tolerance still counts as a match")
    func smallDifferencesAreTolerated() {
        let score = FidelityComparison.compare(
            solid(red: 100, green: 100, blue: 100),
            with: solid(red: 120, green: 100, blue: 100)
        ).score
        #expect(score.mismatchedFraction == 0)
        #expect(score.meanDelta > 0)
    }

    @Test("A difference beyond the tolerance marks every pixel")
    func largeDifferencesMismatch() {
        let result = FidelityComparison.compare(
            solid(red: 0, green: 0, blue: 0),
            with: solid(red: 255, green: 255, blue: 255)
        )
        #expect(result.score.mismatchedFraction == 1)
        #expect(result.difference?.width == 4)
    }

    @Test("Images of different sizes are compared at the design's size and say so")
    func mismatchedSizesAreReported() {
        let score = FidelityComparison.compare(
            solid(red: 10, green: 10, blue: 10, width: 8, height: 8),
            with: solid(red: 10, green: 10, blue: 10)
        ).score
        #expect(!score.sizesMatched)
        #expect(score.pixelsWide == 4)
        #expect(score.mismatchedFraction == 0)
    }

    @Test("A section is cropped from its board at the export scale")
    func sectionFrameReadsTheManifestRect() throws {
        let json = #"{"id":"a","board":"Main","rect":[8,8,264,884],"title":"Navigator"}"#
        let section = try JSONDecoder().decode(DesignReferenceCatalog.Section.self, from: Data(json.utf8))
        #expect(section.frame == CGRect(x: 8, y: 8, width: 264, height: 884))
    }
}

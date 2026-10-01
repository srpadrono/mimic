import CoreGraphics
import Foundation

/// How far a rendering is from its design image, pixel by pixel.
///
/// A score, not a verdict: the design is drawn by WebKit and the app by AppKit, so antialiasing and
/// text rasterisation never agree exactly. The number is for tracking a section towards its artboard
/// and for noticing when it drifts away; nothing fails on it.
public struct FidelityScore: Codable, Sendable, Equatable {
    /// Pixels whose largest channel difference exceeds `FidelityComparison.tolerance`, as a fraction.
    public var mismatchedFraction: Double
    /// Mean absolute channel difference over every pixel, from 0 to 1.
    public var meanDelta: Double
    public var pixelsWide: Int
    public var pixelsHigh: Int
    /// `false` when the rendering and the design differ in size, and the rendering was scaled to
    /// the design's size before comparing.
    public var sizesMatched: Bool

    /// 1 when every pixel is within tolerance.
    public var similarity: Double { 1 - mismatchedFraction }
}

public enum FidelityComparison {
    /// A channel difference at or below this (out of 255) counts as a match.
    public static let tolerance: UInt8 = 24

    /// Compares `actual` with `reference` and paints the differences.
    ///
    /// - Returns: the score, and a difference image: the design dimmed, with mismatched pixels in
    ///   magenta at a strength that follows the size of the difference.
    public static func compare(_ actual: CGImage, with reference: CGImage) -> (score: FidelityScore, difference: CGImage?) {
        let width = reference.width
        let height = reference.height
        let sizesMatched = actual.width == width && actual.height == height
        guard let actualPixels = rgba(actual, width: width, height: height),
              let referencePixels = rgba(reference, width: width, height: height) else {
            return (FidelityScore(mismatchedFraction: 1, meanDelta: 1, pixelsWide: width, pixelsHigh: height,
                                  sizesMatched: sizesMatched), nil)
        }

        var difference = [UInt8](repeating: 0, count: width * height * 4)
        var mismatched = 0
        var totalDelta = 0.0
        for pixel in 0..<(width * height) {
            let offset = pixel * 4
            var largest: UInt8 = 0
            for channel in 0..<3 {
                let a = actualPixels[offset + channel]
                let b = referencePixels[offset + channel]
                let delta = a > b ? a - b : b - a
                totalDelta += Double(delta)
                largest = max(largest, delta)
            }
            let isMismatch = largest > tolerance
            if isMismatch { mismatched += 1 }
            for channel in 0..<3 {
                difference[offset + channel] = referencePixels[offset + channel] / 4
            }
            if isMismatch {
                difference[offset] = max(difference[offset], largest)
                difference[offset + 2] = max(difference[offset + 2], largest)
            }
            difference[offset + 3] = 255
        }

        let pixels = Double(width * height)
        let score = FidelityScore(
            mismatchedFraction: pixels > 0 ? Double(mismatched) / pixels : 1,
            meanDelta: pixels > 0 ? totalDelta / (pixels * 3 * 255) : 1,
            pixelsWide: width,
            pixelsHigh: height,
            sizesMatched: sizesMatched
        )
        return (score, image(from: difference, width: width, height: height))
    }

    /// Redraws `image` as premultiplied sRGB RGBA at `width` × `height`.
    static func rgba(_ image: CGImage, width: Int, height: Int) -> [UInt8]? {
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? pixels : nil
    }

    static func image(from pixels: [UInt8], width: Int, height: Int) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }
}

import CoreGraphics
import Foundation

/// Compares a rendering with the last approved rendering of the same view.
///
/// A design fidelity score measures the distance from a WebKit-drawn artboard and never fails. A
/// baseline is different: it is an earlier AppKit rendering of the same gallery entry on the same CI
/// macOS image, so the two agree apart from antialiasing. A change beyond `allowedMismatch` is
/// either a regression or an intended change that needs its baseline recorded again.
public enum SnapshotBaseline {
    /// The share of pixels that may differ by more than `FidelityComparison.tolerance` before a
    /// rendering counts as changed. Small enough that a moved control or a resized row fails; large
    /// enough that a shifted antialiasing edge does not.
    public static let allowedMismatch = 0.002

    public enum Verdict: Equatable, Sendable {
        case matches
        /// No approved rendering exists yet.
        case missing
        /// The rendering differs from its baseline, or changed size.
        case changed(FidelityScore)
    }

    public struct Result {
        public var verdict: Verdict
        /// The baseline dimmed with the changed pixels painted, when there was a baseline.
        public var difference: CGImage?
    }

    public static func check(actual: CGImage, baseline: CGImage?, allowedMismatch: Double = allowedMismatch) -> Result {
        guard let baseline else { return Result(verdict: .missing, difference: nil) }
        let comparison = FidelityComparison.compare(actual, with: baseline)
        let score = comparison.score
        if score.sizesMatched, score.mismatchedFraction <= allowedMismatch {
            return Result(verdict: .matches, difference: nil)
        }
        return Result(verdict: .changed(score), difference: comparison.difference)
    }
}

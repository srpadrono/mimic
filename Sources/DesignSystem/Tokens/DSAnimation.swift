import SwiftUI

/// Animation durations and curves. Repeating animation is gated on Reduce Motion by the caller.
nonisolated public enum DSAnimation {
    /// 0.1s — hover and press feedback.
    public static let fast: Double = 0.10
    /// 0.2s — selection, expand and collapse.
    public static let normal: Double = 0.20
    /// 0.3s — a panel appearing or hiding.
    public static let slow: Double = 0.30

    /// The spring used when a panel shows or hides.
    public static var panel: Animation { .spring(duration: slow, bounce: 0) }

    public static func spring(_ duration: Double = normal, bounce: Double = 0.15) -> Animation {
        .spring(duration: duration, bounce: bounce)
    }
}

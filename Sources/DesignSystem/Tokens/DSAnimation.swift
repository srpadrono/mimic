import SwiftUI

/// Animation duration and curve tokens.
public enum DSAnimation {
    /// 0.06s — instantaneous feedback (button press, toggle snap)
    public static let micro: Double = 0.06
    /// 0.1s — micro-interactions (hover, press feedback, copied toast)
    public static let fast: Double = 0.10
    /// 0.2s — standard transitions (expand/collapse, selection, panel toggle)
    public static let normal: Double = 0.20
    /// 0.35s — larger transitions (drawer slide, inspector reveal)
    public static let slow: Double = 0.35

    /// Spring animation with configurable duration and bounce.
    public static func spring(_ duration: Double = normal, bounce: Double = 0.15) -> Animation {
        .spring(duration: duration, bounce: bounce)
    }
}

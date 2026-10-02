import SwiftUI

/// Type roles, after Apple's macOS text styles. Six sizes: 20, 15, 13, 12, 11, and SF Mono 12.
public enum DSTypography {
    /// 28pt bold — the welcome window's app name.
    public static let largeTitle: Font = .system(size: 28, weight: .bold)
    /// 20pt semibold — sheet and editor titles.
    public static let title: Font = .system(size: 20, weight: .semibold)
    /// 15pt semibold — the scenario or journey being edited, alert titles.
    public static let headline: Font = .system(size: 15, weight: .semibold)

    /// 13pt — everything you read and edit.
    public static let body: Font = .system(size: 13, weight: .regular)
    public static let bodyMedium: Font = .system(size: 13, weight: .medium)
    public static let bodySemibold: Font = .system(size: 13, weight: .semibold)

    /// 12pt — secondary text, field values in dense rows, segment titles.
    public static let callout: Font = .system(size: 12, weight: .regular)
    public static let calloutMedium: Font = .system(size: 12, weight: .medium)

    /// 11pt — timestamps, units, notes.
    public static let caption: Font = .system(size: 11, weight: .regular)
    /// 11pt semibold — section and column headers.
    public static let captionSemibold: Font = .system(size: 11, weight: .semibold)

    // MARK: - Code

    /// SF Mono 12 — paths, bodies, headers.
    public static let code: Font = .system(size: 12, weight: .regular, design: .monospaced)
    /// SF Mono 13 — the request field, where the route is the thing being edited.
    public static let codeLarge: Font = .system(size: 13, weight: .regular, design: .monospaced)
    /// SF Mono 11 semibold — the method label.
    public static let method: Font = .system(size: 11, weight: .semibold, design: .monospaced)
    /// SF Mono 12 medium — a status code beside its dot.
    public static let status: Font = .system(size: 12, weight: .medium, design: .monospaced)

    // MARK: - Figures

    /// Numbers that sit in a column or tick while you watch them.
    public enum Figure {
        /// SF Mono 12 with tabular digits.
        public static let regular: Font = DSTypography.code.monospacedDigit()
        /// 15pt semibold — summary figures in the inspector.
        public static let large: Font = Font.system(size: 15, weight: .semibold, design: .monospaced)
            .monospacedDigit()
    }

    /// Line spacing for wrapped text. SwiftUI adds this gap between lines.
    public enum Leading {
        /// Paragraphs of 12pt text: 17pt lines.
        public static let callout: CGFloat = 5
        /// Code: 19pt lines at SF Mono 12.
        public static let code: CGFloat = 5
        /// Short paragraphs on empty screens: 17pt lines at 12pt and 18pt at 13pt, measured against
        /// the EmptyStates artboard. `callout` draws about 20pt lines at 12pt.
        public static let tight: CGFloat = 2
    }
}

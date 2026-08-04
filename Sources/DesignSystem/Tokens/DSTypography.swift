import SwiftUI

/// Typography role tokens — SF Pro + SF Mono, refined scale.
public enum DSTypography {
    // MARK: - Body scale

    /// SF Pro 13px regular — default body text
    public static let body: Font = .system(size: 13, weight: .regular)
    /// SF Pro 13px medium — emphasized body without bold
    public static let bodyMedium: Font = .system(size: 13, weight: .medium)
    /// SF Pro 13px semibold — strong emphasis, active states
    public static let bodyBold: Font = .system(size: 13, weight: .semibold)

    // MARK: - Small scale

    /// SF Pro 11px regular — labels, captions
    public static let label: Font = .system(size: 11, weight: .regular)
    /// SF Pro 10px medium — timestamps, footnotes, tertiary labels
    public static let caption: Font = .system(size: 10, weight: .medium)

    // MARK: - Heading scale

    /// SF Pro 14px medium — sub-section headings, panel titles
    public static let subheading: Font = .system(size: 14, weight: .medium)
    /// SF Pro 16px semibold — section headings
    public static let heading: Font = .system(size: 16, weight: .semibold)
    /// SF Pro 20px semibold — sheet titles, dialog headings
    public static let title: Font = .system(size: 20, weight: .semibold)
    /// SF Pro 28px bold — display / hero text
    public static let display: Font = .system(size: 28, weight: .bold)

    // MARK: - Code scale

    /// SF Mono 11px regular — compact code in sidebar rows, log timestamps
    public static let codeSmall: Font = .system(size: 11, weight: .regular, design: .monospaced)
    /// SF Mono 12px regular — JSON, paths, ports, code
    public static let code: Font = .system(size: 12, weight: .regular, design: .monospaced)
    /// SF Mono 12px medium — method badges, emphasized code
    public static let codeBold: Font = .system(size: 12, weight: .medium, design: .monospaced)
    /// SF Mono 13px regular — prominent code like base URL
    public static let codeLarge: Font = .system(size: 13, weight: .regular, design: .monospaced)
}

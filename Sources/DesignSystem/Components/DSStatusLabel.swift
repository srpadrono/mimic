import SwiftUI

/// A status as a dot and the code in one colour. One style everywhere, never a fill.
public struct DSStatusLabel: View {
    public enum Style {
        /// SF Mono: a code in a row or table.
        case code
        /// SF Pro: a word like "Running" or "3 unmatched".
        case text
    }

    /// How large a code is drawn.
    public enum Size {
        /// SF Mono 12: rows, tables and the inspector.
        case regular
        /// SF Mono 11: the end of a navigator row, where the code is a footnote to the route.
        case compact
    }

    private let text: String
    private let color: Color
    private let showsDot: Bool
    private let style: Style
    private let size: Size

    @Environment(\.backgroundProminence) private var prominence

    /// An HTTP status, optionally followed by its reason phrase. `nil` is a transport failure.
    /// A focused navigator's selected row draws the code alone, white on the selection, so it passes
    /// `showsDot: false` there.
    public init(statusCode: Int?, reason: String? = nil, showsDot: Bool = true, size: Size = .regular) {
        if let statusCode {
            text = reason.map { "\(statusCode) \($0)" } ?? "\(statusCode)"
            color = DSColors.httpStatusColor(for: statusCode)
        } else {
            text = reason ?? "Failed"
            color = DSColors.error
        }
        self.showsDot = showsDot
        style = .code
        self.size = size
    }

    /// A state in words, coloured by its tone.
    public init(_ text: String, color: Color, showsDot: Bool = true, style: Style = .text) {
        self.text = text
        self.color = color
        self.showsDot = showsDot
        self.style = style
        size = .regular
    }

    public var body: some View {
        HStack(spacing: 6) {
            if showsDot {
                DSStatusDot(ink)
            }
            Text(text)
                .font(font)
                .monospacedDigit()
                .lineLimit(1)
        }
        .foregroundStyle(ink)
        .fixedSize()
        .accessibilityElement(children: .combine)
    }

    private var font: Font {
        switch (style, size) {
        case (.code, .regular): DSTypography.status
        case (.code, .compact): DSTypography.statusCompact
        case (.text, _): DSTypography.calloutMedium
        }
    }

    private var ink: Color {
        prominence == .increased ? .white : color
    }
}

/// The 7 pt dot a status wears beside its code or word, in the status's colour.
public struct DSStatusDot: View {
    /// 7 pt: the dot's diameter.
    public static let diameter: CGFloat = 7

    private let color: Color

    public init(_ color: Color) {
        self.color = color
    }

    public var body: some View {
        Circle()
            .fill(color)
            .frame(width: Self.diameter, height: Self.diameter)
            .accessibilityHidden(true)
    }
}

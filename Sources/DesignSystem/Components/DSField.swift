import SwiftUI

/// The chrome every editable field shares: a quiet fill, a hairline, and an accent border with a halo
/// while focused. Invalid fields keep a red border whether or not they are focused.
///
/// ``EnvironmentValues/dsShowsFocus`` draws the focused look without keyboard focus, for a gallery
/// render whose off-screen window can never hold focus.
public struct DSFieldChrome: ViewModifier {
    private let height: CGFloat
    private let cornerRadius: CGFloat
    private let isFocused: Bool
    private let isInvalid: Bool
    private let horizontalPadding: CGFloat
    @Environment(\.dsSurface) private var surface
    @Environment(\.dsShowsFocus) private var showsFocus

    public init(height: CGFloat = DSControlHeight.regular, cornerRadius: CGFloat = DSCornerRadius.field,
                isFocused: Bool, isInvalid: Bool = false, horizontalPadding: CGFloat = DSSpacing.sm) {
        self.height = height
        self.cornerRadius = cornerRadius
        self.isFocused = isFocused
        self.isInvalid = isInvalid
        self.horizontalPadding = horizontalPadding
    }

    /// Focused for real, or drawn as focused by the environment.
    private var drawsFocus: Bool {
        isFocused || showsFocus
    }

    public func body(content: Content) -> some View {
        content
            .padding(.horizontal, horizontalPadding)
            .frame(height: height)
            .background {
                RoundedRectangle(cornerRadius: cornerRadius).fill(surface.fieldFill)
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(border, lineWidth: drawsFocus || isInvalid ? DSStroke.emphasis : DSStroke.hairline)
                    // Drawn over the field's content, so it must not take the pointer: over an AppKit
                    // control, such as the request bar's method menu, SwiftUI otherwise keeps the
                    // click for the border and the control never sees it.
                    .allowsHitTesting(false)
            }
            .overlay {
                if drawsFocus || isInvalid {
                    RoundedRectangle(cornerRadius: cornerRadius + DSStroke.focusHalo / 2)
                        .stroke(isInvalid ? DSColors.errorBackground : DSColors.focusRing,
                                lineWidth: DSStroke.focusHalo)
                        .padding(-DSStroke.focusHalo / 2)
                        .allowsHitTesting(false)
                }
            }
            .animation(.easeOut(duration: DSAnimation.fast), value: isFocused)
    }

    private var border: Color {
        if isInvalid { return DSColors.error }
        if drawsFocus { return DSColors.accent }
        return surface.fieldBorder
    }
}

public extension View {
    func dsFieldChrome(height: CGFloat = DSControlHeight.regular, cornerRadius: CGFloat = DSCornerRadius.field,
                       isFocused: Bool, isInvalid: Bool = false,
                       horizontalPadding: CGFloat = DSSpacing.sm) -> some View {
        modifier(DSFieldChrome(height: height, cornerRadius: cornerRadius, isFocused: isFocused,
                               isInvalid: isInvalid, horizontalPadding: horizontalPadding))
    }
}

/// A label column beside its control, as sheets and the inspector lay out forms.
///
/// The label column is `labelWidth` when given, else the enclosing form's ``dsFormLabelWidth(_:)``.
///
/// With `.top` alignment, for a control that can grow a message underneath, the label is centred on
/// the control's first `controlHeight` points, as the boards' `align-items: center` rows draw it.
public struct DSFormRow<Content: View>: View {
    private let label: String
    private let labelWidth: CGFloat?
    private let alignment: VerticalAlignment
    private let controlHeight: CGFloat
    private let content: Content

    @Environment(\.dsFormLabelWidth) private var formLabelWidth

    public init(_ label: String, labelWidth: CGFloat? = nil,
                alignment: VerticalAlignment = .center, controlHeight: CGFloat = DSControlHeight.large,
                @ViewBuilder content: () -> Content) {
        self.label = label
        self.labelWidth = labelWidth
        self.alignment = alignment
        self.controlHeight = controlHeight
        self.content = content()
    }

    public var body: some View {
        HStack(alignment: alignment, spacing: DSSpacing.md) {
            Text(label)
                .font(DSTypography.callout)
                .foregroundStyle(DSColors.labelSecondary)
                .lineLimit(1)
                .frame(width: labelWidth ?? formLabelWidth, height: alignment == .top ? controlHeight : nil,
                       alignment: .trailing)
                .accessibilityHidden(true)
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A red message under a field, with a glyph so it survives without colour.
public struct DSValidationMessage: View {
    private let message: String
    private let identifier: String

    public init(_ message: String, identifier: String) {
        self.message = message
        self.identifier = identifier
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DSSpacing.xs) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: DSGlyph.field - 1, weight: .semibold))
                .accessibilityHidden(true)
            Text(message)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(DSTypography.caption)
        .foregroundStyle(DSColors.error)
        .accessibilityElement()
        .accessibilityLabel(message)
        .accessibilityValue(message)
        .accessibilityIdentifier(identifier)
    }
}

/// A one-line hint under a form row, aligned with the controls, on the sheet boards' 11/15 line.
public struct DSFormHint: View {
    private let text: String
    private let indent: CGFloat

    public init(_ text: String, indent: CGFloat = DSLayout.sheetLabelWidth) {
        self.text = text
        self.indent = indent
    }

    /// The boards' `.hint { line-height: 15px }`.
    static let lineHeight: CGFloat = 15

    public var body: some View {
        Text(text)
            .font(DSTypography.caption)
            .foregroundStyle(DSColors.labelTertiary)
            .frame(minHeight: Self.lineHeight, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, indent)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private nonisolated struct DSShowsFocusKey: EnvironmentKey {
    static let defaultValue = false
}

public nonisolated extension EnvironmentValues {
    /// Draws every ``DSFieldChrome`` inside as focused. Only for a gallery or preview render, whose
    /// off-screen window never becomes key, so `.defaultFocus` cannot show the design's focused
    /// field. The app never sets it.
    var dsShowsFocus: Bool {
        get { self[DSShowsFocusKey.self] }
        set { self[DSShowsFocusKey.self] = newValue }
    }
}

private nonisolated struct DSFormLabelWidthKey: EnvironmentKey {
    static let defaultValue: CGFloat = DSLayout.sheetLabelWidth - DSSpacing.md
}

public nonisolated extension EnvironmentValues {
    /// The width of the label column ``DSFormRow`` draws, right-aligned before its 12pt gap.
    var dsFormLabelWidth: CGFloat {
        get { self[DSFormLabelWidthKey.self] }
        set { self[DSFormLabelWidthKey.self] = newValue }
    }
}

public extension View {
    /// Sets the label column of every ``DSFormRow`` in this form, for a sheet whose design draws a
    /// narrower or wider column than the sheets' usual 92pt.
    func dsFormLabelWidth(_ width: CGFloat) -> some View {
        environment(\.dsFormLabelWidth, width)
    }
}

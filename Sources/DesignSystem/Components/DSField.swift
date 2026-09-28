import SwiftUI

/// The chrome every editable field shares: a quiet fill, a hairline, and an accent border with a halo
/// while focused. Invalid fields keep a red border whether or not they are focused.
public struct DSFieldChrome: ViewModifier {
    private let height: CGFloat
    private let cornerRadius: CGFloat
    private let isFocused: Bool
    private let isInvalid: Bool
    private let horizontalPadding: CGFloat

    public init(height: CGFloat = DSControlHeight.regular, cornerRadius: CGFloat = DSCornerRadius.field,
                isFocused: Bool, isInvalid: Bool = false, horizontalPadding: CGFloat = DSSpacing.sm) {
        self.height = height
        self.cornerRadius = cornerRadius
        self.isFocused = isFocused
        self.isInvalid = isInvalid
        self.horizontalPadding = horizontalPadding
    }

    public func body(content: Content) -> some View {
        content
            .padding(.horizontal, horizontalPadding)
            .frame(height: height)
            .background {
                RoundedRectangle(cornerRadius: cornerRadius).fill(DSColors.field)
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(border, lineWidth: isFocused || isInvalid ? DSStroke.emphasis : DSStroke.hairline)
            }
            .overlay {
                if isFocused || isInvalid {
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
        if isFocused { return DSColors.accent }
        return DSColors.fieldBorder
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
public struct DSFormRow<Content: View>: View {
    private let label: String
    private let labelWidth: CGFloat
    private let alignment: VerticalAlignment
    private let content: Content

    public init(_ label: String, labelWidth: CGFloat = DSLayout.sheetLabelWidth - DSSpacing.md,
                alignment: VerticalAlignment = .center, @ViewBuilder content: () -> Content) {
        self.label = label
        self.labelWidth = labelWidth
        self.alignment = alignment
        self.content = content()
    }

    public var body: some View {
        HStack(alignment: alignment, spacing: DSSpacing.md) {
            Text(label)
                .font(DSTypography.callout)
                .foregroundStyle(DSColors.labelSecondary)
                .lineLimit(1)
                .frame(width: labelWidth, alignment: .trailing)
                .padding(.top, alignment == .top ? 5 : 0)
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

/// A one-line hint under a form row, aligned with the controls.
public struct DSFormHint: View {
    private let text: String
    private let indent: CGFloat

    public init(_ text: String, indent: CGFloat = DSLayout.sheetLabelWidth) {
        self.text = text
        self.indent = indent
    }

    public var body: some View {
        Text(text)
            .font(DSTypography.caption)
            .foregroundStyle(DSColors.labelTertiary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, indent)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

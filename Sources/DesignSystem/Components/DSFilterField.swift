import SwiftUI

/// A 26-point filter well. Scope, text, and clear controls share one vertically centered row.
public struct DSFilterField: View {
    public struct Scope: Identifiable, Equatable, Sendable {
        public let id: String
        public var title: String

        public init(id: String, title: String) {
            self.id = id
            self.title = title
        }
    }

    @Binding private var text: String
    @Binding private var scopeID: String
    private let scopes: [Scope]
    private let placeholder: String
    private let identifier: String
    private let focusRequest: Int
    @FocusState private var isFocused: Bool

    public init(text: Binding<String>, scopeID: Binding<String>, scopes: [Scope],
                placeholder: String, identifier: String, focusRequest: Int = 0) {
        self._text = text
        self._scopeID = scopeID
        self.scopes = scopes
        self.placeholder = placeholder
        self.identifier = identifier
        self.focusRequest = focusRequest
    }

    public var body: some View {
        HStack(spacing: DSSpacing.sm) {
            if !scopes.isEmpty {
                ScopeMenu(scopes: scopes, scopeID: $scopeID, identifier: identifier)
            }
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(DSTypography.label)
                .focused($isFocused)
                .accessibilityIdentifier("\(identifier).field")
                .accessibilityLabel(placeholder)

            if !text.isEmpty {
                DSClearButton(text: $text, identifier: "\(identifier).clear",
                              label: "Clear filter", help: "Clear the filter")
            }
        }
        .padding(.horizontal, DSSpacing.smPlus)
        .frame(height: DSControlHeight.search)
        .background {
            Capsule()
                .fill(DSColors.tertiary)
                .stroke(isFocused ? DSColors.borderFocused : DSColors.border,
                        lineWidth: isFocused ? DSStroke.focusRing : DSStroke.hairline)
                .contentShape(Capsule())
                .onTapGesture { isFocused = true }
        }
        .animation(.easeOut(duration: DSAnimation.fast), value: isFocused)
        .onChange(of: focusRequest) { _, _ in isFocused = true }
        // Preserve the individual field, scope, and clear identifiers for keyboard and UI tests.
        .accessibilityElement(children: .contain)
    }

    /// The field supplies the bezel; this menu needs only a readable glyph and a full-height target.
    private struct ScopeMenu: View {
        let scopes: [Scope]
        @Binding var scopeID: String
        let identifier: String
        @State private var isHovered = false

        var body: some View {
            Menu {
                ForEach(scopes) { scope in
                    Button(scope.title) { scopeID = scope.id }
                }
            } label: {
                HStack(spacing: DSSpacing.xs) {
                    Image(systemName: "line.3.horizontal.decrease")
                        .font(.system(size: DSGlyph.control, weight: .medium))
                    if isScoped {
                        Text(title)
                            .font(DSTypography.caption)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Image(systemName: "chevron.down")
                        .font(.system(size: DSGlyph.indicator, weight: .semibold))
                }
                .foregroundStyle(isScoped ? DSColors.accentText
                                 : isHovered ? DSColors.labelPrimary : DSColors.labelSecondary)
                .padding(.horizontal, DSSpacing.xxs)
                .frame(height: DSControlHeight.field)
                .background {
                    RoundedRectangle(cornerRadius: DSCornerRadius.sm)
                        .fill(isHovered || isScoped ? DSColors.accentSubtle : .clear)
                }
                .contentShape(Rectangle())
            }
            .onHover { isHovered = $0 }
            .animation(.easeOut(duration: DSAnimation.micro), value: isHovered)
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Choose what the filter searches")
            .accessibilityIdentifier("\(identifier).scope")
            .accessibilityLabel("Filter scope")
            .accessibilityValue(title)
        }

        private var selection: DSFilterField.Scope? {
            scopes.first { $0.id == scopeID } ?? scopes.first
        }
        private var title: String { selection?.title ?? "" }
        private var isScoped: Bool { selection?.id != scopes.first?.id }
    }
}

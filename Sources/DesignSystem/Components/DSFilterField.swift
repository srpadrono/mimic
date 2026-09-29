import SwiftUI

/// A 24-point filter well. Scope, text, and clear controls share one vertically centered row.
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
    private let reservesScopeSlot: Bool
    private let label: String
    @Environment(\.isEnabled) private var isEnabled
    @FocusState private var isFocused: Bool

    /// `reservesScopeSlot` lays a scopeless field out as if it had an unscoped scope menu, so the
    /// text starts where it does in a sibling field that has one. Fields that stand in for each other
    /// in one place, as the navigator's two filters do, set it; a field on its own does not.
    public init(text: Binding<String>, scopeID: Binding<String>, scopes: [Scope],
                placeholder: String, label: String? = nil, identifier: String, focusRequest: Int = 0,
                reservesScopeSlot: Bool = false) {
        self.reservesScopeSlot = reservesScopeSlot
        self.label = label ?? placeholder
        self._text = text
        self._scopeID = scopeID
        self.scopes = scopes
        self.placeholder = placeholder
        self.identifier = identifier
        self.focusRequest = focusRequest
    }

    public var body: some View {
        HStack(spacing: DSSpacing.xs + 2) {
            if scopes.isEmpty {
                // The unscoped menu's label, with its chevron kept for its width but not drawn.
                HStack(spacing: ScopeMenu.glyphSpacing) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: DSGlyph.field, weight: .regular))
                    if reservesScopeSlot {
                        ScopeMenu.chevron.hidden()
                    }
                }
                .foregroundStyle(DSColors.labelTertiary)
                .frame(height: DSControlHeight.regular)
                .fixedSize()
                .accessibilityHidden(true)
            } else {
                ScopeMenu(scopes: scopes, scopeID: $scopeID, identifier: identifier)
            }
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(DSTypography.callout)
                .focused($isFocused)
                .accessibilityIdentifier("\(identifier).field")
                .accessibilityLabel(label)

            if !text.isEmpty {
                DSClearButton(text: Binding(get: { text }, set: {
                    text = $0
                    isFocused = true
                }), identifier: "\(identifier).clear",
                              label: "Clear filter", help: "Clear the filter")
            }
        }
        .dsFieldChrome(height: DSControlHeight.regular, cornerRadius: DSControlHeight.regular / 2,
                       isFocused: isFocused)
        .contentShape(Capsule())
        .onTapGesture { if isEnabled { isFocused = true } }
        .onChange(of: focusRequest) { _, _ in if isEnabled { isFocused = true } }
        .accessibilityElement(children: .contain)
    }

    private struct ScopeMenu: View {
        let scopes: [Scope]
        @Binding var scopeID: String
        let identifier: String
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovered = false

        static let glyphSpacing: CGFloat = 2
        static var chevron: some View {
            Image(systemName: "chevron.down")
                .font(.system(size: DSGlyph.minimum, weight: .bold))
        }

        var body: some View {
            Menu {
                ScopeOptions(scopes: scopes, scopeID: $scopeID, identifier: identifier)
            } label: {
                HStack(spacing: Self.glyphSpacing) {
                    Image(systemName: isScoped ? "line.3.horizontal.decrease.circle.fill" : "magnifyingglass")
                        .font(.system(size: DSGlyph.field, weight: .regular))
                    if isScoped {
                        Text(title)
                            .font(DSTypography.caption.weight(.semibold))
                            .lineLimit(1)
                    }
                    Self.chevron
                }
                .foregroundStyle(isScoped ? DSColors.accent
                                 : isEnabled && isHovered ? DSColors.labelSecondary : DSColors.labelTertiary)
                .frame(height: DSControlHeight.regular)
                .contentShape(Rectangle())
            }
            .onHover { isHovered = isEnabled && $0 }
            .onChange(of: isEnabled) { _, enabled in
                if !enabled { isHovered = false }
            }
            .animation(.easeOut(duration: DSAnimation.fast), value: isHovered)
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

    /// Native mutually exclusive choices, including the selected checkmark and keyboard behavior.
    /// Shared with the hosted menu regression so it exercises AppKit's actual menu adaptation.
    struct ScopeOptions: View {
        let scopes: [Scope]
        @Binding var scopeID: String
        let identifier: String

        var body: some View {
            Picker("Filter scope", selection: $scopeID) {
                ForEach(scopes) { scope in
                    Text(scope.title)
                        .tag(scope.id)
                        .accessibilityIdentifier("\(identifier).scope.\(scope.id)")
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
    }
}

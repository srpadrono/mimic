import SwiftUI

/// The shared chrome for panel titles and editor identities. An editor may lead with a badge and
/// path or with a name and state, but it must occupy the same bar as the surrounding panels.
public struct DSHeaderChrome: ViewModifier {
    public init() {}

    public func body(content: Content) -> some View {
        content
            .padding(.horizontal, DSSpacing.md)
            .frame(height: DSBarHeight.panelHeader)
            .background(DSColors.secondary)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(DSColors.separator)
                    .frame(height: DSStroke.hairline)
            }
    }
}

public extension View {
    func dsHeaderChrome() -> some View { modifier(DSHeaderChrome()) }
}

public struct DSEditorHeader<Identity: View, Action: View>: View {
    private let identifier: String
    private let identity: Identity
    private let action: Action

    public init(
        identifier: String,
        @ViewBuilder identity: () -> Identity,
        @ViewBuilder action: () -> Action
    ) {
        self.identifier = identifier
        self.identity = identity()
        self.action = action()
    }

    public var body: some View {
        HStack(spacing: DSSpacing.sm) {
            identity
            Spacer(minLength: DSSpacing.sm)
            action
        }
        .dsHeaderChrome()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ds.editorHeader.\(identifier)")
    }
}

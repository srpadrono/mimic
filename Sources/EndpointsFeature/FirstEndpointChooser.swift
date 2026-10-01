import DesignSystem
import SwiftUI

/// A new project's centre: three ways to get a first endpoint.
///
/// The headline sits over the three cards, which share one row and shrink before they wrap; a
/// pane too short for all of it scrolls rather than clipping the headline.
public struct FirstEndpointChooser: View {
    /// The port the server runs on, or will, named in the message.
    let port: Int
    let onAddEndpoint: () -> Void
    let onImportHAR: () -> Void
    let onImportOpenAPI: () -> Void

    /// The pane's width, which decides how many option cards share a row.
    @State private var chooserWidth: CGFloat = 1_000

    public init(
        port: Int,
        onAddEndpoint: @escaping () -> Void,
        onImportHAR: @escaping () -> Void,
        onImportOpenAPI: @escaping () -> Void
    ) {
        self.port = port
        self.onAddEndpoint = onAddEndpoint
        self.onImportHAR = onImportHAR
        self.onImportOpenAPI = onImportOpenAPI
    }

    public var body: some View {
        ViewThatFits(in: .vertical) {
            content
            ScrollView { content }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { chooserWidth = $0 }
    }

    private var content: some View {
        let columns = Self.chooserColumns(forWidth: chooserWidth - 2 * DSSpacing.xxl)
        return VStack(spacing: DSSpacing.xxl + DSSpacing.xs) {
            VStack(spacing: DSSpacing.sm) {
                Text("Mock your first endpoint")
                    .font(DSTypography.title)
                    .foregroundStyle(DSColors.labelPrimary)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("ds.empty.center.noSelection.heading")
                    .accessibilityAddTraits(.isHeader)
                Text("Add one by hand, or bring in traffic you already have. Mimic serves it on localhost:\(String(port)) when you press Run.")
                    .font(DSTypography.body)
                    .foregroundStyle(DSColors.labelSecondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(DSTypography.Leading.callout)
                    .frame(maxWidth: 460)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("ds.empty.center.noSelection.message")
            }
            LazyVGrid(
                columns: Array(
                    repeating: GridItem(
                        .flexible(minimum: Self.cardMinimumWidth, maximum: Self.cardWidth),
                        spacing: DSSpacing.lg,
                        alignment: .top
                    ),
                    count: columns
                ),
                alignment: .center,
                spacing: DSSpacing.lg
            ) {
                chooserCards
            }
            .frame(maxWidth: CGFloat(columns) * Self.cardWidth + CGFloat(columns - 1) * DSSpacing.lg)
        }
        .padding(DSSpacing.xxl)
        .frame(maxWidth: .infinity)
        // On the content, not the `ViewThatFits`: XCUITest finds no element for an identifier set
        // around a `ScrollView`. Only one of the two copies is ever on screen.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ds.empty.center.noSelection")
    }

    /// The design's card width, and the narrowest a card gets before the row wraps.
    private static let cardWidth: CGFloat = 220
    private static let cardMinimumWidth: CGFloat = 168

    /// Three cards to a row while they fit at their narrowest, then two, then one.
    public static func chooserColumns(forWidth width: CGFloat) -> Int {
        let perCard = cardMinimumWidth + DSSpacing.lg
        let fitting = Int((width + DSSpacing.lg) / perCard)
        return min(3, max(1, fitting))
    }

    @ViewBuilder
    private var chooserCards: some View {
        // ⌥⌘N, the shortcut File ▸ New Endpoint… really has; ⌘N is New Project.
        DSOptionCard("Add endpoint", systemImage: "plus",
                     message: "Choose a method and path, then write the response.",
                     shortcut: ["⌥", "⌘", "N"], isDefault: true, identifier: "empty.center.noSelection.cta",
                     action: onAddEndpoint)
        DSOptionCard("Import HAR", systemImage: "doc.text",
                     message: "From Proxyman, Charles or browser DevTools.",
                     footnote: "A .har file", identifier: "center.importHAR", action: onImportHAR)
        DSOptionCard("Import OpenAPI", systemImage: "curlybraces",
                     message: "Each operation becomes an endpoint with its example response.",
                     footnote: "JSON or YAML", identifier: "center.importOpenAPI", action: onImportOpenAPI)
    }
}

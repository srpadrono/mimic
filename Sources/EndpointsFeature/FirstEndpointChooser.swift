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
        // `minWidth: 0` so the measured width is the pane's, not the row's. Without it the frame is
        // never narrower than three cards once three are showing, so a pane that narrows keeps
        // measuring wide enough for three and the last card runs out of the window.
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
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
                    .lineSpacing(DSTypography.Leading.tight)
                    .frame(maxWidth: 460)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("ds.empty.center.noSelection.message")
            }
            // A `Grid`, not a `LazyVGrid`: a grid row is as tall as its tallest card, and each card
            // fills it, so a row of cards shares one height whatever their text.
            Grid(horizontalSpacing: DSSpacing.lg, verticalSpacing: DSSpacing.lg) {
                ForEach(Self.rows(of: Option.allCases, columns: columns), id: \.self) { row in
                    GridRow(alignment: .top) {
                        ForEach(row, id: \.self) { option in
                            card(option)
                        }
                    }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: CGFloat(columns) * DSOptionCard.width + CGFloat(columns - 1) * DSSpacing.lg)
        }
        .padding(DSSpacing.xxl)
        .frame(maxWidth: .infinity)
        // On the content, not the `ViewThatFits`: XCUITest finds no element for an identifier set
        // around a `ScrollView`. Only one of the two copies is ever on screen.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ds.empty.center.noSelection")
    }

    /// Three cards to a row while they fit at their narrowest, then two, then one.
    public static func chooserColumns(forWidth width: CGFloat) -> Int {
        let perCard = DSOptionCard.minimumWidth + DSSpacing.lg
        let fitting = Int((width + DSSpacing.lg) / perCard)
        return min(3, max(1, fitting))
    }

    /// `options` split into rows of `columns`, in order.
    static func rows<Element>(of options: [Element], columns: Int) -> [[Element]] {
        stride(from: 0, to: options.count, by: max(1, columns)).map {
            Array(options[$0..<min($0 + max(1, columns), options.count)])
        }
    }

    enum Option: CaseIterable, Hashable {
        case addEndpoint, importHAR, importOpenAPI
    }

    @ViewBuilder
    private func card(_ option: Option) -> some View {
        switch option {
        case .addEndpoint:
            // ⌥⌘N, the shortcut File ▸ New Endpoint… really has; ⌘N is New Project.
            DSOptionCard("Add endpoint", systemImage: "plus",
                         message: "Choose a method and path, then write the response.",
                         shortcut: ["⌥", "⌘", "N"], isDefault: true, fillsHeight: true,
                         identifier: "empty.center.noSelection.cta", action: onAddEndpoint)
        case .importHAR:
            // The board's "Or drop a .har file here" waits for a drop target; nothing takes one yet.
            DSOptionCard("Import HAR", systemImage: "doc.text",
                         message: "From Proxyman, Charles or browser DevTools.",
                         footnote: "A .har file", fillsHeight: true, identifier: "center.importHAR",
                         action: onImportHAR)
        case .importOpenAPI:
            DSOptionCard("Import OpenAPI", systemImage: "curlybraces",
                         message: "Each operation becomes an endpoint with its example response.",
                         footnote: "JSON or YAML", fillsHeight: true, identifier: "center.importOpenAPI",
                         action: onImportOpenAPI)
        }
    }
}

import AppKit
import SwiftUI

// Debug only: the catalogue is for the gallery, previews and snapshot tests, and never ships.
#if DEBUG

/// Every design-system component in the states the design canvas draws, grouped the way the
/// Components and Tokens artboards group them.
///
/// Each entry names the section of `Design/Reference/sections.json` it corresponds to, so the
/// gallery can lay the artboard over it and the fidelity tests can score it.
public enum DSCatalog {
    public struct Entry: Identifiable {
        public let id: String
        public let title: String
        /// The artboard section this entry is drawn to match.
        public let referenceID: String
        /// The size, in points, of the artboard section.
        public let size: CGSize
        public let content: () -> AnyView

        public init(id: String, title: String, referenceID: String, size: CGSize,
                    @ViewBuilder content: @escaping () -> some View) {
            self.id = id
            self.title = title
            self.referenceID = referenceID
            self.size = size
            self.content = { AnyView(content()) }
        }
    }

    public static let components: [Entry] = [
        Entry(id: "ds.methodLabel", title: "Method label", referenceID: "ds.methodLabel",
              size: CGSize(width: 432, height: 220)) {
            DSCatalogCard("Method label",
                          detail: "Coloured monospaced text, no pill. 44 pt column. Hue and lightness both differ.") {
                HStack(spacing: 6) {
                    ForEach(["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD"], id: \.self) { method in
                        DSMethodLabel(method, fixedWidth: false, identifier: "catalog.\(method.lowercased())")
                    }
                }
                VStack(alignment: .leading, spacing: DSSpacing.xxs) {
                    catalogRoute("GET", "/products/:id")
                    catalogRoute("DELETE", "/session")
                }
            }
        },
        Entry(id: "ds.status", title: "Status", referenceID: "ds.status",
              size: CGSize(width: 432, height: 220)) {
            DSCatalogCard("Status", detail: "One style everywhere: a dot and the code in one colour. No fills.") {
                HStack(spacing: 14) {
                    ForEach([200, 204, 302, 401, 404, 429, 500, 503], id: \.self) { code in
                        DSStatusLabel(statusCode: code)
                    }
                }
                HStack(spacing: 14) {
                    DSStatusLabel(statusCode: 503, reason: "Service Unavailable")
                    Text("Unmatched").foregroundStyle(DSColors.warning)
                    Text("Upstream").foregroundStyle(DSColors.labelSecondary)
                    DSStatusLabel("Dropped", color: DSColors.labelTertiary)
                }
                .font(DSTypography.callout)
            }
        },
        Entry(id: "ds.buttons", title: "Buttons", referenceID: "ds.buttons",
              size: CGSize(width: 432, height: 239)) {
            DSCatalogCard("Buttons") {
                HStack(spacing: DSSpacing.sm) {
                    DSButton("Add endpoint", variant: .primary, size: .large, identifier: "catalog.primary") {}
                    DSButton("Cancel", variant: .secondary, size: .large, identifier: "catalog.secondary") {}
                    DSButton("Delete", variant: .destructive, size: .large, identifier: "catalog.destructive") {}
                }
                HStack(spacing: DSSpacing.sm) {
                    DSButton("Make live", variant: .secondary, size: .small, identifier: "catalog.small") {}
                    DSButton("Format", variant: .ghost, size: .small, identifier: "catalog.ghost") {}
                }
            }
        },
        Entry(id: "ds.fields", title: "Fields", referenceID: "ds.fields",
              size: CGSize(width: 432, height: 368)) {
            DSCatalogFields()
        },
        Entry(id: "ds.segmented", title: "Segmented control and toggles", referenceID: "ds.segmented",
              size: CGSize(width: 432, height: 368)) {
            DSCatalogSegments()
        },
        Entry(id: "ds.banners", title: "Banners", referenceID: "ds.banners",
              size: CGSize(width: 432, height: 235)) {
            DSCatalogCard("Banners", detail: "Inline, above the content they concern, with one action.") {
                DSBanner(.error, message: "Changes couldn\u{2019}t be saved.", actionTitle: "Try again",
                         identifier: "catalog.error") {}
                DSBanner(.warning, message: "Restart to use the new port.", actionTitle: "Restart",
                         systemImage: "arrow.counterclockwise", identifier: "catalog.warning") {}
                DSBanner(.info, message: "This scenario isn\u{2019}t live.", actionTitle: "Make live",
                         identifier: "catalog.info") {}
            }
        },
        Entry(id: "ds.codeEditor", title: "Code editor", referenceID: "ds.codeEditor",
              size: CGSize(width: 432, height: 208)) {
            DSCatalogCard("Code editor") {
                DSCodeBlock("""
                {
                  "id": "p_42",
                  "name": "Canvas Tote",
                  "price": 39.5
                }
                """, identifier: "catalog.code")
            }
        },
        Entry(id: "ds.jumpBarAndEmptyState", title: "Empty state", referenceID: "ds.jumpBarAndEmptyState",
              size: CGSize(width: 888, height: 269)) {
            DSCatalogCard("Jump bar and empty state") {
                DSEmptyState(
                    systemImage: "point.topleft.down.to.point.bottomright.curvepath",
                    heading: "No journeys yet",
                    message: "Script what a flow returns step by step, or capture one from the request log.",
                    actionTitle: "Add journey",
                    prominence: .compact,
                    identifier: "catalog.empty"
                ) {}
            }
        },
        Entry(id: "ds.pills", title: "Pills", referenceID: "ds.pills",
              size: CGSize(width: 432, height: 269)) {
            DSCatalogCard("Pills", detail: "A short fact beside a row. 18 pt capsule, 11 pt text, 7 pt in from each end.") {
                catalogSpecimen("Neutral") {
                    DSPill("\u{00D7} 3")
                    DSPill("Drop after 5 s", systemImage: "bolt.horizontal")
                }
                catalogSpecimen("Warning") {
                    DSPill("Same route as row 4", tone: .warning, weight: .medium)
                }
                catalogSpecimen("State") {
                    catalogStatePill("Active", tint: DSColors.success)
                    catalogStatePill("Selected", tint: DSColors.labelSecondary)
                }
                catalogSpecimen("Journey glyph") {
                    DSJourneyGlyph(size: DSGlyph.control)
                    DSJourneyGlyph(size: DSGlyph.card)
                }
                .foregroundStyle(DSColors.labelSecondary)
            }
        },
    ]

    public static let tokens: [Entry] = [
        Entry(id: "tokens.colour", title: "Colour", referenceID: "tokens.colour",
              size: CGSize(width: 1344, height: 297)) {
            DSCatalogCard("Colour", detail: "Each swatch shows light on the left and dark on the right. The accent "
                          + "and focus ring come from the system setting; blue is only the default.") {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(DSCatalogSwatch.roles) { $0 }
                }
                HStack(alignment: .top, spacing: 14) {
                    ForEach(DSCatalogSwatch.inks) { $0 }
                }
            }
        },
        Entry(id: "tokens.type", title: "Type", referenceID: "tokens.type",
              size: CGSize(width: 660, height: 267)) {
            DSCatalogCard("Type") {
                Text("Title \u{00B7} 20 semibold").font(DSTypography.title)
                Text("Headline \u{00B7} 15 semibold").font(DSTypography.headline)
                Text("Body \u{00B7} 13 regular").font(DSTypography.body)
                Text("Callout \u{00B7} 12 regular").font(DSTypography.callout)
                Text("Caption \u{00B7} 11 regular").font(DSTypography.caption)
                Text("Code \u{00B7} SF Mono 12").font(DSTypography.code)
            }
        },
        Entry(id: "tokens.spacing", title: "Spacing, radius and size", referenceID: "tokens.spacing",
              size: CGSize(width: 660, height: 267)) {
            DSCatalogCard("Spacing, radius and size") {
                HStack(alignment: .bottom, spacing: DSSpacing.lg) {
                    ForEach([DSSpacing.xs, DSSpacing.sm, DSSpacing.md, DSSpacing.lg, DSSpacing.xl, DSSpacing.xxl,
                             DSSpacing.xxxl], id: \.self) { value in
                        VStack(spacing: DSSpacing.xs) {
                            Rectangle().fill(DSColors.accent).frame(width: value, height: value)
                            Text("\(Int(value))").font(DSTypography.caption).foregroundStyle(DSColors.labelSecondary)
                        }
                    }
                }
                HStack(spacing: DSSpacing.lg) {
                    ForEach(radii, id: \.name) { radius in
                        VStack(spacing: DSSpacing.xs) {
                            RoundedRectangle(cornerRadius: radius.value, style: .continuous)
                                .strokeBorder(DSColors.fieldBorder, lineWidth: DSStroke.hairline * 2)
                                .frame(width: 48, height: 32)
                            Text("\(Int(radius.value)) \(radius.name)")
                                .font(DSTypography.caption).foregroundStyle(DSColors.labelSecondary)
                        }
                    }
                }
            }
        },
    ]

    public static var all: [Entry] { components + tokens }

    /// Every corner radius, named for the shape it rounds, as the Tokens board lists them.
    private static let radii: [NamedRadius] = [
        NamedRadius(name: "mark", value: DSCornerRadius.mark),
        NamedRadius(name: "field", value: DSCornerRadius.field),
        NamedRadius(name: "segment", value: DSCornerRadius.segment),
        NamedRadius(name: "card", value: DSCornerRadius.card),
        NamedRadius(name: "panel", value: DSCornerRadius.panel),
        NamedRadius(name: "sheet", value: DSCornerRadius.sheet),
    ]

    private struct NamedRadius {
        let name: String
        let value: CGFloat
    }

    /// A specimen row: its caption in the board's 84 pt column, then the specimens.
    private static func catalogSpecimen(_ caption: String, @ViewBuilder content: () -> some View) -> some View {
        HStack(spacing: 10) {
            Text(caption)
                .font(DSTypography.caption)
                .foregroundStyle(DSColors.labelTertiary)
                .frame(width: 84, alignment: .leading)
            content()
        }
    }

    /// A state drawn as a pill: the dot and word in the state's colour, outlined.
    private static func catalogStatePill(_ title: String, tint: Color) -> some View {
        HStack(spacing: 6) {
            DSStatusDot(tint)
            Text(title).font(DSTypography.caption.weight(.medium))
        }
        .dsPill(.outline(tint))
    }

    private static func catalogRoute(_ method: String, _ path: String) -> some View {
        HStack(spacing: DSSpacing.sm) {
            DSMethodLabel(method, identifier: "catalog.route.\(method.lowercased())")
            Text(path).font(DSTypography.code).foregroundStyle(DSColors.labelPrimary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DSSpacing.sm)
        .frame(height: DSRowHeight.list)
    }
}

/// One artboard section: a card with a title, an optional line of description, and its specimens.
public struct DSCatalogCard<Content: View>: View {
    let title: String
    let detail: String?
    let content: Content

    public init(_ title: String, detail: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.detail = detail
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: DSSpacing.xs) {
                Text(title)
                    .font(DSTypography.bodySemibold)
                    .foregroundStyle(DSColors.labelPrimary)
                if let detail {
                    Text(detail)
                        .font(DSTypography.caption)
                        .foregroundStyle(DSColors.labelTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            content
            Spacer(minLength: 0)
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(DSColors.content, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(DSColors.separator, lineWidth: DSStroke.hairline)
        }
    }
}

struct DSCatalogFields: View {
    @State private var empty = ""
    @State private var filled = "Acme Storefront"
    @State private var invalid = "80"
    @State private var filter = ""
    @State private var scope = "any"
    @State private var format = "json"

    var body: some View {
        DSCatalogCard("Fields") {
            DSTextField("Default", text: $empty, placeholder: "Name", identifier: "catalog.default")
            DSTextField("Filled", text: $filled, identifier: "catalog.filled")
            DSTextField("Invalid", text: $invalid, validation: "Port must be between 1024 and 65535",
                        identifier: "catalog.invalid")
            DSFilterField(text: $filter, scopeID: $scope, scopes: [], placeholder: "Filter",
                          identifier: "catalog.filter")
            DSMenuField("Pop-up", selection: $format,
                        options: [DSMenuOption("JSON", value: "json"), DSMenuOption("Text", value: "text")],
                        identifier: "catalog.popup")
                .frame(width: 160)
        }
    }
}

struct DSCatalogSegments: View {
    @State private var navigator = "endpoints"
    @State private var log = "all"

    var body: some View {
        DSCatalogCard("Segmented control and toggles") {
            DSSegmentedControl(
                "Navigator",
                segments: [
                    DSSegmentedControl<String>.Segment("Endpoints", value: "endpoints", identifier: "catalog.endpoints"),
                    DSSegmentedControl<String>.Segment("Journeys", value: "journeys", identifier: "catalog.journeys"),
                ],
                selection: $navigator,
                identifier: "catalog.navigator"
            )
            DSSegmentedControl(
                "Show",
                segments: [
                    DSSegmentedControl<String>.Segment("All", value: "all", identifier: "catalog.all"),
                    DSSegmentedControl<String>.Segment("Unmatched", value: "unmatched", count: 3,
                                                       countColor: DSColors.warning, identifier: "catalog.unmatched"),
                    DSSegmentedControl<String>.Segment("Errors", value: "errors", count: 5,
                                                       countColor: DSColors.error, identifier: "catalog.errors"),
                ],
                selection: $log,
                identifier: "catalog.log"
            )
        }
    }
}

/// One colour role as a light and dark pair, with what it resolves to underneath.
struct DSCatalogSwatch: View, Identifiable {
    enum Fill {
        /// An adaptive role, drawn as it resolves in each appearance.
        case role(Color)
        /// A role that only means something under Increase Contrast.
        case highContrast(Color)
        /// The system material behind glass panels, which has no fixed value.
        case material
    }

    let id: String
    let fill: Fill
    /// What to print under the name instead of the resolved hex pair, for roles that are not one colour.
    let caption: String?
    var monospacedName = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 0) {
                half(dark: false)
                half(dark: true)
            }
            .frame(width: 96, height: 40)
            .clipShape(RoundedRectangle(cornerRadius: DSCornerRadius.field, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: DSCornerRadius.field, style: .continuous)
                    .strokeBorder(DSColors.separator, lineWidth: DSStroke.hairline)
            }
            Text(id)
                .font(monospacedName ? DSTypography.method : DSTypography.captionSemibold)
                .foregroundStyle(DSColors.labelPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Text(caption ?? hexPair)
                .font(DSTypography.caption.monospaced())
                .foregroundStyle(DSColors.labelTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: 96, alignment: .leading)
    }

    @ViewBuilder
    private func half(dark: Bool) -> some View {
        switch fill {
        case .role(let color), .highContrast(let color):
            Rectangle().fill(Color(nsColor: resolved(color, dark: dark)))
        case .material:
            Rectangle().fill(.regularMaterial).environment(\.colorScheme, dark ? .dark : .light)
        }
    }

    private func resolved(_ color: Color, dark: Bool) -> NSColor {
        let highContrast: Bool
        if case .highContrast = fill { highContrast = true } else { highContrast = false }
        let name: NSAppearance.Name = switch (dark, highContrast) {
        case (false, false): .aqua
        case (true, false): .darkAqua
        case (false, true): .accessibilityHighContrastAqua
        case (true, true): .accessibilityHighContrastDarkAqua
        }
        let dynamic = NSColor(color)
        var value = dynamic
        NSAppearance(named: name)?.performAsCurrentDrawingAppearance {
            value = dynamic.usingColorSpace(.sRGB) ?? dynamic
        }
        return value
    }

    /// `#F6F6F7 · #1E1E20`, read from the role itself so the board cannot drift from the tokens.
    private var hexPair: String {
        guard case .role(let color) = fill else { return "" }
        return "\(Self.hex(resolved(color, dark: false))) \u{00B7} \(Self.hex(resolved(color, dark: true)))"
    }

    private static func hex(_ color: NSColor) -> String {
        let srgb = color.usingColorSpace(.sRGB) ?? color
        let channels = [srgb.redComponent, srgb.greenComponent, srgb.blueComponent]
            .map { Int(($0 * 255).rounded()) }
        return String(format: "#%02X%02X%02X", channels[0], channels[1], channels[2])
    }

    /// Surfaces, text and status: the first row of the design's colour board.
    static let roles: [DSCatalogSwatch] = [
        .init(id: "Window", fill: .role(DSColors.window), caption: nil),
        .init(id: "Content", fill: .role(DSColors.content), caption: nil),
        .init(id: "Glass panel", fill: .material, caption: "system material"),
        .init(id: "Code", fill: .role(DSColors.code), caption: nil),
        .init(id: "Label", fill: .role(DSColors.labelPrimary), caption: "labelColor"),
        .init(id: "Secondary", fill: .role(DSColors.labelSecondary), caption: "secondaryLabel"),
        .init(id: "Accent", fill: .role(DSColors.accent), caption: "controlAccent"),
        .init(id: "Success \u{00B7} 2xx", fill: .role(DSColors.success), caption: nil),
        .init(id: "Warning \u{00B7} 4xx", fill: .role(DSColors.warning), caption: nil),
        .init(id: "Error \u{00B7} 5xx", fill: .role(DSColors.error), caption: nil),
    ]

    /// Methods, JSON syntax and separators: the second row.
    static let inks: [DSCatalogSwatch] = [
        .init(id: "GET", fill: .role(DSColors.methodColor(for: "GET")), caption: nil, monospacedName: true),
        .init(id: "POST", fill: .role(DSColors.methodColor(for: "POST")), caption: nil, monospacedName: true),
        .init(id: "PUT", fill: .role(DSColors.methodColor(for: "PUT")), caption: nil, monospacedName: true),
        .init(id: "PATCH", fill: .role(DSColors.methodColor(for: "PATCH")), caption: nil, monospacedName: true),
        .init(id: "DELETE", fill: .role(DSColors.methodColor(for: "DELETE")), caption: nil, monospacedName: true),
        .init(id: "JSON key", fill: .role(DSColors.Syntax.key), caption: nil),
        .init(id: "JSON string", fill: .role(DSColors.Syntax.string), caption: nil),
        .init(id: "JSON number", fill: .role(DSColors.Syntax.number), caption: nil),
        .init(id: "Separator", fill: .role(DSColors.separator), caption: "1 px, not 0.5 pt"),
        .init(id: "Separator, high contrast", fill: .highContrast(DSColors.separator), caption: "Increase Contrast"),
    ]
}

#Preview("Components") {
    ScrollView {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 432), spacing: 24)], spacing: 24) {
            ForEach(DSCatalog.components) { entry in
                entry.content().frame(width: entry.size.width, height: entry.size.height)
            }
        }
        .padding(48)
    }
    .frame(width: 1440, height: 900)
    .background(DSColors.window)
}

#Preview("Tokens") {
    VStack(spacing: 24) {
        ForEach(DSCatalog.tokens) { entry in
            entry.content().frame(width: entry.size.width, height: entry.size.height)
        }
    }
    .padding(48)
    .background(DSColors.window)
}
#endif

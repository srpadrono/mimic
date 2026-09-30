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
              size: CGSize(width: 432, height: 229)) {
            DSCatalogCard("Banners") {
                DSBanner(.error, message: "Changes couldn\u{2019}t be saved.", identifier: "catalog.error")
                DSBanner(.info, message: "Restart to use the new port.", identifier: "catalog.info")
                DSBanner(.warning, message: "This scenario isn\u{2019}t live.", actionTitle: "Make live",
                         identifier: "catalog.warning") {}
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
    ]

    public static let tokens: [Entry] = [
        Entry(id: "tokens.colour", title: "Colour", referenceID: "tokens.colour",
              size: CGSize(width: 1344, height: 297)) {
            DSCatalogCard("Colour") {
                HStack(spacing: DSSpacing.md) {
                    ForEach(DSCatalogSwatch.surfaces) { $0 }
                }
                HStack(spacing: DSSpacing.md) {
                    ForEach(DSCatalogSwatch.semantic) { $0 }
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
                    ForEach([DSSpacing.xs, DSSpacing.sm, DSSpacing.md, DSSpacing.lg, DSSpacing.xl, DSSpacing.xxl],
                            id: \.self) { value in
                        VStack(spacing: DSSpacing.xs) {
                            Rectangle().fill(DSColors.accent).frame(width: value, height: value)
                            Text("\(Int(value))").font(DSTypography.caption).foregroundStyle(DSColors.labelSecondary)
                        }
                    }
                }
                HStack(spacing: DSSpacing.lg) {
                    ForEach([DSCornerRadius.field, DSCornerRadius.card, DSCornerRadius.panel, DSCornerRadius.sheet],
                            id: \.self) { radius in
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .strokeBorder(DSColors.fieldBorder, lineWidth: DSStroke.hairline * 2)
                            .frame(width: 48, height: 32)
                    }
                }
            }
        },
    ]

    public static var all: [Entry] { components + tokens }

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

    var body: some View {
        DSCatalogCard("Fields") {
            DSTextField("Default", text: $empty, placeholder: "Name", identifier: "catalog.default")
            DSTextField("Filled", text: $filled, identifier: "catalog.filled")
            DSTextField("Invalid", text: $invalid, validation: "Port must be between 1024 and 65535",
                        identifier: "catalog.invalid")
            DSFilterField(text: $filter, scopeID: $scope, scopes: [], placeholder: "Filter",
                          identifier: "catalog.filter")
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

struct DSCatalogSwatch: View, Identifiable {
    let id: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpacing.xs) {
            RoundedRectangle(cornerRadius: DSCornerRadius.field, style: .continuous)
                .fill(color)
                .frame(width: 72, height: 44)
                .overlay {
                    RoundedRectangle(cornerRadius: DSCornerRadius.field, style: .continuous)
                        .strokeBorder(DSColors.separator, lineWidth: DSStroke.hairline)
                }
            Text(id).font(DSTypography.caption).foregroundStyle(DSColors.labelSecondary)
        }
    }

    static let surfaces: [DSCatalogSwatch] = [
        .init(id: "Window", color: DSColors.window),
        .init(id: "Content", color: DSColors.content),
        .init(id: "Raised", color: DSColors.raised),
        .init(id: "Field", color: DSColors.field),
        .init(id: "Code", color: DSColors.code),
        .init(id: "Separator", color: DSColors.separator),
        .init(id: "Accent", color: DSColors.accent),
        .init(id: "Selection", color: DSColors.selectionSoft),
    ]

    static let semantic: [DSCatalogSwatch] = [
        .init(id: "GET", color: DSColors.methodColor(for: "GET")),
        .init(id: "POST", color: DSColors.methodColor(for: "POST")),
        .init(id: "PUT", color: DSColors.methodColor(for: "PUT")),
        .init(id: "PATCH", color: DSColors.methodColor(for: "PATCH")),
        .init(id: "DELETE", color: DSColors.methodColor(for: "DELETE")),
        .init(id: "Success", color: DSColors.success),
        .init(id: "Redirect", color: DSColors.redirect),
        .init(id: "Warning", color: DSColors.warning),
        .init(id: "Error", color: DSColors.error),
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

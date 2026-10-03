import AppKit
import SwiftUI

// Debug only: the catalogue is for the gallery, previews and snapshot tests, and never ships.
#if DEBUG

/// Every design-system component in the states the design canvas draws, grouped the way the
/// Components and Tokens artboards group them.
///
/// Each entry names the section of `Design/Reference/sections.json` it corresponds to, so the
/// gallery can lay the artboard over it and the fidelity tests can score it. The jump bar and empty
/// state card is the one Components section drawn by the gallery instead: the jump bar lives in
/// WorkspaceShell, which the design system cannot import.
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
              size: CGSize(width: 432, height: 219)) {
            // The board leaves its last word alone on the second line; SwiftUI would carry "both"
            // down with it.
            DSCatalogCard("Method label",
                          detail: "Coloured monospaced text, no pill. 44 pt column. Hue and lightness both\ndiffer.") {
                HStack(spacing: 6) {
                    ForEach(["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD"], id: \.self) { method in
                        DSMethodLabel(method, identifier: "catalog.\(method.lowercased())")
                    }
                }
                VStack(alignment: .leading, spacing: DSSpacing.xxs) {
                    catalogRoute("GET", "/products/:id")
                    catalogRoute("DELETE", "/session")
                }
            }
        },
        Entry(id: "ds.status", title: "Status", referenceID: "ds.status",
              size: CGSize(width: 432, height: 219)) {
            DSCatalogCard("Status", detail: "One style everywhere: a dot and the code in one colour. No fills.") {
                HStack(spacing: 14) {
                    ForEach([200, 204, 302, 401, 404, 429, 500, 503], id: \.self) { code in
                        DSStatusLabel(statusCode: code)
                    }
                }
                .frame(minHeight: catalogLine)
                // A code with its reason phrase is set in SF Pro here, as this card draws it.
                HStack(spacing: 14) {
                    DSStatusLabel("503 Service Unavailable", color: DSColors.httpStatusColor(for: 503))
                    Text("Unmatched").foregroundStyle(DSColors.warning)
                    Text("Upstream").foregroundStyle(DSColors.labelSecondary)
                    DSStatusLabel("Dropped", color: DSColors.labelTertiary)
                }
                .font(DSTypography.callout)
                .frame(minHeight: catalogLine)
            }
        },
        Entry(id: "ds.buttons", title: "Buttons", referenceID: "ds.buttons",
              size: CGSize(width: 432, height: 238)) {
            DSCatalogCard("Buttons",
                          detail: "Capsules. One primary per view. 28 pt in sheets, 24 pt in panels, 20 pt\ninline.") {
                // The board's first row wraps Import onto a line of its own, 8 pt below.
                VStack(alignment: .leading, spacing: DSSpacing.sm) {
                    HStack(spacing: DSSpacing.sm) {
                        DSButton("Add endpoint", variant: .primary, size: .large, identifier: "catalog.primary") {}
                        DSButton("Cancel", variant: .secondary, size: .large, identifier: "catalog.secondary") {}
                        DSButton("Delete endpoint", variant: .destructive, size: .large,
                                 identifier: "catalog.destructive") {}
                    }
                    DSButton("Import", variant: .primary, size: .large, identifier: "catalog.disabled") {}
                        .disabled(true)
                }
                HStack(spacing: DSSpacing.sm) {
                    DSButton("Make live", variant: .secondary, size: .medium, identifier: "catalog.medium") {}
                    DSButton("Create endpoint", variant: .primary, size: .medium,
                             identifier: "catalog.mediumPrimary") {}
                    DSButton("Format", systemImage: "text.alignleft", variant: .ghost, size: .medium,
                             identifier: "catalog.ghost") {}
                    DSButton("Copy", variant: .secondary, size: .small, identifier: "catalog.small") {}
                }
            }
        },
        Entry(id: "ds.fields", title: "Fields", referenceID: "ds.fields",
              size: CGSize(width: 432, height: 367)) {
            DSCatalogFields()
        },
        Entry(id: "ds.segmented", title: "Segmented control and toggles", referenceID: "ds.segmented",
              size: CGSize(width: 432, height: 367)) {
            DSCatalogSegments()
        },
        Entry(id: "ds.banners", title: "Banners", referenceID: "ds.banners",
              size: CGSize(width: 432, height: 234)) {
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
              size: CGSize(width: 432, height: 206.5)) {
            DSCatalogCodeEditor()
        },
        Entry(id: "ds.pills", title: "Pills", referenceID: "ds.pills",
              size: CGSize(width: 432, height: 266)) {
            DSCatalogCard("Pills", detail: "A short fact beside a row. 18 pt capsule, 11 pt text, 7 pt in from each end.") {
                catalogSpecimen("Neutral") {
                    DSPill("\u{00D7} 3")
                    DSPill("Drop after 5 s", glyph: .connectionDrop)
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

        // MARK: Table (shared by the request log and the import review)

        Entry(id: "ds.table", title: "Table", referenceID: "ds.table",
              size: CGSize(width: 888, height: 206.5)) {
            DSCatalogCard("Table", detail: "Plain headers that sort, zebra rows, accent selection. "
                          + "Used by the request log and import review.") {
                VStack(spacing: 0) {
                    DSTableHeader {
                        DSTableColumnTitle("Time").dsTableCell(width: DSCatalogTableRow.time)
                        DSTableColumnTitle("Method").dsTableCell(width: DSCatalogTableRow.method)
                        DSTableColumnTitle("Path").dsTableCell(width: nil)
                        DSTableColumnTitle("Status").dsTableCell(width: DSCatalogTableRow.status)
                        DSTableColumnTitle("Scenario").dsTableCell(width: DSCatalogTableRow.scenario)
                        DSTableColumnTitle("Duration").dsTableCell(width: DSCatalogTableRow.duration, alignment: .trailing)
                        DSTableColumnTitle("Size").dsTableCell(width: DSCatalogTableRow.size, alignment: .trailing)
                    }
                    ForEach(Array(DSCatalogTableRow.rows.enumerated()), id: \.offset) { index, row in
                        row.dsTableRow(index: index, isSelected: index == 2)
                    }
                }
            }
        },
    ]

    public static let tokens: [Entry] = [
        Entry(id: "tokens.colour", title: "Colour", referenceID: "tokens.colour",
              size: CGSize(width: 1344, height: 297)) {
            DSCatalogCard("Colour", detail: "Each swatch shows light on the left and dark on the right. The accent "
                          + "and focus ring come from the system setting; blue is only the default.") {
                // Centred, as the board's rows are: a swatch whose name wraps stands taller than the rest.
                HStack(alignment: .center, spacing: 14) {
                    ForEach(DSCatalogSwatch.roles) { $0 }
                }
                HStack(alignment: .center, spacing: 14) {
                    ForEach(DSCatalogSwatch.inks) { $0 }
                }
            }
        },
        Entry(id: "tokens.type", title: "Type", referenceID: "tokens.type",
              size: CGSize(width: 660, height: 267)) {
            DSCatalogCard("Type", detail: "Apple\u{2019}s macOS text styles. Six roles, from 12 sizes today.") {
                VStack(alignment: .leading, spacing: 12) {
                    typeRow("Title \u{00B7} 20 semibold", "Payment retry", font: DSTypography.title, line: 24)
                    typeRow("Headline \u{00B7} 15 semibold", "Out of stock", font: DSTypography.headline, line: 20)
                    typeRow("Body \u{00B7} 13", "Forward unmatched requests", font: DSTypography.body)
                    typeRow("Callout \u{00B7} 12", "Filter by path, status or scenario", font: DSTypography.callout,
                            color: DSColors.labelSecondary)
                    typeRow("Caption \u{00B7} 11", "Last 15 minutes", font: DSTypography.caption,
                            color: DSColors.labelSecondary)
                    typeRow("Code \u{00B7} SF Mono 12", "/products/:id", font: DSTypography.code)
                }
            }
        },
        Entry(id: "tokens.spacing", title: "Spacing, radius and size", referenceID: "tokens.spacing",
              size: CGSize(width: 660, height: 267)) {
            DSCatalogCard("Spacing, radius and size",
                          detail: "A 4 pt grid. Six radii, one for each kind of shape. One row height for every list.") {
                HStack(alignment: .bottom, spacing: 10) {
                    ForEach([DSSpacing.xs, DSSpacing.sm, DSSpacing.md, DSSpacing.lg, DSSpacing.xl, DSSpacing.xxl,
                             DSSpacing.xxxl], id: \.self) { value in
                        VStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 1, style: .circular)
                                .fill(DSColors.accent)
                                .frame(width: value, height: value)
                            Text("\(Int(value))")
                                .font(annotation)
                                .foregroundStyle(DSColors.labelTertiary)
                        }
                    }
                    // The board's 12 pt gap between the grid and the radii, with the row's gap either side.
                    Color.clear.frame(width: 12, height: 0)
                    ForEach(radii, id: \.name) { radius in
                        VStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: radius.value, style: .circular)
                                .strokeBorder(DSColors.labelSecondary, lineWidth: 1.5)
                                .frame(width: 40, height: 32)
                            Text("\(Int(radius.value)) \(radius.name)")
                                .font(annotation)
                                .foregroundStyle(DSColors.labelTertiary)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    sizeRow("List row", "\(Int(DSRowHeight.list)) in lists, \(Int(DSRowHeight.table)) in tables")
                    sizeRow("Controls", "\(Int(DSControlHeight.large)) sheet \u{00B7} "
                            + "\(Int(DSControlHeight.regular)) panel \u{00B7} "
                            + "\(Int(DSControlHeight.inline)) settings row \u{00B7} "
                            + "\(Int(DSControlHeight.small)) inline")
                    sizeRow("Column tops", "Sidebar, content and inspector all start "
                            + "\(Int(DSBarHeight.column)) pt from the top")
                    sizeRow("Panels", "Sidebar \(Int(DSLayout.sidebarWidth)) \u{00B7} "
                            + "Inspector \(Int(DSLayout.inspectorWidth)) \u{00B7} "
                            + "\(Int(DSLayout.panelInset)) pt inset")
                }
            }
        },
    ]

    public static var all: [Entry] { components + tokens }

    /// The boards' 16 pt line: one line of 11 to 13 pt text, or a row of status labels.
    static let catalogLine: CGFloat = 16

    /// The Tokens board's annotation face, SF Mono 10.5, under swatches and specimens. It labels the
    /// board itself, not anything the app draws, so it is not a type role.
    static let annotation: Font = .system(size: 10.5, weight: .regular, design: .monospaced)

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

    /// A specimen row: its caption in the board's 84 pt column, then the specimens, 10 pt apart.
    ///
    /// `.top` is for a 24 pt field with a line under it, such as a validation message: the caption
    /// then centres on the field rather than on the whole specimen.
    static func catalogSpecimen(_ caption: String, alignment: VerticalAlignment = .center,
                                @ViewBuilder content: () -> some View) -> some View {
        HStack(alignment: alignment, spacing: 10) {
            Text(caption)
                .font(DSTypography.caption)
                .foregroundStyle(DSColors.labelTertiary)
                .frame(width: 84, height: alignment == .top ? DSControlHeight.regular : nil, alignment: .leading)
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

    /// A list row as the board sketches it: the method in a 44 pt column, then the path.
    private static func catalogRoute(_ method: String, _ path: String) -> some View {
        HStack(spacing: DSSpacing.sm) {
            DSMethodLabel(method, fixedWidth: false, identifier: "catalog.route.\(method.lowercased())")
                .frame(width: DSLayout.rowMethodColumn, alignment: .leading)
            Text(path).font(DSTypography.code).foregroundStyle(DSColors.labelPrimary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DSSpacing.sm)
        .frame(height: DSRowHeight.list)
    }

    /// A type role: its name in the board's 110 pt label column, then a specimen on the role's line.
    private static func typeRow(_ label: String, _ specimen: String, font: Font, line: CGFloat = DSCatalog.catalogLine,
                                color: Color = DSColors.labelPrimary) -> some View {
        HStack(spacing: 16) {
            Text(label)
                .font(DSTypography.caption)
                .foregroundStyle(DSColors.labelTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .dsCatalogLineBox(catalogLine, fontSize: 11)
                .frame(width: 110, alignment: .leading)
            Text(specimen)
                .font(font)
                .foregroundStyle(color)
                .lineLimit(1)
                .frame(height: line)
        }
    }

    /// A size rule: its name in the 110 pt label column, then the values, read from the tokens.
    private static func sizeRow(_ label: String, _ value: String) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(DSTypography.caption)
                .foregroundStyle(DSColors.labelTertiary)
                .frame(width: 110, height: catalogLine, alignment: .leading)
            Text(value)
                .font(DSTypography.callout)
                .foregroundStyle(DSColors.labelPrimary)
                .lineLimit(1)
                .frame(height: catalogLine)
        }
    }
}

/// One artboard section: a card with a title, an optional line of description, and its specimens.
///
/// The header is set on the boards' CSS line boxes: the 13 pt title on a 16 pt line, the 11 pt
/// description on 15 pt lines 4 pt below it, and the specimens 14 pt below that.
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
                    .frame(height: DSCatalog.catalogLine)
                if let detail {
                    Text(detail)
                        .font(DSTypography.caption)
                        .foregroundStyle(DSColors.labelTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .dsCatalogLineBox(15, fontSize: 11)
                }
            }
            content
            Spacer(minLength: 0)
        }
        // The board pads 18 pt inside its hairline border.
        .padding(18 + DSStroke.hairline)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(DSColors.content, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(DSColors.separator, lineWidth: DSStroke.hairline)
        }
    }
}

/// Text set on a CSS line box: lines `height` points apart, with half the extra space above the
/// first line and half below the last, as a browser sets them. SwiftUI otherwise sets text on the
/// font's own line height, which is shorter than every line box the boards use.
private struct DSCatalogLineBox: ViewModifier {
    let height: CGFloat
    let fontSize: CGFloat
    let monospaced: Bool

    func body(content: Content) -> some View {
        content
            .lineSpacing(extra)
            .padding(.vertical, extra / 2)
    }

    private var extra: CGFloat {
        let font = monospaced
            ? NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
            : NSFont.systemFont(ofSize: fontSize)
        return max(0, height - (font.ascender - font.descender + font.leading))
    }
}

extension View {
    /// Sets this text on the board's `height`-point line box. `fontSize` is the text's point size.
    func dsCatalogLineBox(_ height: CGFloat, fontSize: CGFloat, monospaced: Bool = false) -> some View {
        modifier(DSCatalogLineBox(height: height, fontSize: fontSize, monospaced: monospaced))
    }
}

struct DSCatalogFields: View {
    @State private var value = "Catalog"
    @State private var invalid = "70000"
    @State private var unit = "800"
    @State private var filter = ""
    @State private var scope = "any"
    @State private var format = "json"

    var body: some View {
        DSCatalogCard("Fields", detail: "Native bezels and the system focus ring. Units sit inside the field.") {
            DSCatalog.catalogSpecimen("Default") {
                DSTextField("Default", text: $value, labelPlacement: .hidden, height: DSControlHeight.regular,
                            identifier: "catalog.default")
            }
            DSCatalog.catalogSpecimen("Focused") {
                // A rendered specimen cannot hold focus, so it draws the field's own chrome focused.
                Text("Out of stock")
                    .font(DSTypography.body)
                    .foregroundStyle(DSColors.labelPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .dsFieldChrome(height: DSControlHeight.regular, isFocused: true)
            }
            DSCatalog.catalogSpecimen("Invalid", alignment: .top) {
                // The field, 5 pt, then the message on the board's 16 pt line.
                DSTextField("Invalid", text: $invalid, validation: "Use a port from 1 to 65535", monospaced: true,
                            labelPlacement: .hidden, height: DSControlHeight.regular, identifier: "catalog.invalid")
                    .frame(height: DSControlHeight.regular + 5 + DSCatalog.catalogLine, alignment: .top)
            }
            DSCatalog.catalogSpecimen("With unit") {
                DSTextField("With unit", text: $unit, controlWidth: 92, unit: "ms", monospaced: true,
                            labelPlacement: .hidden, height: DSControlHeight.regular, identifier: "catalog.unit")
            }
            DSCatalog.catalogSpecimen("Pop-up") {
                DSMenuField("Pop-up", selection: $format,
                            options: [DSMenuOption("JSON", value: "json"), DSMenuOption("Text", value: "text")],
                            identifier: "catalog.popup")
                    .frame(width: 160)
            }
            DSCatalog.catalogSpecimen("Search") {
                DSFilterField(text: $filter, scopeID: $scope, scopes: [], placeholder: "Filter",
                              identifier: "catalog.filter")
            }
            DSCatalog.catalogSpecimen("Request") {
                // The board's sketch of the request bar: method, a rule, the path, in a 32 pt field.
                HStack(spacing: 10) {
                    DSMethodLabel("GET", fixedWidth: false, identifier: "catalog.request")
                    Rectangle()
                        .fill(DSColors.separator)
                        .frame(width: DSStroke.hairline, height: DSControlHeight.prominent - 14)
                        .accessibilityHidden(true)
                    Text("/products").font(DSTypography.code).foregroundStyle(DSColors.labelPrimary)
                    Spacer(minLength: 0)
                }
                .dsFieldChrome(height: DSControlHeight.prominent, cornerRadius: DSCornerRadius.card,
                               isFocused: false)
            }
        }
    }
}

struct DSCatalogSegments: View {
    @State private var navigator = "endpoints"
    @State private var log = "all"
    @State private var pane = "body"

    var body: some View {
        DSCatalogCard("Segmented control and toggles",
                      detail: "Neutral selected segment, so it never competes with list selection.") {
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
            DSSegmentedControl(
                "Pane",
                segments: [
                    DSSegmentedControl<String>.Segment("Body", value: "body", identifier: "catalog.body"),
                    DSSegmentedControl<String>.Segment("Headers", value: "headers", count: 2,
                                                       countColor: DSColors.labelTertiary, identifier: "catalog.headers"),
                ],
                selection: $pane,
                identifier: "catalog.pane"
            )
            HStack(spacing: 18) {
                switchSpecimen("On", isOn: true)
                switchSpecimen("Off", isOn: false)
                HStack(spacing: DSSpacing.sm) {
                    DSCheckboxBox(mark: .on)
                    Text("Checkbox").font(DSTypography.callout).foregroundStyle(DSColors.labelPrimary)
                }
            }
        }
    }
}

extension DSCatalogSegments {
    /// The switch as the board draws it: the track, then its word.
    private func switchSpecimen(_ title: String, isOn: Bool) -> some View {
        HStack(spacing: DSSpacing.sm) {
            DSSwitchTrack(isOn: isOn)
            Text(title).font(DSTypography.callout).foregroundStyle(DSColors.labelPrimary)
        }
    }
}

/// The JSON editor the endpoint editor and step sheet use, showing the board's body.
struct DSCatalogCodeEditor: View {
    @State private var text = """
    {
      "code": "OUT_OF_STOCK",
      "retryAfter": 3600,
      "partial": true
    }
    """

    var body: some View {
        DSCatalogCard("Code editor", detail: "SF Mono 12 on a 19 pt line. Quiet gutter, no permanent scroll track.") {
            // The board's well: five 19 pt lines, 10 pt above and below them, inside a hairline.
            DSJSONEditor(text: $text, identifier: "catalog.code")
                .frame(height: 5 * 19 + 2 * 10 + 2 * DSStroke.hairline)
        }
    }
}

/// One colour role as a light and dark pair, with what it resolves to underneath.
struct DSCatalogSwatch: View, Identifiable {
    enum Fill {
        /// An adaptive role, drawn as it resolves in each appearance.
        case role(Color)
        /// A fixed light and dark pair, for a role AppKit only resolves under a system setting, such
        /// as the separator under Increase Contrast.
        case inks(light: DSColors.Ink, dark: DSColors.Ink)
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
                half(isDark: false)
                half(isDark: true)
            }
            .frame(width: 96, height: 40)
            .clipShape(RoundedRectangle(cornerRadius: DSCornerRadius.segment, style: .circular))
            .overlay {
                RoundedRectangle(cornerRadius: DSCornerRadius.segment, style: .circular)
                    .strokeBorder(DSColors.fieldBorder, lineWidth: DSStroke.hairline)
            }
            Text(id)
                .font(monospacedName ? DSTypography.method : DSTypography.captionSemibold)
                .foregroundStyle(DSColors.labelPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .dsCatalogLineBox(DSCatalog.catalogLine, fontSize: 11, monospaced: monospacedName)
            Text(caption ?? hexPair)
                .font(DSCatalog.annotation)
                .foregroundStyle(DSColors.labelTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: 96, alignment: .leading)
    }

    @ViewBuilder
    private func half(isDark: Bool) -> some View {
        switch fill {
        case .role(let color):
            Rectangle().fill(Color(nsColor: resolved(color, dark: isDark)))
        case .inks(let light, let dark):
            Rectangle().fill(Color(nsColor: (isDark ? dark : light).nsColor()))
        case .material:
            Rectangle().fill(.regularMaterial).environment(\.colorScheme, isDark ? .dark : .light)
        }
    }

    private func resolved(_ color: Color, dark: Bool) -> NSColor {
        let dynamic = NSColor(color)
        var value = dynamic
        NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
            value = dynamic.usingColorSpace(.sRGB) ?? dynamic
        }
        return value
    }

    /// `#F6F6F7 · #1E1E20`, read from the role itself so the board cannot drift from the tokens.
    private var hexPair: String {
        switch fill {
        case .role(let color):
            "\(Self.hex(resolved(color, dark: false))) \u{00B7} \(Self.hex(resolved(color, dark: true)))"
        case .inks(let light, let dark):
            "\(Self.hex(light.nsColor())) \u{00B7} \(Self.hex(dark.nsColor()))"
        case .material:
            ""
        }
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
        .init(id: "Separator, high contrast",
              fill: .inks(light: DSColors.separatorHighContrastLightInk, dark: DSColors.separatorHighContrastDarkInk),
              caption: "Increase Contrast"),
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

#if DEBUG
/// One row of the Table card, from the Main board's request log: literal values, so the card shows
/// the shared table's look without the request log's types.
struct DSCatalogTableRow: View {
    static let time: CGFloat = 110
    static let method: CGFloat = 64
    static let status: CGFloat = 84
    static let scenario: CGFloat = 150
    static let duration: CGFloat = 84
    static let size: CGFloat = 76

    static let rows: [DSCatalogTableRow] = [
        DSCatalogTableRow(time: "21:46:12.418", method: "GET", path: "/products", status: 503,
                          scenario: "Out of stock", duration: "803 ms", size: "214 B"),
        DSCatalogTableRow(time: "21:46:12.380", method: "GET", path: "/products/42", status: 200,
                          scenario: "Default", duration: "8 ms", size: "640 B"),
        DSCatalogTableRow(time: "21:46:10.155", method: "GET", path: "/recommendations?limit=4", status: 404,
                          scenario: "Unmatched", scenarioColor: DSColors.warning, duration: "2 ms", size: "0 B"),
        DSCatalogTableRow(time: "21:46:09.771", method: "POST", path: "/payments", status: 503,
                          scenario: "Declined", duration: "1.2 s", size: "180 B"),
    ]

    let time: String
    let method: String
    let path: String
    let status: Int
    let scenario: String
    var scenarioColor: Color = DSColors.labelPrimary
    let duration: String
    let size: String

    /// White on the focused selection, as the request log's cells turn.
    @Environment(\.backgroundProminence) var prominence

    var body: some View {
        HStack(spacing: 0) {
            Text(time)
                .font(DSTypography.Figure.regular)
                .foregroundStyle(ink(DSColors.labelSecondary))
                .lineLimit(1)
                .dsTableCell(width: Self.time)
            DSMethodLabel(method, fixedWidth: false, identifier: "catalog.table.\(time)")
                .dsTableCell(width: Self.method)
            Text(path)
                .font(DSTypography.code)
                .foregroundStyle(ink(DSColors.labelPrimary))
                .lineLimit(1)
                .truncationMode(.middle)
                .dsTableCell(width: nil)
            DSStatusLabel(statusCode: status)
                .dsTableCell(width: Self.status)
            Text(scenario)
                .font(DSTypography.callout)
                .foregroundStyle(ink(scenarioColor))
                .lineLimit(1)
                .dsTableCell(width: Self.scenario)
            Text(duration)
                .font(DSTypography.Figure.regular)
                .foregroundStyle(ink(DSColors.labelSecondary))
                .lineLimit(1)
                .dsTableCell(width: Self.duration, alignment: .trailing)
            Text(size)
                .font(DSTypography.Figure.regular)
                .foregroundStyle(ink(DSColors.labelSecondary))
                .lineLimit(1)
                .dsTableCell(width: Self.size, alignment: .trailing)
        }
    }

    private func ink(_ color: Color) -> Color {
        prominence == .increased ? .white : color
    }
}
#endif

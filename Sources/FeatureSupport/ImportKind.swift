import Foundation

/// Which kind of file an import reads. Shared so the welcome window can offer both imports without
/// depending on the import workflow itself.
public enum ImportKind: Sendable, Identifiable {
    case har
    case openAPI

    public var id: Self { self }

    public var title: String {
        switch self {
        case .har: "Import from HAR"
        case .openAPI: "Import from OpenAPI"
        }
    }

    public var parsingMessage: String {
        switch self {
        case .har: "Parsing HAR file\u{2026}"
        case .openAPI: "Parsing OpenAPI spec\u{2026}"
        }
    }

    public var emptyHeading: String {
        switch self {
        case .har: "No HAR file loaded"
        case .openAPI: "No OpenAPI spec loaded"
        }
    }

    /// The glyph the empty state opens with. Both import flows used to have none, so the two screens
    /// were distinguishable only by reading them — and `DSEmptyState`'s icon is, in its own words,
    /// the fastest way to tell which empty state you are looking at.
    public var emptySystemImage: String {
        switch self {
        case .har: "doc.text.magnifyingglass"
        case .openAPI: "curlybraces"
        }
    }

    public var emptyMessage: String {
        switch self {
        case .har:
            "Select a HAR file exported from Charles, Proxyman, or browser DevTools."
        case .openAPI:
            "Select an OpenAPI v3 or Swagger 2 spec, as JSON. Each operation becomes a mock endpoint."
        }
    }

    public var emptyActionTitle: String {
        switch self {
        case .har: "Choose HAR file"
        case .openAPI: "Choose OpenAPI file"
        }
    }

    public var cancelAccessibilityIdentifier: String {
        switch self {
        case .har: "harImport.cancelButton"
        case .openAPI: "openAPIImport.cancelButton"
        }
    }

    public var parsingAccessibilityIdentifier: String {
        switch self {
        case .har: "harImport.parsing"
        case .openAPI: "openAPIImport.parsing"
        }
    }

    public var errorAccessibilityIdentifier: String {
        switch self {
        case .har: "harImport.error"
        case .openAPI: "openAPIImport.error"
        }
    }

    public var emptyAccessibilityIdentifier: String {
        switch self {
        case .har: "harImport.empty"
        case .openAPI: "openAPIImport.empty"
        }
    }

    public var rootAccessibilityIdentifier: String {
        switch self {
        case .har: "harImportView"
        case .openAPI: "openAPIImportView"
        }
    }
}

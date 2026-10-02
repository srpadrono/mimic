import SwiftUI

/// What a control sits on. Fields and secondary buttons take a firmer, white fill on a sheet in
/// light mode, as every sheet design draws them; in the window they keep the quiet grey wash.
public nonisolated enum DSSurface: Sendable {
    case window
    case sheet

    /// The fill inside a field or secondary button on this surface.
    public var fieldFill: Color {
        switch self {
        case .window: DSColors.field
        case .sheet: DSColors.sheetField
        }
    }

    /// The hairline around a field or secondary button on this surface.
    public var fieldBorder: Color {
        switch self {
        case .window: DSColors.fieldBorder
        case .sheet: DSColors.sheetFieldBorder
        }
    }
}

private nonisolated struct DSSurfaceKey: EnvironmentKey {
    static let defaultValue: DSSurface = .window
}

public nonisolated extension EnvironmentValues {
    /// The surface the controls below draw on. See ``dsSheetSurface()``.
    var dsSurface: DSSurface {
        get { self[DSSurfaceKey.self] }
        set { self[DSSurfaceKey.self] = newValue }
    }
}

public extension View {
    /// Marks this view as a sheet's content, so its fields and secondary buttons draw as sheet
    /// controls.
    func dsSheetSurface() -> some View {
        environment(\.dsSurface, .sheet)
    }
}

import CoreGraphics

/// Sizes for SF Symbols in the window's chrome. Nothing is drawn below ``minimum``.
public enum DSGlyph {
    /// 10pt — a disclosure or pop-up chevron beside a value, a jump-bar separator.
    public static let disclosure: CGFloat = 10
    /// 12pt — a glyph inside a field: search, a validation mark.
    public static let field: CGFloat = 12
    /// 14pt — a glyph inside a button beside its title: Format, Copy.
    public static let button: CGFloat = 14
    /// 15pt — an icon-only button in a panel header: add, clear, more.
    public static let control: CGFloat = 15
    /// 16pt — toolbar items, matching the system's own.
    public static let toolbar: CGFloat = 16
    /// 28pt — the symbol above an empty state's title.
    public static let illustration: CGFloat = 28

    /// The house-rule floor, stated so tests can assert against it. Not a size to draw at.
    public static let minimum: CGFloat = 8
}

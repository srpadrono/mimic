import CoreGraphics

/// Sheet widths. Forms of the same complexity keep one width.
public enum DSSheetWidth {
    /// A short creation form: new project, new endpoint, rename.
    public static let compact: CGFloat = 440
    /// A sheet with one list or explanation: update notes, templates.
    public static let medium: CGFloat = 560
    /// A multi-section form: journey step, server settings.
    public static let wide: CGFloat = 680
    /// A review table: import.
    public static let review: CGFloat = 860
}

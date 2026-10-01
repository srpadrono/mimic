import CoreGraphics

/// Sheet widths. Forms of the same complexity keep one width.
nonisolated public enum DSSheetWidth {
    /// A two-field form with a short hint: new project.
    public static let short: CGFloat = 377
    /// A short creation form: new endpoint, rename.
    public static let compact: CGFloat = 440
    /// A sheet with one list or explanation: update notes, templates.
    public static let medium: CGFloat = 560
    /// A multi-section form: journey step.
    public static let wide: CGFloat = 680
    /// A source list beside a multi-section form: server settings.
    public static let split: CGFloat = 760
    /// A review table: import.
    public static let review: CGFloat = 860
}

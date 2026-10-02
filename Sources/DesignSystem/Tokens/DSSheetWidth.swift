import CoreGraphics

/// Sheet widths. Forms of the same complexity keep one width.
nonisolated public enum DSSheetWidth {
    /// A two-field form with a short hint: new project.
    public static let short: CGFloat = 377
    /// A four-row creation form with a request field: new endpoint, at the new endpoint design's width.
    public static let endpoint: CGFloat = 407
    /// A short creation form: new scenario, rename.
    public static let compact: CGFloat = 440
    /// A sheet with one list or explanation: update notes, templates.
    public static let medium: CGFloat = 560
    /// A multi-section form: journey step, at the journey step design's width.
    public static let form: CGFloat = 580
    /// A wizard with a preview beside its form: the import flow.
    public static let wide: CGFloat = 680
    /// A source list beside a multi-section form: server settings.
    public static let split: CGFloat = 760
    /// A review table: import, at the import design's width.
    public static let review: CGFloat = 1000
}

import CoreGraphics

/// Width roles for modal sheets. Forms of the same complexity should not change width when a
/// person moves from creating a project to adding an endpoint or configuring a journey.
public enum DSSheetWidth {
    /// A short, single-column creation form.
    public static let compact: CGFloat = 420
    /// A detail sheet with one longer explanation or selection list.
    public static let medium: CGFloat = 540
    /// A multi-section configuration form with aligned columns.
    public static let wide: CGFloat = 640
    /// A review table that needs several readable columns.
    public static let review: CGFloat = 760
}

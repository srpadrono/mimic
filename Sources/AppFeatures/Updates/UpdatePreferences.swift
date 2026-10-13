import Domain
import Foundation

/// What this person has told Mimic about update checks.
///
/// Backed by the **session's** `UserDefaults`, never `.standard` directly — the same rule
/// `RecentProjectsStore` and `PanelLayoutStore` follow, and for the same reason: a UI test run that
/// wrote here would silently change the developer's real settings, and one that read here would
/// inherit them and stop being reproducible. `AppState.resolveDefaults` decides which suite that is.
final class UpdatePreferences: @unchecked Sendable {

    // Namespaced, because this is a shared suite with recents and the panel layout in it.
    private static let automaticChecksKey = "updates.automaticChecks"
    private static let lastCheckedAtKey = "updates.lastCheckedAt"
    private static let skippedVersionKey = "updates.skippedVersion"
    /// Set by an administrator, not by Mimic: a configuration profile for `devxa.Mimic`, or
    /// `defaults write devxa.Mimic updates.disabled -bool true`. README ▸ Managed installs documents it.
    static let updatesDisabledKey = "updates.disabled"

    /// How long after a check before another one is due.
    ///
    /// Once a day. A release happens every few weeks, so checking more often buys nothing and spends
    /// somebody's GitHub rate limit — which is shared per network address, so an office of Mimic
    /// users shares one allowance.
    static let checkInterval: TimeInterval = 60 * 60 * 24

    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// Whether Mimic may check on its own. On unless turned off.
    ///
    /// Read through `object(forKey:)` rather than `bool(forKey:)`: `bool(forKey:)` answers `false`
    /// for a key that was never written, which is indistinguishable from someone having turned it
    /// off, and would make the default the opposite of the one intended.
    var checksAutomatically: Bool {
        get { defaults.object(forKey: Self.automaticChecksKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Self.automaticChecksKey) }
    }

    /// Whether something outside Mimic owns updates, such as a company that pins versions through
    /// Homebrew or device management. Read-only: Mimic has no control that turns it on or off.
    ///
    /// A company that has approved one version must not find people on another the next morning, so
    /// this silences automatic checks **and** the manual menu item, not only the background check
    /// that ``checksAutomatically`` already covers.
    var updatesAreManaged: Bool {
        defaults.bool(forKey: Self.updatesDisabledKey)
    }

    var lastCheckedAt: Date? {
        get { defaults.object(forKey: Self.lastCheckedAtKey) as? Date }
        set { defaults.set(newValue, forKey: Self.lastCheckedAtKey) }
    }

    /// A version the user asked not to be told about again.
    var skippedVersion: ReleaseVersion? {
        get { (defaults.string(forKey: Self.skippedVersionKey)).flatMap(ReleaseVersion.init) }
        set {
            if let newValue {
                defaults.set(newValue.description, forKey: Self.skippedVersionKey)
            } else {
                defaults.removeObject(forKey: Self.skippedVersionKey)
            }
        }
    }

    /// Whether a background check is due now.
    ///
    /// Takes `now` rather than reading the clock, so the boundary is testable without waiting a day.
    func isAutomaticCheckDue(now: Date = Date()) -> Bool {
        guard checksAutomatically, !updatesAreManaged else { return false }
        guard let lastCheckedAt else { return true }
        // A restored backup or corrected system clock must not postpone checks indefinitely.
        guard lastCheckedAt <= now else { return true }
        return now.timeIntervalSince(lastCheckedAt) >= Self.checkInterval
    }
}

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
        guard checksAutomatically else { return false }
        guard let lastCheckedAt else { return true }
        // A `lastCheckedAt` in the future means the clock moved backwards — a timezone change, a
        // restored backup, a corrected system clock. Treating that as "not due yet" would disable
        // checks until real time caught up, which could be months.
        guard lastCheckedAt <= now else { return true }
        return now.timeIntervalSince(lastCheckedAt) >= Self.checkInterval
    }
}

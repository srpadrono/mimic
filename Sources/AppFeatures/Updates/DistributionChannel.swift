/// Where this copy of Mimic came from, which decides who updates it.
///
/// A compile-time answer rather than an Info.plist read: the store build is a separate archive, and
/// reading the bundle at launch is a path `UpdateService.resolveInstalledVersion` already explains
/// staying out of. `Scripts/package_app_store.sh` builds with `MIMIC_APP_STORE=YES`, which
/// Project.swift turns into the `MIMIC_APP_STORE` condition for this module.
nonisolated enum DistributionChannel: Sendable, Equatable {
    /// The signed installer from GitHub, or the Homebrew cask that installs it. Mimic checks for and
    /// installs its own updates, unless an administrator turned that off.
    case direct
    /// The Mac App Store, which installs updates itself and does not allow an app to update itself
    /// any other way (App Review Guideline 2.4.5).
    case appStore

    static var current: DistributionChannel {
        #if MIMIC_APP_STORE
        .appStore
        #else
        .direct
        #endif
    }
}

import Foundation
import Testing
@testable import Persistence

/// Where the project store lives, pinned against literals.
///
/// This is what makes an app update safe, and it is not enforced by anything else. The installer
/// replaces `/Applications/Mimic.app` and `/usr/local/bin/mimic` and touches nothing else, so the
/// store survives an update **because it is somewhere else** — inside the sandbox container, under
/// Application Support. A refactor that moved it inside the bundle, or into a directory keyed on the
/// version, would compile, pass every other suite, and quietly delete every project on the next
/// update.
///
/// The expected tail is written out as a literal rather than rebuilt from `DatabaseFactory`'s own
/// components. A test that assembles the path the same way the code does agrees with the code by
/// construction and cannot fail.
@Suite("Store location")
struct StoreLocationTests {

    private var resolved: URL {
        get throws { try DatabaseFactory.resolveDatabaseURL(environment: [:]) }
    }

    /// The part that is true everywhere: the directory and the filename.
    ///
    /// Split from the macOS path below because the suites this file lives in run on Linux too, where
    /// `applicationSupportDirectory` resolves to `~/.local/share` — so a single assertion pinning
    /// `/Library/Application Support` fails there for a reason that has nothing to do with the
    /// invariant being guarded. This half is the invariant: whatever the platform calls its
    /// application-support directory, Mimic's store is `devxa.Mimic/mimic.sqlite` inside it.
    @Test("The store is devxa.Mimic/mimic.sqlite inside application support")
    func storeDirectoryAndFilenameArePinned() throws {
        let path = try resolved.path
        #expect(path.hasSuffix("/devxa.Mimic/mimic.sqlite"), "\(path)")
    }

    /// And the whole macOS path, which is the one that ships.
    ///
    /// Written out as a literal rather than rebuilt from `DatabaseFactory`'s own components: a test
    /// that assembles the path the same way the code does agrees with it by construction. On a
    /// sandboxed build this sits inside the app's container, which is what an installer cannot reach
    /// and therefore what makes an update safe.
    @Test("On macOS that is Library/Application Support")
    func macOSStorePathIsPinned() throws {
        #if canImport(Darwin)
        let path = try resolved.path
        #expect(path.hasSuffix("/Library/Application Support/devxa.Mimic/mimic.sqlite"), "\(path)")
        #endif
    }

    /// The one that matters for updates: anything inside `Mimic.app` is replaced wholesale.
    @Test("The store is not inside an app bundle")
    func storeIsOutsideTheBundle() throws {
        let url = try resolved
        let components = url.pathComponents
        #expect(!components.contains { $0.hasSuffix(".app") }, "\(url.path)")
        #expect(!components.contains("Contents"), "\(url.path)")
    }

    /// A version-keyed directory would survive one update and orphan the data on the next.
    @Test("The store path carries no version number")
    func storePathIsVersionIndependent() throws {
        let path = try resolved.path
        #expect(!path.contains(ControlAPIVersionProbe.releaseVersion), "\(path)")
        // Resolving twice gives the same answer — no timestamps, no per-launch identifiers.
        #expect(try DatabaseFactory.resolveDatabaseURL(environment: [:]) == (try resolved))
    }

    @Test("Backups sit beside the store, not inside the bundle")
    func backupsLiveBesideTheStore() throws {
        let store = try resolved
        let backups = StoreBackup.directoryURL(for: store)

        #expect(backups.deletingLastPathComponent() == store.deletingLastPathComponent())
        #expect(backups.lastPathComponent == "Backups")
        #expect(!backups.pathComponents.contains { $0.hasSuffix(".app") })
    }

    /// The escape hatch a test run and the CLI share still works, and still expands `~`.
    @Test("MIMIC_DATABASE_PATH overrides the location")
    func environmentOverrideWins() throws {
        let explicit = try DatabaseFactory.resolveDatabaseURL(
            environment: [DatabaseFactory.databasePathEnvironmentKey: "/tmp/mimic-elsewhere/store.sqlite"]
        )
        #expect(explicit.path == "/tmp/mimic-elsewhere/store.sqlite")

        let tilde = try DatabaseFactory.resolveDatabaseURL(
            environment: [DatabaseFactory.databasePathEnvironmentKey: "~/mimic-elsewhere.sqlite"]
        )
        #expect(tilde.path == NSHomeDirectory() + "/mimic-elsewhere.sqlite")

        // An empty value is not an override — it must fall back rather than resolve to "".
        let empty = try DatabaseFactory.resolveDatabaseURL(
            environment: [DatabaseFactory.databasePathEnvironmentKey: ""]
        )
        #expect(empty == (try resolved))
    }
}

/// Reads the shipped version without importing Domain into a location test's assertions.
private enum ControlAPIVersionProbe {
    static let releaseVersion = "0.10.0"
}

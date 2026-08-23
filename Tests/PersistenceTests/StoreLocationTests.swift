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

    @Test("The store is Application Support/devxa.Mimic/mimic.sqlite")
    func storePathTailIsPinned() throws {
        let path = try resolved.path
        #expect(path.hasSuffix("/Library/Application Support/devxa.Mimic/mimic.sqlite"), "\(path)")
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

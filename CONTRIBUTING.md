# Contributing

## Build from source

Use macOS 26+, Xcode with Swift 6.2 or newer, and the Tuist version pinned in `mise.toml`:

```bash
mise install
tuist install && tuist generate --no-open
xcodebuild -workspace Mimic.xcworkspace -scheme Mimic -configuration Debug \
  -derivedDataPath .artifacts/DerivedData build
```

If mise is not activated in your shell, run Tuist through `mise exec --`. If Command Line Tools are selected, set `DEVELOPER_DIR` to the installed Xcode path. Re-run Tuist after changing `Project.swift` or `Tuist/Package.swift`; never patch a generated Xcode project.

`Package.swift` builds the portable modules from the same source folders as Tuist. Add a new target to both manifests; a new source file inside an existing buildable folder is picked up automatically. `swift test` runs the portable suites, including on Linux with SQLite development headers available. `Scripts/check_lockfiles.py`, `check_compiler_settings.py`, and `check_module_edges.py` guard the manifest contract.

## Test gates

Choose the smallest check that covers your change. For a portable change, select its suite:

```bash
swift test --filter RequestMatcherTests
xcodebuild -workspace Mimic.xcworkspace -scheme Mimic-Workspace test \
  -destination 'platform=macOS' -only-testing:DomainTests
```

For UI changes, select the affected methods and wait for each run to finish before starting another. Add more `-only-testing` arguments when the changed flow needs several cases:

```bash
xcodebuild -workspace Mimic.xcworkspace -scheme Mimic test \
  -destination 'platform=macOS' \
  -only-testing:MimicUITests/EndpointEditorUITests/testPrettyPrintFormatsTheJSONBodyAndTheResultPersists
```

The full UI suite runs only in CI's isolated shards. `Scripts/run_full_test_suite.sh` also requires a CI environment; it is not a local validation shortcut. For wider non-UI changes, use the workspace unit suites or the local gate:

```bash
swift test
xcodebuild -workspace Mimic.xcworkspace -scheme Mimic-Workspace test \
  -destination 'platform=macOS' -skip-testing:MimicUITests
xcodebuild -workspace Mimic.xcworkspace -scheme Mimic -configuration Release \
  CODE_SIGN_IDENTITY=- build
./Scripts/ci.sh
```

Use the Release build after a manifest or dependency change. `./Scripts/ci.sh` runs non-UI tests, Debug and Release builds, script checks, and the CLI end-to-end check with a disposable store and app copy. It does not replace CI's full UI gate. Read a script before changing its checks. `xcodebuild -workspace Mimic.xcworkspace -list` shows generated schemes; module schemes can run their own tests.

For documentation or script changes, run the applicable checks in `Scripts/`, including `python3 Scripts/check_doc_counts.py` for local links and test targets, `python3 -m unittest discover -s Scripts/tests -p 'test_*.py'` for script regressions, and `git diff --check`. A documentation edit does not need an XCUITest run. Coverage reports read existing result bundles; neither coverage nor source declaration counts prove that tests passed.

## Adding behavior

- Project-scoped operations belong in `Domain`'s `ProjectCommandExecutor`; host-scoped operations belong in the single `AppControlHost`. See [Architecture](docs/ARCHITECTURE.md).
- For a new control operation, add its `ControlCommand` and `CommandKind` cases, scope, implementation, sweep samples, catalog descriptor, CLI command, parse tests, and [CLI reference](docs/CLI.md). Keep the window and script on the same rule.
- New unit tests use Swift Testing. Build fixtures from literal expected inputs, independent of the function being tested. External-format parsers need realistic HAR, OpenAPI, and traffic shapes.
- UI controls need accessibility identifiers and labels. Changed flows need page-object XCUITests that wait for state, including error, empty, and edge cases. Keep test launch hooks in Debug builds.

UI tests must use an isolated `MIMIC_DEFAULTS_SUITE` and test-owned database path. `MIMIC_DATABASE_PATH` alone must not enable a reset; never open or delete the developer's `mimic.sqlite`. Launch through `UITestApp.launchAndBringToForeground`. SwiftUI toolbar menus may appear as `MenuButton` in accessibility queries; inspect `app.debugDescription` when a query misses.

## Releases

Update `MARKETING_VERSION` in `Project.swift` and `ControlAPI.releaseVersion` in `Sources/Domain/Control/ControlResult.swift` together. `ControlAPI.version` changes only for a breaking control API change. Regenerate the workspace after the version bump, run `./Scripts/ci.sh`, and require the full CI gates before release. Use `Scripts/package_release.sh` with the signing and notarization settings described in its header.

Only a signed, notarized, stapled installer that passes Gatekeeper assessment is copied to `.artifacts/release` for publication. Unsigned or signed-only development packages remain under `.artifacts/package`; missing or failed requested signing is an error. A passing build or fixture-based update test does not prove real installer acceptance. Record user-visible changes in [CHANGELOG.md](CHANGELOG.md).

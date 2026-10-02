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

For a change inside one UI section, run that section's own test target, which builds nothing else, and compare it with its design in the `MimicGallery` app ([Working on one section](docs/ARCHITECTURE.md#working-on-one-section)):

```bash
xcodebuild -workspace Mimic.xcworkspace -scheme Mimic-Workspace test -destination 'platform=macOS' -only-testing:EndpointsFeatureTests
```

To score one section against its design, name it in `TEST_RUNNER_MIMIC_SECTION`; the report's path is printed at the end:

```bash
TEST_RUNNER_MIMIC_SECTION=journeys xcodebuild -workspace Mimic.xcworkspace -scheme Mimic-Workspace test \
  -destination 'platform=macOS' -only-testing:DesignFidelityTests
```

Every gallery entry is also a snapshot test: `GallerySnapshotTests` (in `DesignFidelityTests`) renders each entry in light and dark and fails when it no longer matches its approved PNG in `Tests/DesignFidelityTests/Snapshots/`. Check sizes, spacing and colours there rather than in an XCUITest; it runs in seconds and does not take over the mouse. Baselines are recorded by CI, because fonts rasterise differently on another macOS version: when an entry is new or changed on purpose, the failing CI run pushes the new renderings to the `snapshots/<your branch>` branch (with a difference image for each change under `Differences/`) and uploads them as the `snapshots` artifact. Look at them, then take the approved ones with `git fetch origin snapshots/<your branch>` and `git checkout FETCH_HEAD -- Tests/DesignFidelityTests/Snapshots`, and commit.

For UI changes, select the affected methods and wait for each run to finish before starting another. Add more `-only-testing` arguments when the changed flow needs several cases:

```bash
xcodebuild -workspace Mimic.xcworkspace -scheme Mimic test \
  -destination 'platform=macOS' \
  -only-testing:MimicUITests/EndpointEditorUITests/testPrettyPrintFormatsTheJSONBodyAndTheResultPersists
```

macOS remembers privacy grants, such as access to your Documents folder, against the app's signature. Debug builds are signed ad hoc by default, so every rebuild asks again. To keep the grant, copy `Configs/Local.xcconfig.example` to `Configs/Local.xcconfig` (gitignored) and regenerate; your Debug builds are then signed with your Apple Development certificate. CI never has that file and stays ad hoc.

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

### What CI runs

A pull request or push runs only the tests its changes can break. CI's first job, `Scripts/select_tests.py`, reads the changed files and `Scripts/test_selection.json`:

- a file in a module runs the unit test targets of that module and of every module that depends on it, plus the UI test classes `ui_classes_by_target` names for that module and the smoke shard;
- a UI test file runs its own shards; a shared UI support file runs them all;
- documentation and scripts run only the Linux job;
- `Project.swift`, `Tuist/`, `Configs/`, `mise.toml`, the CI workflow and the selection itself run everything, and so does a file that belongs to no module.

The full suite (every unit target, every UI shard and the Release build) and the coverage badges run nightly. Run it on demand from the CI workflow's **Run workflow** button with **full** ticked. The run's summary page lists what was selected and why.

To reproduce a UI failure without the rest of the suite, run the CI workflow by hand with `only_testing` set to the failing tests (`EndpointEditorUITests/testMethodPickerCreatesAPostEndpoint`, or a class name) and, for a suspected flake, `iterations` above 1: it repeats them until one fails. It runs on the same macOS image as CI and does not take over your mouse.

A new module the app links needs an entry in `ui_classes_by_target`, and a new UI test method needs a shard in `ui_shards`; `select_tests.py --check` and `check_ui_shards.py` fail until it has one.

## Adding behavior

- Project-scoped operations belong in `Domain`'s `ProjectCommandExecutor`; host-scoped operations belong in the single `AppControlHost`. See [Architecture](docs/ARCHITECTURE.md).
- For a new control operation, add its `ControlCommand` and `CommandKind` cases, scope, implementation, sweep samples, catalog descriptor, CLI command, parse tests, and [CLI reference](docs/CLI.md). Keep the window and script on the same rule.
- New unit tests use Swift Testing. Build fixtures from literal expected inputs, independent of the function being tested. External-format parsers need realistic HAR, OpenAPI, and traffic shapes.
- UI controls need accessibility identifiers and labels. Changed flows need page-object XCUITests that wait for state, including error, empty, and edge cases. Keep test launch hooks in Debug builds.

UI tests must use an isolated `MIMIC_DEFAULTS_SUITE` and test-owned database path. `MIMIC_DATABASE_PATH` alone must not enable a reset; never open or delete the developer's `mimic.sqlite`. Launch through `UITestApp.launchAndBringToForeground`. SwiftUI toolbar menus may appear as `MenuButton` in accessibility queries; inspect `app.debugDescription` when a query misses.

## Releases

Update `MARKETING_VERSION` in `Project.swift` and `ControlAPI.releaseVersion` in `Sources/Domain/Control/ControlResult.swift` together. `ControlAPI.version` changes only for a breaking control API change. Regenerate the workspace after the version bump, run `./Scripts/ci.sh`, and require the full CI gates before release. Use `Scripts/package_release.sh` with the signing and notarization settings described in its header.

Only a signed, notarized, stapled installer that passes Gatekeeper assessment is copied to `.artifacts/release` for publication. Unsigned or signed-only development packages remain under `.artifacts/package`; missing or failed requested signing is an error. A passing build or fixture-based update test does not prove real installer acceptance. Record user-visible changes in [CHANGELOG.md](CHANGELOG.md).

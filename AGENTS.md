# Agent guide

This is the repository guidance for coding agents. `CLAUDE.md` delegates here. Read [Architecture](docs/ARCHITECTURE.md) for the module map, [Contributing](CONTRIBUTING.md) for build and test commands, and the relevant product reference before editing behavior.

## First steps

- Check `pwd` and `git status --short --branch`. Preserve unrelated work.
- Inspect the affected source, tests, and the nearest documentation. Verify claims against the current tree.
- Use the Tuist-generated `Mimic.xcworkspace` for app builds. After changing `Project.swift` or `Tuist/Package.swift`, run `tuist install && tuist generate --no-open` with the version in `mise.toml`. Do not edit generated projects.
- Run focused checks for the changed surface. Report exactly what ran and what could not be verified. [Contributing](CONTRIBUTING.md#test-gates) lists the commands.

## Where behavior belongs

- `Domain` owns models, request matching, journey resolution, validation, and `ControlCommand` rules. Keep it independent of SwiftUI, Vapor, and GRDB.
- Project-scoped operations go through `ProjectCommandExecutor.apply(_:to:)`, which returns `nil` only for host-scoped commands and reports whether a project mutated. Do not implement a project rule again in a view or CLI command.
- Server lifecycle, project selection, the live journey cursor, and request log belong to `AppControlHost` in `AppFeatures`. It is the sole production `ControlHost`, including in headless mode. Do not create another host in `ControlPlane`.
- `MockServerEngine` owns the serving actor and live cursor; read, resolve, and advance the cursor in one actor hop. `Persistence` implements the `ProjectRepository` port. `MimicCLICore` is a client and must not link Vapor or GRDB.
- Spec import and update installation are window workflows. `project import` loads a Mimic project export; `app update-check` is automatable. See [CLI](docs/CLI.md).

## Change checklists

**Operation:** add the `ControlCommand` and `CommandKind` cases, classify its scope, implement it in the executor or host, add samples in `HostCommandSweepTests.sample(for:)` and `ControlCommandSamples.all`, a `CommandCatalog` descriptor, the CLI verb and parsing coverage, and update [CLI](docs/CLI.md). Preserve stable error codes. The catalog and sweep tests check surface coverage.

**View or navigation:** give interactive controls accessibility identifiers and labels; cover changed happy, error, empty, and edge flows with page-object XCUITests. Keep test hooks behind `#if DEBUG`. Use an isolated test database and defaults suite; never let a UI test open or delete the developer's `mimic.sqlite`.

**Test fixtures:** write expected external inputs as literals, independent of the function under test. Ask whether reverting that function would make the test fail. Use Swift Testing for new unit tests and XCTest for UI tests. UI tests wait for state with `waitForExistence(timeout:)` or `UITestApp.waitForAny`, not sleeps.

## Project rules

- SwiftUI: `@Observable` for new state, modern `.alert`, cancellable `Task.sleep`, and `@MainActor` for UI updates. Use sentence case inside the window and Title Case in the menu bar. Follow the `DS*` size and color tokens, including `DSGlyph` with an 8 pt minimum; honor Reduce Motion for repeating animation.
- Control API: bind only `127.0.0.1`. Keep the discovery file `0600`. Send a discovered token only to the advertised loopback port; remote or forwarded connections require an explicit token. Read [Security](SECURITY.md) and [CLI discovery](docs/CLI.md#finding-an-instance) before changing this path.
- The module, compiler, lockfile, house-rule, and documentation checks live in `Scripts/`; run the relevant ones when their inputs change. Do not treat a green script as proof of UI behavior.

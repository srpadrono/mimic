---
name: mimic-ui-tests
description: Mimic's Definition of Done for view and navigation changes, and the XCUITest contract behind it — accessibility identifiers, the launch/activation retry, `waitForAny`, and the store-isolation rule that keeps a test run from deleting the developer's real `mimic.sqlite`. Use when adding or changing a SwiftUI view or navigation, writing or debugging anything in `MimicUITests`, or touching UserDefaults/database isolation or a launch hook.
---

# UI Changes — Definition of Done

When adding or modifying views or navigation:

1. **Add accessibility identifiers** to all interactive elements and key labels used for assertions.
2. **Write or update XCUITests** covering the changed flows. `MimicUITests/` is four files, not one,
   so put the test where its feature already lives: `MimicUITests.swift` (welcome, workspace,
   endpoint editor, inspector, request log), `JourneyUITests.swift` (the journeys navigator and its
   sheets), `ControlPlaneIsolationTests.swift` (the discovery file a run must not touch), and
   `AppLaunchSupport.swift`, which is not a suite at all — it is `UITestApp`, home of the
   launch-and-activate contract and `waitForAny` that the rules below make mandatory. Page objects
   sit at the top of the file whose flows use them.
3. **Run the UI test suite** and verify it passes before considering the work complete.
4. **Keep test-only code out of production sources** — use `MIMIC_DEFAULTS_SUITE` for UserDefaults
   isolation, a **separate store** for persistence isolation, and `#if DEBUG` for launch hooks.
   The launch contract (`UITestApp.launchAndBringToForeground`) also exports `MIMIC_CONTROL_FILE`
   to a per-run throwaway sidecar, so no UI run can overwrite — then delete — the developer's
   shared `control.json` credential file; a suite that names its own override keeps it.

   **A UI test run must never open, and never delete, `mimic.sqlite`.** It used to do both: the suite
   launches the real app, the real app opened the real database, and `UITestSupport.resetApp` computed
   that same path and deleted it at the start of every test. Running the suite on a development
   machine silently destroyed the developer's projects and left the runner's fixtures in their place.
   It cost this repository a project before anyone noticed, because the damage looks exactly like
   "the recents list is empty".

   The isolation is now one property, `UITestSupport.databaseURL`, which `AppState` opens and
   `defaultResetContext` deletes — so the file a run writes and the file a run removes cannot drift
   apart. It resolves to `mimic-uitests.sqlite`, beside the real store rather than in `/tmp` because
   the app is sandboxed and Application Support *is* its container. It returns `nil` outside a UI test
   run, which is what makes the reset inert everywhere else, and a bare `MIMIC_DATABASE_PATH` does
   **not** arm it — `Scripts/run_cli_e2e.sh` exports exactly that to share a throwaway store with the
   CLI, and arming there would delete the store the script just set up.

   **The same rule binds anything that can destroy a store, not just a test reset.** GRDB's
   `eraseDatabaseOnSchemaChange` was set under `#if DEBUG` in `AppMigrations.migrator` — the migrator
   the app runs against the real `mimic.sqlite`. It drops the file and rebuilds it empty on any
   schema difference, and Debug is the configuration every developer runs, so the next migration
   anybody added would have deleted every project of everyone who pulled it, with the damage again
   looking exactly like "the recents list is empty". It is now opt-in via
   `MIMIC_ERASE_DB_ON_SCHEMA_CHANGE` **and** honoured only alongside an explicit
   `MIMIC_DATABASE_PATH`, so it can only ever reach a store somebody deliberately named. A
   convenience that erases must never be able to compute its own target.

   If you add another kind of persisted state, isolate it the same way: give the test run its own,
   and never let a reset compute a production path for itself.
5. **Use XCTest for UI tests** (Swift Testing does not support XCUITest).
6. **Launch through `UITestApp.launchAndBringToForeground`.** `XCUIApplication.launch()` returns once
   the process is running, which is not the same as having a window the accessibility layer can see —
   the app may come up hidden or behind the runner. A suite written without the activation retry fails
   every test on "welcome screen should appear", which reads like a broken app rather than a broken
   test.
7. **Check what AppKit actually realizes an element as.** A SwiftUI `Menu` in a toolbar becomes a
   `MenuButton`, not a `Button`, so `app.buttons[…]` never matches it; a `DSEmptyState`'s text arrives
   as the element's `value` rather than its label. When a query finds nothing, dump
   `app.debugDescription` and match against reality instead of guessing the element type.
8. **A container's `.accessibilityIdentifier` overrides its descendants', and `.contain` does not
   reliably stop it.** The rule for a leaf control inside a named container is: **target it by label,
   not by identifier.** Keep setting the identifier — it costs nothing and it lands whenever SwiftUI
   does not flatten — but never write a query that assumes it did without dumping the tree first.

   Two more rules live with it: do **not** pair `.contain` with an identifier a wrapper is lending to
   the single control inside it, and a `.contextMenu` must attach **after**
   `.accessibilityElement(children: .ignore)`, never beneath it.

   All three have cost this suite real time, and the evidence for each — the tree dumps, the five
   consecutive CI failures that read as a flaky modifier — is in
   [`references/accessibility-tree.md`](references/accessibility-tree.md). Read it before writing a
   query against a container.
9. **Never write `a.waitForExistence(t) || b.waitForExistence(t)`.** It waits out `a`'s entire timeout
   before it ever looks at `b`, so a short-lived `b` can appear and vanish inside `a`'s wait and the
   test fails claiming neither was seen. Use `UITestApp.waitForAny([a, b], timeout:)`, which polls
   them together. The autosave indicator is the case that bites: `.saving` lasts only as long as a
   SQLite write, and `.saved` clears after two seconds.

## The generic XCUITest rules

Page objects, no `sleep()`, accessibility-id targeting, state configured through the launch
environment rather than the UI, and coverage of happy path / error / empty / edge cases. An
`xcuitest-pro` skill is **not** vendored here — `find . -iname '*xcuitest*'` returns nothing. Agents
run with their own skill sets and some do carry one; if yours does, use it alongside this file. The
rules above are the ones a generic skill would not tell you, because they came out of this suite.

## Running it

```bash
xcodebuild -workspace Mimic.xcworkspace -scheme Mimic test \
  -destination 'platform=macOS' -only-testing:MimicUITests
```

If the runner reports `Timed out while enabling automation mode` with zero tests executed, that is
the SIP-protected `automationmode-writer` service, not your suite — see the `mimic-build-and-test`
skill's `references/ci.md` for what CI does about it.

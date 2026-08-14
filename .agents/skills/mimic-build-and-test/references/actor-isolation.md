# `SWIFT_DEFAULT_ACTOR_ISOLATION`, per target

Swift 6.2 with `SWIFT_APPROACHABLE_CONCURRENCY = YES` everywhere, and
`SWIFT_DEFAULT_ACTOR_ISOLATION` set **per target, not project-wide**. The shared base in
`Project.swift` sets it to `MainActor`, and fourteen targets then override it to `"none"`:
`Domain`, `MockServerEngine`, `Persistence`, `ControlPlane`, `MimicCLICore`, `SpecImport`, the
`MimicCLI` tool, each of their six test targets, and `MimicUITests`. Only five targets actually
compile under `MainActor` — `DesignSystem`, `DesignSystemTests`, `AppFeatures`, the `Mimic` app,
and `MimicTests` — which is to say: **the SwiftUI half is MainActor-by-default and the portable
half is not.**

The overrides are not incidental. Each one is a place where main-actor inference would be wrong
rather than merely unnecessary, and `Project.swift` says which above each target: MainActor on
`Domain`'s struct inits would stop nonisolated modules constructing Domain values at all; the
engine lives on NIO threads; GRDB's closures run off the main queue and deadlock against
`DatabaseQueue`; `SpecImport` is called from `Task.detached`; and `XCTestCase`'s lifecycle methods
are nonisolated, so `MimicUITests` cannot compile with it. Read the default as "MainActor when
there is a window involved".

`Package.swift` sets no `defaultIsolation` at all, so on Linux the portable modules take the
language default — nonisolated — which happens to be what the fourteen `"none"` overrides ask for.
The two agree by coincidence, not by construction, and changing the base setting in `Project.swift`
would not move Linux with it. `Scripts/check_compiler_settings.py` says exactly that on every run,
in those words, next to the other three `SWIFT_*` settings in the shared base — but it *reports*;
the Swift-settings half of that script never fails a build. Nothing enforces the agreement.

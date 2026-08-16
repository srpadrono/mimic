---
name: mimic-build-and-test
description: How Mimic builds, which scheme runs which suite, what CI covers on Linux versus macOS, and the caveats behind the e2e script. Use when running or changing a build, picking a `-scheme`, editing `.github/workflows/ci.yml`, `Scripts/ci.sh` or any `Scripts/check_*` gate, touching `Package.swift`/`Project.swift`/lockfiles, chasing a Linux-only failure, or refreshing coverage.
---

# Building and testing Mimic

The canonical command block lives in [AGENTS.md](../../../AGENTS.md) under "Build & Test Commands" —
it is always in context, so it is not repeated here. This skill is what stands behind it: which
scheme actually runs a suite, what each CI job covers, and the two scripts whose caveats cost a day
if you meet them cold.

After changing `Project.swift` or `Tuist/Package.swift`, run `tuist install && tuist generate`.

## Which scheme runs what

`Project.swift` declares **exactly one** scheme — confirm with `grep -c '\.scheme(' Project.swift`,
which answers `1`, for the `Mimic` scheme at the bottom of the file. Every other name you will see
passed to `-scheme` in this repository (`Mimic-Workspace`, `Domain`, `MockServerEngine`,
`Persistence`, `ControlPlane`, `MimicCLICore`, `DesignSystem`, `SpecImport`) is **inferred by Tuist**
at generation time, not written by anyone here.

This section used to say the per-module schemes "build the frameworks but do not bundle their test
targets", and that is why `Mimic-Workspace` was presented as the only way to run a unit suite. It
cannot be right: [`Scripts/run_full_test_suite.sh`](../../../Scripts/run_full_test_suite.sh) — the
only writer the README's coverage section has actually had, CI's `record-coverage` job being blocked
by branch protection ([`references/ci.md`](references/ci.md)) — runs
`xcodebuild -scheme Domain test` and six more against exactly
those schemes, and `Scripts/update_readme_coverage.py` then reads the `Domain.xcresult`,
`ControlPlane.xcresult` … bundles they leave behind. A scheme with nothing testable in it fails
immediately with *"Scheme X is not currently configured for the test action"* and produces no bundle,
so seven of that script's steps would be dead on arrival and it could never produce the coverage
section it is written to produce. Tuist's inferred schemes group a target with the suites whose names
extend it, and every test target here is named `<Module>Tests` for exactly that reason.

So: `Mimic-Workspace` is the scheme to reach for because it builds and tests **everything** in one
pass, not because the per-module ones cannot test. Prefer the smallest scheme that contains the suite
you are iterating on — it compiles less. Neither claim can be checked from inside this file; the
generated workspace is the authority, and it answers in one command:

```bash
xcodebuild -workspace Mimic.xcworkspace -list      # every scheme Tuist actually generated
```

## References

Load the one that matches what you are doing — they are independent.

| File | Read it when |
|------|--------------|
| [`references/ci.md`](references/ci.md) | Editing the workflow, adding a gate, or explaining why a job is red |
| [`references/cli-e2e.md`](references/cli-e2e.md) | Running `run_cli_e2e.sh` — `ci.sh` gates on it and the macOS job runs it non-gating — or touching discovery-file/Linux-portability code |
| [`references/actor-isolation.md`](references/actor-isolation.md) | Changing `SWIFT_DEFAULT_ACTOR_ISOLATION`, adding a target, or reading a concurrency error that only appears in Xcode |
| [`references/real-inputs.md`](references/real-inputs.md) | Adding a feature that parses external input (HAR, OpenAPI, Swagger, live traffic) |

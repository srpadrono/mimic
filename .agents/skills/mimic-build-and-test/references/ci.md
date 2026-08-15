# What CI actually covers

CI runs on every pull request and on every push to `main`, in three jobs. Two are split by what
actually needs a Mac; the third, `record-coverage`, is a short Linux job that runs only on pushes to
`main` and writes the coverage the macOS job measured into the README's two badges and its
`coverage:generated` block. It is the only job in the workflow holding `contents: write`, and it
holds it precisely so that the job compiling code out of a pull request does not — see the comments
above it and above `Emit coverage figures`. Both runners are free: GitHub does not meter standard
hosted runners on public repositories, macOS included.

**Linux** builds through [`Package.swift`](../../../../Package.swift) rather than Tuist — the domain rules, mock
engine, persistence, control plane, spec import and CLI are plain Swift, so most of the suite reports
back in a couple of minutes. Both manifests declare those modules from the same directories, so they
cannot drift in what they compile, only in how targets are declared. What they *can* drift in is
dependency resolution: they resolve the same ranges into two separate lockfiles, and 21 packages —
Vapor, NIO and GRDB among them — had already diverged, so this job was passing against versions the
shipped `.pkg` does not contain. `Scripts/check_lockfiles.py` compares the two before the job builds
anything, and a second step fails if `swift build` *re-resolved* `Package.resolved` on the way past —
otherwise the versions the job tested are not the versions the commit names, and the drift check
would have passed on a file the build then rewrote. The macOS job holds `tuist install` to the same
rule for `Tuist/Package.resolved`.

Compiler settings are the other half, and `Scripts/check_compiler_settings.py` splits them by what a
disagreement costs. **The deployment floor fails**: `MACOSX_DEPLOYMENT_TARGET` in `Project.swift`
against `platforms:` in `Package.swift` are one fact written twice, they have already come apart, and
comparing two literals needs no toolchain. **The Swift settings warn.** `Project.swift`'s shared base
sets four; run the script and it prints where each stands — today
`SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY` and `SWIFT_APPROACHABLE_CONCURRENCY` have no
SwiftPM counterpart, so Linux still accepts an implicit transitive import that Xcode rejects, while
`SWIFT_VERSION` and `SWIFT_DEFAULT_ACTOR_ISOLATION` are annotated as already-equivalent rather than
missing. Declaring the two on the SwiftPM side is the fix; it warns rather than fails because turning
them on lights up every portable module at once, and going red before anyone can iterate on the
errors helps nobody. The gap is visible on every run instead of silent, and the step goes quiet on
its own the day `swiftSettings:` lands.

**macOS** (`macos-26`) covers everything that needs Xcode: `tuist generate`, the Debug build, the
app-level suites, **the XCUITest suite**, the CLI end-to-end check — non-gating, for the reason
below — and the Release gate. The image label is load-bearing — macOS 26 and Swift
6.2 are the compile floor, not a preference.

Two things about the macOS job are worth knowing before you edit it:

- **`sudo automationmodetool enable-automationmode-without-authentication` is what makes XCUITest
  possible at all.** Since Monterey, macOS asks a human to approve UI automation before a runner may
  drive another app. Nobody is at the keyboard on CI, so without it the runner fails to initialise
  and reports `Timed out while enabling automation mode` with *zero tests executed* — which reads
  like a broken suite rather than a missing permission. The same message appears locally when the
  SIP-protected `automationmode-writer` service wedges; see the `mimic-ui-tests` skill.
- **Everything is signed ad-hoc (`CODE_SIGN_IDENTITY=-`).** The project carries a `DEVELOPMENT_TEAM`
  for local builds, and a hosted runner has none of that team's certificates. It does not need them:
  a macOS app only has to be signed *somehow* to launch.

This was not always possible. While the repo was private, every run died in about two seconds with
zero steps executed, on Linux and macOS alike, because of a billing block — which is why the triggers
used to be commented out and the macOS job disabled. Making the repo public resolved it.

`./Scripts/ci.sh` runs the same gates locally and is still the fastest way to check before pushing,
in this order: lockfiles, compiler settings, module edges, `swift test`, `tuist install && generate`,
the Debug build, every unit suite, the Release gate, the UI suite, `check_house_rules.sh --self-test`
followed by the real house rules scan, `check_doc_counts.py --self-test` followed by the real count
check, `check_skills.py`, and — last, and gating here from the start — the CLI end-to-end check. The
three manifest checks near the top run before anything
compiles, `check_module_edges.py` among them, because a drift there makes every step below it test a
build that does not ship. Its own header names the three things it cannot reproduce — `swift test`
runs on this machine's toolchain rather than in the `swift:6.2` container, the UI suite runs without
CI's `-retry-tests-on-failure`, and runner setup is absent — so read it rather than treating a green
local run as a green CI run.


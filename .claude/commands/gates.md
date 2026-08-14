---
description: Run every gate this machine can actually run, and report honestly which ones it could not.
allowed-tools: Bash, Read, Glob, Grep
---

Run the repository's gates against the working tree and report the result.

**First decide what this machine can run.** `command -v xcodebuild swift tuist` settles it in one
call — do not assume from the platform, and do not skip this step because a previous session had a
toolchain.

## Always runnable — no toolchain needed, by design

```bash
python3 Scripts/check_doc_counts.py
python3 Scripts/check_module_edges.py
python3 Scripts/check_compiler_settings.py
python3 Scripts/check_lockfiles.py
./Scripts/check_house_rules.sh --self-test && ./Scripts/check_house_rules.sh
```

Run all five. They need only the Python stdlib and find/awk/grep, and they catch real regressions: a
documented count that no longer matches the tree, a forbidden module edge, a lockfile drifted from
the one the shipped `.pkg` was built against, a house rule broken in a way a grep can settle.

The house-rule self-test runs **before** the real scan for a reason — it plants each forbidden
pattern and requires the scanner to catch it, so a scan that passes because its regex broke is told
apart from a scan that passes because the tree is clean.

`check_compiler_settings.py` exits 0 while printing a WARNING about Swift settings `Package.swift`
does not declare. That is the designed behaviour, not a failure to fix — read the warning, leave it
alone unless you are the one landing `swiftSettings:`.

## Needs Xcode — run only if the toolchain is present

```bash
./Scripts/ci.sh
```

That is the whole local gate set: lockfiles, compiler settings, `swift test`, `tuist install &&
generate`, the Debug build, every unit suite, the Release gate, the UI suite, and the two checks
above. Read its header first — it names the three things it cannot reproduce, so a green run here is
not a green CI run.

If you only need one suite, prefer the smallest scheme containing it over `Mimic-Workspace`; the
`mimic-build-and-test` skill explains which schemes exist and what each one bundles.

## Reporting

State each gate's result plainly. **If the toolchain was absent, say so and name what went
unverified** — do not describe a Swift change as tested when no Swift ran. On this repository that
matters more than usual: the macOS CI job is the only thing that compiles the app, and a pull
request described as verified when it was not is how a red pipeline becomes a surprise.

If a gate fails, fix the cause rather than the assertion. Each of these scripts was written after the
drift it detects had already shipped once; a failing count almost always means the tree changed and
the documentation did not.

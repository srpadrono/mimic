#!/usr/bin/env python3
"""Compares how Project.swift and Package.swift configure the compiler.

The lockfiles are checked next door by `check_lockfiles.py`; this is the other half of the same
drift. Both manifests build the portable modules from the same directories, so they cannot disagree
about *what* they compile — only about how. Two kinds of disagreement, and they are not equally
serious, so this file treats them differently.

**The deployment floor is a gate.** `Project.swift` sets `MACOSX_DEPLOYMENT_TARGET` in its shared
base and `Package.swift` sets `platforms:`; they are the same fact written twice, and they have
already come apart. Package.swift's own comment records it: `platforms:` said `.v15` — eleven majors
below the value in `Project.swift`, CONTRIBUTING.md, the README badge and the installer's
`<os-version min>` — and nothing caught it, because no CI job builds that manifest on a Mac and
Linux ignores `platforms:` entirely. A contributor running `swift build` compiled the portable
modules against a macOS 15 availability floor while Xcode used 26, so an API introduced in between
built in one and errored in the other. Comparing two literals needs no toolchain, so this half
fails.

**The Swift settings are a warning.** `Project.swift` sets four in its shared base and
`Package.swift` sets none, which makes the Linux job the looser gate: it accepts an implicit
transitive import that Xcode rejects, because member-import visibility is enforced there and not
here. That gap cannot be closed by editing a manifest and hoping — turning the setting on lights up
every portable module at once, and the errors have to be read off a real Swift 6.2 compiler while
you fix them. Failing here would mean iterating against a red pipeline, which is how a gate stops
being read. So it is reported on every run, in the job summary, and closes itself the day
`swiftSettings: [.enableUpcomingFeature(...)]` lands in `Package.swift`.

It lives in a file rather than inside the two runners because it used to be pasted into both
`Scripts/ci.sh` and `.github/workflows/ci.yml`, under a comment in ci.sh promising the copies were
"character-for-character" identical "so a diff between the two files shows drift at a glance". They
had drifted: diffed after dedent, the lockfile program matched and this one did not — the comment
policing the duplication was itself the thing that was wrong. A shared file cannot drift from itself.

Runs before anything is compiled, so: stdlib only, no arguments. Paths are resolved from this file's
location rather than the working directory, so it answers the same from anywhere.
"""

import os
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent


def annotate(kind, path, message):
    print(("::%s file=%s::%s" if os.environ.get("GITHUB_ACTIONS") else "%s (%s): %s")
          % (kind if os.environ.get("GITHUB_ACTIONS") else kind.upper(), path, message))


def warn(path, message):
    annotate("warning", path, message)


def error(path, message):
    annotate("error", path, message)


def without_line_comments(text):
    """Drops whole-line `//` comments.

    Both manifests explain themselves at length, and a setting merely *named* in prose must not be
    able to stand in for one that is actually set — that is the whole failure this file exists to
    catch. Trailing comments are left alone on purpose: `//` also appears inside every
    `.package(url:)`, and cutting there would mangle the manifest being read. (The house-rule
    scanner has a real lexer for that problem; it is not worth one here, because neither thing this
    reads for is ever written after a trailing comment.)
    """
    return "\n".join(l for l in text.splitlines() if not l.lstrip().startswith("//"))


def normalized_version(text):
    """(26, ) for "26.0", ".v26" and "26"; (10, 15) for ".v10_15".

    Trailing zeros are dropped so the two spellings of the same floor compare equal — Xcode writes
    `26.0` where SwiftPM writes `.v26`, and a mismatch reported between those two would be noise
    that teaches people to ignore this check.
    """
    parts = [int(p) for p in re.findall(r"\d+", text)]
    while len(parts) > 1 and parts[-1] == 0:
        parts.pop()
    return tuple(parts)


def check_deployment_target(project_block, package):
    """The gate. Returns a list of (manifest, failure) pairs; empty means the two floors agree."""
    xcode = re.search(r'"MACOSX_DEPLOYMENT_TARGET"\s*:\s*"([^"]*)"', project_block)
    swiftpm = re.search(r'\.macOS\(\s*(?:"([0-9.]+)"|\.v([0-9_]+))\s*\)', package)

    if xcode is None:
        return [("Project.swift",
                 "Project.swift's shared base no longer sets MACOSX_DEPLOYMENT_TARGET, so there "
                 "was nothing to compare Package.swift's platforms: against. Point this check at "
                 "wherever the deployment floor moved to.")]
    if swiftpm is None:
        return [("Package.swift",
                 "Package.swift declares no `.macOS(...)` in platforms:, so SwiftPM builds the "
                 "portable modules against its own default floor while Xcode uses "
                 f"MACOSX_DEPLOYMENT_TARGET = {xcode.group(1)}. Declare the same floor here.")]

    swiftpm_text = swiftpm.group(1) or (".v" + swiftpm.group(2))
    if normalized_version(xcode.group(1)) != normalized_version(swiftpm_text):
        return [("Package.swift",
                 f"Deployment floors disagree: Project.swift MACOSX_DEPLOYMENT_TARGET = "
                 f"{xcode.group(1)}, Package.swift platforms: = .macOS({swiftpm_text}). "
                 "`swift build` then compiles the portable modules against a different "
                 "availability floor than the one that ships them, so an API introduced between "
                 "the two builds in one manifest and errors in the other. This has shipped once "
                 "already, at .v15 against 26.0.")]

    print(f"  Deployment floor agrees: {xcode.group(1)} in both manifests.")
    return []


# Spelled differently in the two manifests but meaning the same thing today. Printed every run,
# because that is a fact about the current tree rather than a property of either file.
EQUIVALENT_TODAY = {
    "SWIFT_VERSION":
        "swift-tools-version 6.0 already puts SwiftPM in language mode 6",
    "SWIFT_DEFAULT_ACTOR_ISOLATION":
        'every module Package.swift builds overrides this to "none" in Project.swift, and '
        "nonisolated is what SwiftPM defaults to — so the two agree by coincidence, not by "
        "construction",
}

# Deliberately NOT in the dict above. It is an Xcode umbrella that turns on a set of upcoming
# concurrency features, and Package.swift enables none of them — so calling it "equivalent today"
# would file a real divergence under the heading of things that are only spelled differently, which
# is the failure this whole check exists to stop. It has no one-to-one SwiftPM spelling, so it is
# reported as unmapped rather than as a missing feature flag.
UMBRELLA_WITHOUT_SWIFTPM_SPELLING = {
    "SWIFT_APPROACHABLE_CONCURRENCY":
        "an Xcode umbrella over several upcoming concurrency features; Package.swift enables none "
        "of them, so the Linux gate is genuinely looser here",
}


def check_swift_settings(project_block, package):
    """The warning half. Reports; never fails. See the module docstring for why."""
    xcode = dict(re.findall(r'"(SWIFT_[A-Z_0-9]+)"\s*:\s*"([^"]*)"', project_block))
    looser, unmapped, notes = [], [], []
    for name, value in sorted(xcode.items()):
        if name.startswith("SWIFT_UPCOMING_FEATURE_"):
            # Xcode names an upcoming feature in UPPER_SNAKE, SwiftPM in UpperCamel. Deriving it
            # means a feature added to Project.swift is picked up with no edit here.
            feature = "".join(w.capitalize()
                              for w in name[len("SWIFT_UPCOMING_FEATURE_"):].split("_"))
            token = 'enableUpcomingFeature("%s")' % feature
            if token not in package:
                looser.append("  %s = %s — Package.swift declares no .%s" % (name, value, token))
        elif name in UMBRELLA_WITHOUT_SWIFTPM_SPELLING:
            unmapped.append("  %s = %s — %s" % (name, value, UMBRELLA_WITHOUT_SWIFTPM_SPELLING[name]))
        elif name in EQUIVALENT_TODAY:
            notes.append("  %s = %s — %s" % (name, value, EQUIVALENT_TODAY[name]))
        else:
            unmapped.append("  %s = %s — this check has no SwiftPM mapping for it; add one"
                            % (name, value))
    for line in looser + unmapped + notes:
        print(line)
    if looser or unmapped:
        warn("Package.swift",
             "%d Swift setting(s) Project.swift applies that Package.swift does not, so this gate "
             "is looser than the compiler that ships the app. Reported, not enforced: turning them "
             "on here lights up every portable module at once, and closing those errors wants a "
             "toolchain to hand rather than a red pipeline to iterate against."
             % (len(looser) + len(unmapped)))
    else:
        print("  Every Swift setting Project.swift applies is declared in Package.swift too.")


def main():
    project = without_line_comments((ROOT / "Project.swift").read_text())
    package = without_line_comments((ROOT / "Package.swift").read_text())

    block = re.search(r"let sharedSettings.*?configurations:", project, re.S)
    if block is None:
        # Fatal, unlike the Swift-settings half below. A check that cannot find its input has not
        # found agreement, and reporting success there is how a manifest refactor silently turns
        # this file into a no-op that prints a reassuring line every run.
        error("Project.swift",
              "Could not find `sharedSettings`, so this check compared nothing. Point it at "
              "wherever the shared base settings moved to.")
        sys.exit(1)

    failures = check_deployment_target(block.group(0), package)
    check_swift_settings(block.group(0), package)

    for manifest, line in failures:
        error(manifest, line)
    if failures:
        sys.exit("%d manifest disagreement(s) that a build cannot catch." % len(failures))


if __name__ == "__main__":
    main()

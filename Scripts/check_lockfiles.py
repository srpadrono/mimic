#!/usr/bin/env python3
"""Checks that Package.resolved and Tuist/Package.resolved pin the same versions.

The two manifests declare the same dependency ranges from the same directories, and then resolve
them into two separate lockfiles. That is a drift generator: 21 packages had already diverged,
including Vapor, NIO and GRDB — so the Linux job's socket-binding suites were passing against
versions the shipped .pkg does not contain. Nothing detected it, because the claim that the
manifests "cannot drift" was written in prose rather than checked.

This compares the *union*, not the intersection. The first version iterated
`root.keys() & tuist.keys()`, which meant a package present in one lockfile and absent from the
other was simply not looked at — precisely the shape a dropped or newly one-sided dependency takes,
and the one case where "the versions agree" is the wrong question. The two legitimately one-sided
packages are named below instead: Tuist builds DesignSystem, which links CodeEditorView, which pulls
Rearrange, and Package.swift declares no SwiftUI target for either to attach to. Naming them keeps
today green while a *new* one-sided package fails, and the allowlist is itself checked for
staleness, because a list that has stopped describing the tree has stopped checking it.

It lives in a file rather than inside the two runners for one reason: it used to be pasted into both
`Scripts/ci.sh` and `.github/workflows/ci.yml`, under a comment in ci.sh promising the two copies
were "character-for-character" identical "so a diff between the two files shows drift at a glance".
Diffing them after dedent showed this program matched and the compiler-settings one beside it did
not — the copies had drifted while the comment policing them said they could not. A shared file
cannot drift from itself.

Runs before anything is compiled, so: stdlib only, no arguments, nonzero exit on failure. Paths are
resolved from this file's location rather than the working directory, so it answers the same from
anywhere.
"""

import json
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent

TUIST_ONLY, ROOT_ONLY = {"codeeditorview", "rearrange"}, set()


def pins(path):
    return {p["identity"]: p["state"].get("version")
            for p in json.loads((ROOT / path).read_text())["pins"]}


def main():
    root, tuist = pins("Package.resolved"), pins("Tuist/Package.resolved")
    problems = [f"{k}: Package.resolved={root[k]} Tuist/Package.resolved={tuist[k]}"
                for k in sorted(root.keys() & tuist.keys()) if root[k] != tuist[k]]
    problems += [f"{k}: in Package.resolved ({root[k]}) and missing from Tuist/Package.resolved"
                 for k in sorted(root.keys() - tuist.keys() - ROOT_ONLY)]
    problems += [f"{k}: in Tuist/Package.resolved ({tuist[k]}) and missing from Package.resolved"
                 for k in sorted(tuist.keys() - root.keys() - ROOT_ONLY - TUIST_ONLY)]
    problems += [f"{k}: allowlisted as one-sided but is no longer — drop it from the allowlist"
                 for k in sorted((TUIST_ONLY - (tuist.keys() - root.keys()))
                                 | (ROOT_ONLY - (root.keys() - tuist.keys())))]
    for line in problems:
        print(line)
    if problems:
        sys.exit(f"{len(problems)} lockfile problem(s) — re-resolve both lockfiles to one set, "
                 "or update the one-sided allowlist in this check")
    print(f"{len(root.keys() & tuist.keys())} shared packages agree; "
          f"{len(TUIST_ONLY | ROOT_ONLY)} allowlisted as one-sided")


if __name__ == "__main__":
    main()

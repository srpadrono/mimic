#!/usr/bin/env python3
"""Recounts the test suites and checks README.md still states the right numbers.

README.md's Tests badge and its Testing table are hand-maintained, and the README says so — along
with the fact that they have twice claimed a figure the tree did not support: 469 / 34 / 181 against
an actual 487 / 49 / 173, and then 173 for the app row while a new parity suite was landing 13 more
in the same afternoon. Its advice is "recount before you change them", followed by the two shell
one-liners to do it with. This is those one-liners with the comparison written down, so that
recounting is something that happens whether or not somebody remembers to.

It counts what the README says it counts: `@Test` declarations under `Tests/` and `func test…`
methods under `MimicUITests/`. A parameterized case runs many times and is one declaration — the
same convention the README states, and the reason this cannot be checked against a test *run*.

Three kinds of disagreement fail:

  - a stated number that no longer matches the tree;
  - a claim the README has stopped making at all, which would leave this check silently agreeing
    with nothing (the failure mode that lets a doc rot while its checker stays green);
  - a suite folder that exists on disk but appears in none of the README's groups, which is what a
    newly added suite looks like before anybody has written it into the table.

It never edits README.md. It prints the true numbers, in the shape the README states them, so
whoever owns that file can paste them in.

Stdlib only, no arguments. Paths resolve from this file's location, so it answers the same from
anywhere.
"""

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent

# How the README groups the suites. The names are the folder names under Tests/; the check asserts
# below that these three groups between them account for every folder that exists.
PORTABLE = ["DomainTests", "SpecImportTests", "MockServerEngineTests",
            "PersistenceTests", "MimicCLICoreTests", "ControlPlaneTests"]
DESIGN_SYSTEM = ["DesignSystemTests"]
APP = ["WorkspaceFeatureTests", "MimicTests", "ImportFeatureTests",
       "ProjectFeatureTests", "EndpointFeatureTests", "JourneyFeatureTests"]

# `@Test` at the start of a line (after indentation) is a Swift Testing declaration; `func testX(`
# is an XCTest one. Anchoring to the line start is what keeps a mention inside prose or a doc
# comment from counting — verified against this tree, where every `@Test` occurrence under Tests/ is
# a declaration and none appears mid-line or in a comment. The count itself is deliberately not
# written here: it is what this script computes, and a number in a comment beside it would be one
# more hand-maintained mirror to go stale.
SWIFT_TESTING = re.compile(r"^\s*@Test\b", re.M)
XCTEST = re.compile(r"^\s*(?:@MainActor\s+)?func test[A-Za-z0-9_]*\s*\(", re.M)


def count(directory, pattern):
    total = 0
    for file in sorted((ROOT / directory).rglob("*.swift")):
        total += len(pattern.findall(file.read_text()))
    return total


def suite_counts():
    return {d.name: count(f"Tests/{d.name}", SWIFT_TESTING)
            for d in sorted((ROOT / "Tests").iterdir()) if d.is_dir()}


def claims(readme, counts, ui, portable, design, app, total):
    """Every number README.md states, paired with what the tree says it should be.

    Each entry is (what it is, regex with one capturing group, expected). A regex that matches
    nothing is reported as a lost claim rather than passed over, because a README that has stopped
    saying something is exactly as stale as one that says the wrong thing — and much harder to
    notice from a green check.
    """
    stated = [
        ("Tests badge", r"tests-(\d+)%20passing", total),
        ("headline total", r"(\d+) tests, counted as", total),
        ("table: portable row", r"import, CLI \| (\d+) \|", portable),
        ("table: design system row", r"Design system \| (\d+) \|", design),
        ("table: app row", r"App and coordination \| (\d+) \|", app),
        ("table: UI row", r"macOS UI \(XCUITest\) \| (\d+) \|", ui),
        ("prose: portable break down", r"The portable (\d+) break down as", portable),
        ("prose: app folders", r"The app's (\d+) are the", app),
        ("shell block: swift test", r"swift test\s+# the portable (\d+)", portable),
    ]
    # The two per-suite breakdowns. Written as "Domain 166, SpecImport 105, …" — module names, no
    # `Tests` suffix — and "`WorkspaceFeatureTests` 88, …" — folder names in backticks. Both are
    # parsed as name/number pairs out of the sentence that introduces them, so the check does not
    # depend on their order.
    for what, sentence_pattern, suffix in [
        ("portable breakdown", r"break down as (.+?)\.\s", "Tests"),
        # Deliberately not anchored on how many folders the sentence names. Writing "five" here is
        # the same hand-maintained mirror this script exists to remove: adding a suite made the
        # README say "six" and this pattern match nothing, which reports as a lost claim rather than
        # as the passing check it should be.
        ("app breakdown", r"The app's \d+ are the \w+ folders `MimicTests` builds —(.+?)—", ""),
    ]:
        sentence = re.search(sentence_pattern, readme, re.S)
        if sentence is None:
            yield (what, None, None, "README no longer contains this sentence")
            continue
        for name, number in re.findall(r"`?([A-Za-z]+)`? (\d+)", sentence.group(1)):
            folder = name + suffix
            if folder not in counts:
                yield (f"{what}: {name}", int(number), None,
                       f"names {folder}, which is not a folder under Tests/")
                continue
            yield (f"{what}: {name}", int(number), counts[folder], None)

    for what, pattern, expected in stated:
        found = re.search(pattern, readme)
        if found is None:
            yield (what, None, expected, "README no longer states this")
        else:
            yield (what, int(found.group(1)), expected, None)


def main():
    counts = suite_counts()
    ui = count("MimicUITests", XCTEST)
    portable = sum(counts[name] for name in PORTABLE)
    design = sum(counts[name] for name in DESIGN_SYSTEM)
    app = sum(counts[name] for name in APP)
    total = sum(counts.values()) + ui

    print("Counted in the tree:")
    for name in sorted(counts):
        print(f"  Tests/{name:<24} {counts[name]:>4}")
    print(f"  MimicUITests{'':<20} {ui:>4}  (func test)")
    print(f"  portable {portable} · design system {design} · app {app} · UI {ui} · total {total}")

    problems = []

    grouped = set(PORTABLE) | set(DESIGN_SYSTEM) | set(APP)
    for name in sorted(set(counts) - grouped):
        problems.append(f"Tests/{name} ({counts[name]} tests) is in none of the README's groups — "
                        "add it to the table and to the group lists in this file")
    for name in sorted(grouped - set(counts)):
        problems.append(f"Tests/{name} is in this file's group lists and no longer exists on disk")

    for what, stated, expected, note in claims(
        (ROOT / "README.md").read_text(), counts, ui, portable, design, app, total
    ):
        if note is not None:
            problems.append(f"{what}: {note}")
        elif stated != expected:
            problems.append(f"{what}: README says {stated}, the tree says {expected}")

    if problems:
        print("\nREADME.md disagrees with the tree:")
        for line in problems:
            print(f"  {line}")
        sys.exit(f"\n{len(problems)} stale count(s). Update README.md to the numbers above — "
                 "and only after checking they are the ones you meant to change.")

    print("\nREADME.md agrees with the tree on every count it states.")


if __name__ == "__main__":
    main()

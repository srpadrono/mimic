#!/usr/bin/env python3
"""Fails when a UI test method is not run by exactly one CI shard.

`.github/workflows/ci.yml` shards the XCUITest suite across independent macOS runners. Each shard
passes class or method `-only-testing:` selectors. The suites share one store, one defaults domain,
and one window server, so parallel workers on a single machine cannot provide this isolation.

Nothing below hard-codes the shard count. The shard list, bundle count, and per-shard totals are
derived from the workflow text.

Sharding introduces a failure mode the single job did not have: **a new UI test method that no shard
names never runs, while every shard stays green.** `xcodebuild` cannot notice, because each shard
asked for only the methods it was given. The checker compares those selections with the source tree.

This repository has met that shape before. `Project.swift` carried a `buildableFolders` line naming
`Tests/JourneyFeatureTests` with no directory behind it, which Tuist tolerated silently while the
manifest read as though the journey UI had tests; `Scripts/check_doc_counts.py` exists partly to fail
on a suite folder that no manifest declares, "which on a green pipeline is indistinguishable from one
that passed". This is the same sentence with `-only-testing:` in place of `buildableFolders`.

So the shard list is checked against the tree rather than trusted:

  - a method declared in `MimicUITests/` that appears in **no** shard fails;
  - a method selected by **two** shards fails, including a class selector overlapping a method one;
  - a shard naming a class or method that **does not exist** fails — `xcodebuild` can otherwise
    report "no tests to run" and exit 0;
  - and `EXPECTED_COVERAGE_BUNDLES` in the same workflow disagreeing with the shard count fails,
    which is the same shape one level up. The `coverage` job merges one result bundle per test-running
    job — the unit suites plus every shard — and refuses to publish if fewer arrive than it expects.
    It cannot count the shards for itself: a job cannot read another job's `matrix`, so the total is
    written down as a literal. Adding a shard without increasing it could publish incomplete coverage;
    leaving it too high refuses coverage forever. Both are quiet; this makes them loud.

It reads the workflow and suite sources as text. Nothing here imports PyYAML: the Linux CI job
installs `python3-minimal` and has no third-party packages.

`--self-test` drives the verdicts over fixtures written in this file — a workflow and a suite
tree invented here, never read off disk and never produced by the functions under test. That is the
rule AGENTS.md states as one question: if I revert the mechanism this test is for, does this test go
red? A fixture derived from the parsers would move with them and the answer would be no.
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
WORKFLOW = ROOT / ".github" / "workflows" / "ci.yml"
UI_TESTS = ROOT / "MimicUITests"

# The target name is part of the flag, and part of what makes this checkable: `-only-testing:` takes
# `<target>/<class>[/<method>]` and this repository has exactly one UI target.
TARGET = "MimicUITests"

ONLY_TESTING = re.compile(
    r"-only-testing:" + TARGET
    + r"/(?P<class>[A-Za-z_][A-Za-z0-9_]*)(?:/(?P<method>test[A-Za-z0-9_]+))?(?=\s|$)"
)

# The literal the `coverage` job compares its downloaded bundle count against. Matched as an `env:`
# entry rather than parsed as YAML, for the reason the module header gives: nothing here imports
# PyYAML.
EXPECTED_BUNDLES = re.compile(r"^\s*EXPECTED_COVERAGE_BUNDLES:\s*(\d+)\s*$", re.MULTILINE)

# A shard is a `- id: N` entry, and its flags are the `-only-testing:` lines before the next one.
SHARD_SPLIT = r"^\s*- id:\s*"

# A class declaration at the start of a line, with a superclass. Page objects in this target are
# `struct`s and are correctly invisible to this; a `class` with no superclass is not an XCTestCase
# either. The `func test…` count below is the real filter — `MimicUITestCase` is a `class` with a
# superclass and zero tests, and XCTest runs nothing in it.
CLASS_DECL = re.compile(r"^(?:final\s+|public\s+|open\s+)*class\s+([A-Za-z_][A-Za-z0-9_]*)\s*:")

# Indented, because a top-level `func test…` is not a test method. The same convention
# `Scripts/check_doc_counts.py` uses the same declaration convention for its live count.
TEST_FUNC = re.compile(
    r"^\s+(?:@\w+\s+)*(?:final\s+|public\s+|private\s+|internal\s+)*func\s+"
    r"(test[A-Za-z0-9_]+)\s*\("
)


def shard_selectors(workflow_text):
    """Every `(class, method or None)` selector, in order, duplicates kept.

    Order and duplicates both matter: the caller reports a class named twice, and it can only do
    that if this does not deduplicate on the way past.
    """
    return [(match.group("class"), match.group("method"))
            for match in ONLY_TESTING.finditer(workflow_text)]


def suite_methods(sources):
    """`{class name: [test methods]}` for every class declaring at least one test.

    `sources` is an iterable of `(filename, text)` so the caller decides whether that comes from
    disk or from a fixture. A file may hold more than one class; each `func test…` is attributed to
    the most recent declaration above it.
    """
    methods = {}
    for _name, text in sources:
        current = None
        for line in text.splitlines():
            declared = CLASS_DECL.match(line)
            if declared:
                current = declared.group(1)
                methods.setdefault(current, [])
                continue
            test = TEST_FUNC.match(line)
            if current and test:
                methods[current].append(test.group(1))
    return {name: names for name, names in methods.items() if names}


def suite_classes(sources):
    """`{class name: test count}` for reporting and the self-test's readable assertions."""
    return {name: len(names) for name, names in suite_methods(sources).items()}


def shard_blocks(workflow_text):
    """`[(id, [selectors])]` for every matrix leg that selects at least one test.

    A leg naming none is not a shard — it is a `- id:` in some other list, or a leg mid-edit — and
    counting it would make the bundle-count check below disagree with what the `coverage` job will
    actually be handed.
    """
    blocks = re.split(SHARD_SPLIT, workflow_text, flags=re.MULTILINE)[1:]
    found = []
    for block in blocks:
        selectors = shard_selectors(block)
        if selectors:
            found.append((block.split("\n", 1)[0].strip(), selectors))
    return found


def check_bundle_count(workflow_text):
    """`EXPECTED_COVERAGE_BUNDLES` against the shard count. One string, or none."""
    shards = len(shard_blocks(workflow_text))
    declared = EXPECTED_BUNDLES.search(workflow_text)

    if declared is None:
        return [
            "no `EXPECTED_COVERAGE_BUNDLES:` in .github/workflows/ci.yml. The `coverage` job needs "
            "it to know how many result bundles a complete merge has — one from the unit suites and "
            f"one from each of the {shards} shards, so {shards + 1}. If the coverage job is gone, "
            "delete this check with it rather than leaving a checker that compares nothing."
        ]

    expected = shards + 1
    if int(declared.group(1)) != expected:
        return [
            f"EXPECTED_COVERAGE_BUNDLES is {declared.group(1)} in .github/workflows/ci.yml and the "
            f"`macos-ui` matrix has {shards} shard(s), so a complete merge has {expected} bundles — "
            f"one from the unit suites and one per shard. Too high and the `coverage` job refuses "
            f"to publish on every run; too low and it merges fewer shards than exist while "
            f"believing it has them all, publishing a figure lower than the truth with nothing to "
            f"say a shard is missing."
        ]

    return []


def check(workflow_text, sources):
    """Returns `(problems, sharded, tests)` — a list of strings, the shard list, the counts."""
    sharded = shard_selectors(workflow_text)
    methods = suite_methods(sources)
    tests = {name: len(names) for name, names in methods.items()}
    problems = list(check_bundle_count(workflow_text))

    selected = {}
    for name, method in sharded:
        if name not in methods:
            problems.append(
                f"{TARGET}/{name} is named by a shard but declares no tests — a renamed or deleted "
                "class. xcodebuild can report 'no tests to run' and exit 0."
            )
            continue
        if method is not None and method not in methods[name]:
            problems.append(
                f"{TARGET}/{name}/{method} is named by a shard but declares no test method."
            )
            continue
        for selected_method in ([method] if method else methods[name]):
            key = (name, selected_method)
            selected[key] = selected.get(key, 0) + 1

    for name, names in sorted(methods.items()):
        missing = [method for method in names if selected.get((name, method), 0) == 0]
        doubled = [method for method in names if selected.get((name, method), 0) > 1]
        if missing:
            problems.append(
                f"{TARGET}/{name} has {len(missing)} test method(s) no shard runs: "
                + ", ".join(missing)
            )
        if doubled:
            problems.append(
                f"{TARGET}/{name} has {len(doubled)} test method(s) selected more than once: "
                + ", ".join(doubled)
            )

    return problems, sharded, tests


def report_balance(workflow_text, tests):
    """Prints the per-shard totals. Informational — an imbalance is never a failure.

    Test count is a proxy for time and the workflow says so; a spread this prints is a prompt to go
    and look at the real per-test durations in a shard's result bundle, not a verdict on anything.
    """
    totals = [
        (shard_id, sum(tests.get(name, 0) if method is None else 1
                       for name, method in selectors), selectors)
        for shard_id, selectors in shard_blocks(workflow_text)
    ]
    if not totals:
        return

    print(f"UI shards ({sum(n for _i, n, _c in totals)} tests across {len(totals)}):")
    for shard_id, total, selectors in totals:
        print(f"  shard {shard_id}: {total:3d} tests from {len(selectors)} selector(s)")
    heaviest = max(n for _i, n, _c in totals)
    lightest = min(n for _i, n, _c in totals)
    if lightest and heaviest > lightest * 1.5:
        print(
            f"  note: the largest shard selects {heaviest} tests against the smallest's "
            f"{lightest}. Test count is not elapsed time; compare measured durations before "
            "changing the balance."
        )


# --- self-test ---------------------------------------------------------------------------------
#
# Fixtures written out here as literals, never read from the repository and never produced by the
# functions above. A checker whose self-test asks the parsers what the right answer is certifies
# whatever they currently do, including doing nothing.

GOOD_WORKFLOW = """
      matrix:
        include:
          - id: 1
            only: >-
              -only-testing:MimicUITests/AlphaUITests
              -only-testing:MimicUITests/BetaUITests/testOne
          - id: 2
            only: >-
              -only-testing:MimicUITests/BetaUITests/testTwo
              -only-testing:MimicUITests/GammaUITests

  coverage:
    env:
      EXPECTED_COVERAGE_BUNDLES: 3
"""

GOOD_SOURCES = [
    ("Alpha.swift", "final class AlphaUITests: MimicUITestCase {\n    func testOne() {}\n"),
    (
        "Beta.swift",
        "final class BetaUITests: XCTestCase {\n    func testOne() {}\n    func testTwo() {}\n",
    ),
    ("Gamma.swift", "final class GammaUITests: XCTestCase {\n    func testOne() {}\n"),
    # A base class with no tests, and a page object. Neither is runnable, and a checker that
    # demanded a shard for either would be red on a tree that is correct.
    ("Base.swift", "class MimicUITestCase: XCTestCase {\n    func setUpWithError() throws {}\n"),
    ("Pages.swift", "struct WelcomePage {\n    func testable() {}\n"),
]


def self_test():
    failures = []

    def expect(label, condition, detail=""):
        if condition:
            print(f"  ok   {label}")
        else:
            print(f"  FAIL {label} {detail}")
            failures.append(label)

    print("check_ui_shards.py --self-test")

    problems, sharded, tests = check(GOOD_WORKFLOW, GOOD_SOURCES)
    expect("a complete, non-overlapping split passes", problems == [], problems)
    expect(
        "only classes that declare tests are counted",
        tests == {"AlphaUITests": 1, "BetaUITests": 2, "GammaUITests": 1},
        tests,
    )
    expect("every class and method flag is found", len(sharded) == 4, sharded)

    # A class split by method must still run every method exactly once.
    partial = GOOD_WORKFLOW.replace("              -only-testing:MimicUITests/BetaUITests/testTwo\n", "")
    problems, _s, _t = check(partial, GOOD_SOURCES)
    expect(
        "an omitted method in a split class fails",
        len(problems) == 1 and "BetaUITests" in problems[0] and "testTwo" in problems[0],
        problems,
    )

    unknown_method = GOOD_WORKFLOW.replace("BetaUITests/testTwo", "BetaUITests/testRenamed")
    problems, _s, _t = check(unknown_method, GOOD_SOURCES)
    expect(
        "a shard naming a nonexistent method fails",
        len(problems) == 2 and "testRenamed" in problems[0] and "testTwo" in problems[1],
        problems,
    )

    # A class on disk that no shard names — the failure this file exists for.
    unsharded = GOOD_SOURCES + [
        ("Delta.swift", "final class DeltaUITests: XCTestCase {\n    func testOne() {}\n")
    ]
    problems, _s, _t = check(GOOD_WORKFLOW, unsharded)
    expect(
        "a class no shard runs fails",
        len(problems) == 1 and "DeltaUITests" in problems[0] and "no shard" in problems[0],
        problems,
    )

    # The same class selected twice.
    doubled = GOOD_WORKFLOW + "              -only-testing:MimicUITests/AlphaUITests\n"
    problems, _s, _t = check(doubled, GOOD_SOURCES)
    expect(
        "a class named twice fails",
        len(problems) == 1 and "selected more than once" in problems[0],
        problems,
    )

    overlap = GOOD_WORKFLOW.replace(
        "              -only-testing:MimicUITests/BetaUITests/testTwo\n",
        "              -only-testing:MimicUITests/BetaUITests\n"
        "              -only-testing:MimicUITests/BetaUITests/testTwo\n",
    )
    problems, _s, _t = check(overlap, GOOD_SOURCES)
    expect(
        "a class selector overlapping a method selector fails",
        len(problems) == 1 and "BetaUITests" in problems[0]
        and "selected more than once" in problems[0],
        problems,
    )

    # A shard naming a class that is not there — what a rename leaves behind.
    renamed = [s for s in GOOD_SOURCES if s[0] != "Gamma.swift"]
    problems, _s, _t = check(GOOD_WORKFLOW, renamed)
    expect(
        "a shard naming a class that does not exist fails",
        len(problems) == 1 and "GammaUITests" in problems[0] and "declares no tests" in problems[0],
        problems,
    )

    # A workflow that has stopped naming any class at all. Every class is then unsharded, which is
    # the loud version of the quiet failure — worth pinning, because a checker that reported "all
    # clear" against an empty flag list would be agreeing with nothing.
    problems, _s, _t = check(
        "matrix:\n  include: []\nEXPECTED_COVERAGE_BUNDLES: 1\n", GOOD_SOURCES
    )
    expect("an empty shard list fails for every class", len(problems) == 3, problems)

    # The bundle-count check, driven on its own so a failure names it rather than showing up as a
    # count that moved. Two shards in the fixture, so a complete merge is three bundles.
    expect(
        "a bundle count matching the shards passes",
        check_bundle_count(GOOD_WORKFLOW) == [],
        check_bundle_count(GOOD_WORKFLOW),
    )
    too_low = GOOD_WORKFLOW.replace("EXPECTED_COVERAGE_BUNDLES: 3", "EXPECTED_COVERAGE_BUNDLES: 2")
    problems = check_bundle_count(too_low)
    expect(
        "a bundle count below the shard count fails",
        len(problems) == 1 and "lower than the truth" in problems[0],
        problems,
    )
    too_high = GOOD_WORKFLOW.replace("EXPECTED_COVERAGE_BUNDLES: 3", "EXPECTED_COVERAGE_BUNDLES: 9")
    problems = check_bundle_count(too_high)
    expect(
        "a bundle count above the shard count fails",
        len(problems) == 1 and "refuses to publish" in problems[0],
        problems,
    )
    missing = GOOD_WORKFLOW.replace("      EXPECTED_COVERAGE_BUNDLES: 3\n", "")
    problems = check_bundle_count(missing)
    expect(
        "a workflow with no bundle count at all fails",
        len(problems) == 1 and "no `EXPECTED_COVERAGE_BUNDLES:`" in problems[0],
        problems,
    )
    # A third shard added to the matrix and the literal left where it was — the drift this check
    # exists for, and the one that would otherwise publish a figure lower than the truth in silence.
    grown = GOOD_WORKFLOW.replace(
        "  coverage:",
        "          - id: 3\n            only: >-\n"
        "              -only-testing:MimicUITests/DeltaUITests\n\n  coverage:",
    )
    problems = check_bundle_count(grown)
    expect(
        "adding a shard without moving the bundle count fails",
        len(problems) == 1 and "3 shard(s)" in problems[0],
        problems,
    )

    if failures:
        print(f"\n{len(failures)} self-test failure(s). The checker is not trustworthy — fix it "
              f"before reading anything it says about the tree.")
        return 1
    print("  self-test passed\n")
    return 0


def main():
    if "--self-test" in sys.argv[1:]:
        return self_test()

    if not WORKFLOW.is_file():
        print(f"error: {WORKFLOW} does not exist", file=sys.stderr)
        return 1
    if not UI_TESTS.is_dir():
        print(f"error: {UI_TESTS} does not exist", file=sys.stderr)
        return 1

    workflow_text = WORKFLOW.read_text(encoding="utf-8")
    sources = [(p.name, p.read_text(encoding="utf-8")) for p in sorted(UI_TESTS.glob("*.swift"))]

    problems, sharded, tests = check(workflow_text, sources)

    # A tree with no UI tests, or a workflow with no shards, is not "clean" — it is a checker with
    # nothing to compare, which is the state every silently-passing gate in this repository was in.
    if not tests:
        print("error: no test classes found under MimicUITests/ — this checker compared nothing.",
              file=sys.stderr)
        return 1
    if not sharded:
        print("error: no -only-testing:MimicUITests/... flags in .github/workflows/ci.yml — either "
              "the UI suite stopped being sharded, in which case delete this checker, or the flag "
              "spelling changed and this compared nothing.", file=sys.stderr)
        return 1

    report_balance(workflow_text, tests)

    if problems:
        print()
        for problem in problems:
            print(f"error: {problem}", file=sys.stderr)
        return 1

    print(f"\nEvery one of the {sum(tests.values())} UI test methods is selected exactly once.")
    return 0


if __name__ == "__main__":
    sys.exit(main())

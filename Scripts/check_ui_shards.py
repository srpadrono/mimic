#!/usr/bin/env python3
"""Fails when a UI test class is not run by any CI shard, or is run by more than one.

`.github/workflows/ci.yml` shards the XCUITest suite across three macOS runners, and it does so by
naming test classes: each shard passes a list of `-only-testing:MimicUITests/<Class>` flags and runs
exactly those. That is the only workable split — the suites share one store, one defaults domain and
one window server, so `-parallel-testing-enabled` on a single machine is not available here, and the
workflow's header argues that at length.

Nothing below hard-codes that three. The shard list, the shard count and the per-shard totals are all
derived from the workflow text, which is what let the split go from four shards to three — after run
#89 measured the concurrent-macOS-job cap at four rather than the documented five — with this file's
logic untouched and only this paragraph and the one above it edited.

It also introduces a failure mode the single job did not have, and it is the worst kind: **a UI test
class that no shard names simply never runs, and every shard is green.** Add `SettingsUITests.swift`
tomorrow, write twenty tests in it, push, and three green checks report that the window is covered.
Nothing in `xcodebuild` can notice — a shard asked for the classes it was given and got them — and
nothing in the workflow can either, because the workflow is the thing that is wrong.

This repository has met that shape before. `Project.swift` carried a `buildableFolders` line naming
`Tests/JourneyFeatureTests` with no directory behind it, which Tuist tolerated silently while the
manifest read as though the journey UI had tests; `Scripts/check_doc_counts.py` exists partly to fail
on a suite folder that no manifest declares, "which on a green pipeline is indistinguishable from one
that passed". This is the same sentence with `-only-testing:` in place of `buildableFolders`.

So the shard list is checked against the tree rather than trusted:

  - a class with at least one `func test…` in `MimicUITests/` that appears in **no** shard fails;
  - a class named by **two** shards fails, because it would be run twice and the balance the shards
    were chosen for is wrong by that much;
  - a shard naming a class that **does not exist** fails, which is what a rename leaves behind —
    `xcodebuild` reports it as "no tests to run" and exits 0, so the shard goes green having run
    nothing.

It reads the workflow as text and the suites as text. Nothing here imports PyYAML: the Linux CI job
installs `python3-minimal` and has no third-party packages at all, which is a constraint every
checker in `Scripts/` states in its own header so that it stays true. Regex over
`-only-testing:MimicUITests/<Class>` is enough, because that string is the whole interface between
the workflow and the suite.

`--self-test` drives all four verdicts over fixtures written in this file — a workflow and a suite
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
# `<target>/<class>` and this repository has exactly one UI target.
TARGET = "MimicUITests"

ONLY_TESTING = re.compile(r"-only-testing:" + TARGET + r"/([A-Za-z_][A-Za-z0-9_]*)")

# A class declaration at the start of a line, with a superclass. Page objects in this target are
# `struct`s and are correctly invisible to this; a `class` with no superclass is not an XCTestCase
# either. The `func test…` count below is the real filter — `MimicUITestCase` is a `class` with a
# superclass and zero tests, and XCTest runs nothing in it.
CLASS_DECL = re.compile(r"^(?:final\s+|public\s+|open\s+)*class\s+([A-Za-z_][A-Za-z0-9_]*)\s*:")

# Indented, because a top-level `func test…` is not a test method. The same convention
# `Scripts/check_doc_counts.py` counts by, and the one README.md documents.
TEST_FUNC = re.compile(r"^\s+(?:@\w+\s+)*(?:final\s+|public\s+|private\s+|internal\s+)*func\s+test")


def shard_classes(workflow_text):
    """Every class named by an `-only-testing:` flag, in order, duplicates kept.

    Order and duplicates both matter: the caller reports a class named twice, and it can only do
    that if this does not deduplicate on the way past.
    """
    return ONLY_TESTING.findall(workflow_text)


def suite_classes(sources):
    """`{class name: test count}` for every class in `sources` that declares at least one test.

    `sources` is an iterable of `(filename, text)` so the caller decides whether that comes from
    disk or from a fixture. A file may hold more than one class; each `func test…` is attributed to
    the most recent declaration above it.
    """
    counts = {}
    for _name, text in sources:
        current = None
        for line in text.splitlines():
            declared = CLASS_DECL.match(line)
            if declared:
                current = declared.group(1)
                counts.setdefault(current, 0)
                continue
            if current and TEST_FUNC.match(line):
                counts[current] += 1
    return {name: n for name, n in counts.items() if n > 0}


def check(workflow_text, sources):
    """Returns `(problems, sharded, tests)` — a list of strings, the shard list, the counts."""
    sharded = shard_classes(workflow_text)
    tests = suite_classes(sources)
    problems = []

    seen = set()
    for name in sharded:
        if name in seen:
            problems.append(
                f"{TARGET}/{name} is named by more than one shard: it would run twice, and the "
                f"balance the shards were chosen for is wrong by that much."
            )
        seen.add(name)

    for name in sorted(seen - set(tests)):
        problems.append(
            f"{TARGET}/{name} is named by a shard in .github/workflows/ci.yml but declares no "
            f"tests — a renamed or deleted class. xcodebuild reports this as 'no tests to run' and "
            f"exits 0, so the shard goes green having run nothing."
        )

    for name in sorted(set(tests) - seen):
        problems.append(
            f"{TARGET}/{name} declares {tests[name]} test(s) and no shard in "
            f".github/workflows/ci.yml runs it. Add an -only-testing:{TARGET}/{name} line to the "
            f"lightest shard's `only:` list."
        )

    return problems, sharded, tests


def report_balance(workflow_text, tests):
    """Prints the per-shard totals. Informational — an imbalance is never a failure.

    Test count is a proxy for time and the workflow says so; a spread this prints is a prompt to go
    and look at the real per-test durations in a shard's result bundle, not a verdict on anything.
    """
    # A shard is a `- id: N` entry, and its flags are the `-only-testing:` lines before the next one.
    blocks = re.split(r"^\s*- id:\s*", workflow_text, flags=re.MULTILINE)[1:]
    if not blocks:
        return
    totals = []
    for block in blocks:
        shard_id = block.split("\n", 1)[0].strip()
        names = ONLY_TESTING.findall(block)
        if not names:
            continue
        totals.append((shard_id, sum(tests.get(n, 0) for n in names), names))
    if not totals:
        return

    print(f"UI shards ({sum(n for _i, n, _c in totals)} tests across {len(totals)}):")
    for shard_id, total, names in totals:
        print(f"  shard {shard_id}: {total:3d}  {', '.join(names)}")
    heaviest = max(n for _i, n, _c in totals)
    lightest = min(n for _i, n, _c in totals)
    if lightest and heaviest > lightest * 1.5:
        print(
            f"  note: the heaviest shard carries {heaviest} tests against the lightest's "
            f"{lightest}. Worth rebalancing the matrix — see the comment above `macos-ui` in "
            f".github/workflows/ci.yml for how to do it from measured durations."
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
              -only-testing:MimicUITests/BetaUITests
          - id: 2
            only: >-
              -only-testing:MimicUITests/GammaUITests
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
    expect("every shard flag is found", len(sharded) == 3, sharded)

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

    # The same class on two shards.
    doubled = GOOD_WORKFLOW + "              -only-testing:MimicUITests/AlphaUITests\n"
    problems, _s, _t = check(doubled, GOOD_SOURCES)
    expect(
        "a class named by two shards fails",
        len(problems) == 1 and "more than one shard" in problems[0],
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
    problems, _s, _t = check("matrix:\n  include: []\n", GOOD_SOURCES)
    expect("an empty shard list fails for every class", len(problems) == 3, problems)

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

    print(f"\nEvery one of the {len(tests)} UI test classes is run by exactly one shard.")
    return 0


if __name__ == "__main__":
    sys.exit(main())

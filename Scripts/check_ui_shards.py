#!/usr/bin/env python3
"""Fails when a UI test method is not run by exactly one UI shard.

The XCUITest suite is split into shards listed in `Scripts/test_selection.json`. CI's `plan` job
(`Scripts/select_tests.py`) picks the shards a change needs, and the nightly run takes all of them.
Each shard is `-only-testing:` selectors for one runner: the suites share one store, one defaults
domain and one window server, so they cannot run in parallel on one machine.

Sharding has a failure mode a single job does not: **a UI test method that no shard names never
runs, while every shard stays green.** `xcodebuild` cannot notice, because each shard asked only for
what it was given. So the shard list is checked against the tree rather than trusted:

  - a method declared in `MimicUITests/` that appears in **no** shard fails;
  - a method selected by **two** shards fails, including a class selector overlapping a method one;
  - a shard naming a class or method that **does not exist** fails — `xcodebuild` can otherwise
    report "no tests to run" and exit 0;
  - a shard with no selectors, or an id that is not a unique integer, fails: an empty leg would run
    every UI test, and a repeated id would overwrite another shard's result artifacts;
  - a shard without its measured `minutes` fails: the plan queues the longest shard first, and a
    missing figure would quietly sort it last. An `allowance` (seconds one test may run) must be a
    whole number of at least a minute, and `retry` must be true or false.

`--self-test` drives the verdicts over fixtures written in this file, never read off disk and never
produced by the functions under test. If the mechanism this test is for were reverted, it would go
red.
"""

import json
import re
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CONFIG = ROOT / "Scripts" / "test_selection.json"
UI_TESTS = ROOT / "MimicUITests"
TARGET = "MimicUITests"

SELECTOR = re.compile(r"(?P<class>[A-Za-z_][A-Za-z0-9_]*)(?:/(?P<method>test[A-Za-z0-9_]+))?\Z")

# A class declaration with a superclass. Page objects are `struct`s and are invisible to this; the
# `func test…` count is the real filter — `MimicUITestCase` is a class with zero tests.
CLASS_DECL = re.compile(r"^(?:final\s+|public\s+|open\s+)*class\s+([A-Za-z_][A-Za-z0-9_]*)\s*:")

# Indented, because a top-level `func test…` is not a test method.
TEST_FUNC = re.compile(
    r"^\s+(?:@\w+\s+)*(?:final\s+|public\s+|private\s+|internal\s+)*func\s+"
    r"(test[A-Za-z0-9_]+)\s*\("
)

# XCTest rounds an execution time allowance up to whole minutes and refuses less than one.
MIN_ALLOWANCE = 60


def suite_methods(sources):
    """`{class name: [test methods]}` for every class declaring at least one test."""
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


def read_sources(root):
    """Tuist's buildable folder includes nested Swift files, so the guard must include them."""
    return [(p.relative_to(root).as_posix(), p.read_text(encoding="utf-8"))
            for p in sorted(root.rglob("*.swift"))]


def check(shards, sources):
    """Returns `(problems, tests)` — a list of strings and `{class: test count}`."""
    methods = suite_methods(sources)
    tests = {name: len(names) for name, names in methods.items()}
    problems = []

    seen_ids = set()
    selected = {}
    for shard in shards:
        shard_id = shard.get("id")
        if not isinstance(shard_id, int) or isinstance(shard_id, bool) or shard_id in seen_ids:
            problems.append(f"UI shard id {shard_id!r} must be a unique integer for result artifacts.")
        seen_ids.add(shard_id)
        minutes = shard.get("minutes")
        if not isinstance(minutes, (int, float)) or isinstance(minutes, bool) or minutes <= 0:
            problems.append(f"UI shard {shard_id} needs its measured job time in minutes, a positive number.")
        allowance = shard.get("allowance", MIN_ALLOWANCE)
        if not isinstance(allowance, int) or isinstance(allowance, bool) or allowance < MIN_ALLOWANCE:
            problems.append(f"UI shard {shard_id} has allowance {allowance!r}; it must be whole seconds, "
                            f"at least {MIN_ALLOWANCE}.")
        if not isinstance(shard.get("retry", True), bool):
            problems.append(f"UI shard {shard_id} has retry {shard.get('retry')!r}; it must be true or "
                            "false.")
        selectors = shard.get("tests") or []
        if not selectors:
            problems.append(f"UI shard {shard_id} has no selectors; it would run every test.")
        for selector in selectors:
            match = SELECTOR.match(selector)
            if not match:
                problems.append(f"UI shard {shard_id} has an unsupported selector: {selector!r}.")
                continue
            name, method = match.group("class"), match.group("method")
            if name not in methods:
                problems.append(
                    f"{TARGET}/{name} is named by a shard but declares no tests — a renamed or "
                    "deleted class. xcodebuild can report 'no tests to run' and exit 0."
                )
                continue
            if method is not None and method not in methods[name]:
                problems.append(f"{TARGET}/{name}/{method} is named by a shard but declares no test method.")
                continue
            for selected_method in ([method] if method else methods[name]):
                key = (name, selected_method)
                selected[key] = selected.get(key, 0) + 1

    for name, names in sorted(methods.items()):
        missing = [method for method in names if selected.get((name, method), 0) == 0]
        doubled = [method for method in names if selected.get((name, method), 0) > 1]
        if missing:
            problems.append(f"{TARGET}/{name} has {len(missing)} test method(s) no shard runs: "
                            + ", ".join(missing))
        if doubled:
            problems.append(f"{TARGET}/{name} has {len(doubled)} test method(s) selected more than once: "
                            + ", ".join(doubled))

    return problems, tests


def report_balance(shards, tests):
    """Prints per-shard totals. Informational: the minutes are the last measurement, not a promise."""
    totals = []
    for shard in shards:
        count = 0
        for selector in shard.get("tests") or []:
            name, _, method = selector.partition("/")
            count += 1 if method else tests.get(name, 0)
        totals.append((shard.get("id"), shard.get("name", ""), count, shard.get("minutes")))
    if not totals:
        return
    print(f"UI shards ({sum(t[2] for t in totals)} tests across {len(totals)}):")
    for shard_id, name, total, minutes in totals:
        measured = f"{minutes:5.1f} min" if isinstance(minutes, (int, float)) else "    ? min"
        print(f"  shard {shard_id:>2} {name:32} {total:3d} tests {measured}")


# --- self-test ---------------------------------------------------------------------------------

GOOD_SHARDS = [
    {"id": 1, "name": "one", "minutes": 7.5, "tests": ["AlphaUITests", "BetaUITests/testOne"]},
    {"id": 2, "name": "two", "minutes": 4, "allowance": 600, "retry": False,
     "tests": ["BetaUITests/testTwo", "GammaUITests"]},
]

GOOD_SOURCES = [
    ("Alpha.swift", "final class AlphaUITests: MimicUITestCase {\n    func testOne() {}\n"),
    ("Beta.swift", "final class BetaUITests: XCTestCase {\n    func testOne() {}\n    func testTwo() {}\n"),
    ("Gamma.swift", "final class GammaUITests: XCTestCase {\n    func testOne() {}\n"),
    # A base class with no tests, and a page object. Neither is runnable.
    ("Base.swift", "class MimicUITestCase: XCTestCase {\n    func setUpWithError() throws {}\n"),
    ("Pages.swift", "struct WelcomePage {\n    func testable() {}\n"),
]


def with_tests(shard_id, tests):
    return [dict(shard, tests=tests) if shard["id"] == shard_id else shard for shard in GOOD_SHARDS]


def self_test():
    failures = []

    def expect(label, condition, detail=""):
        print(f"  {'ok  ' if condition else 'FAIL'} {label}" + ("" if condition else f" {detail}"))
        if not condition:
            failures.append(label)

    print("check_ui_shards.py --self-test")

    with tempfile.TemporaryDirectory(prefix="mimic-shard-fixture-") as directory:
        nested = Path(directory) / "Nested"
        nested.mkdir()
        (nested / "NestedUITests.swift").write_text(
            "final class NestedUITests: XCTestCase {\n    func testNested() {}\n}\n", encoding="utf-8")
        expect("nested UI suite sources are included",
               suite_methods(read_sources(Path(directory))) == {"NestedUITests": ["testNested"]})

    problems, tests = check(GOOD_SHARDS, GOOD_SOURCES)
    expect("a complete, non-overlapping split passes", problems == [], problems)
    expect("only classes that declare tests are counted",
           tests == {"AlphaUITests": 1, "BetaUITests": 2, "GammaUITests": 1}, tests)

    problems, _ = check(with_tests(2, ["GammaUITests"]), GOOD_SOURCES)
    expect("an omitted method in a split class fails",
           len(problems) == 1 and "BetaUITests" in problems[0] and "testTwo" in problems[0], problems)

    problems, _ = check(with_tests(2, ["BetaUITests/testRenamed", "GammaUITests"]), GOOD_SOURCES)
    expect("a shard naming a nonexistent method fails",
           len(problems) == 2 and "testRenamed" in problems[0] and "testTwo" in problems[1], problems)

    unsharded = GOOD_SOURCES + [("Delta.swift", "final class DeltaUITests: XCTestCase {\n    func testOne() {}\n")]
    problems, _ = check(GOOD_SHARDS, unsharded)
    expect("a class no shard runs fails",
           len(problems) == 1 and "DeltaUITests" in problems[0] and "no shard" in problems[0], problems)

    problems, _ = check(with_tests(1, ["AlphaUITests", "AlphaUITests", "BetaUITests/testOne"]), GOOD_SOURCES)
    expect("a class named twice fails", len(problems) == 1 and "more than once" in problems[0], problems)

    problems, _ = check(with_tests(2, ["BetaUITests", "GammaUITests"]), GOOD_SOURCES)
    expect("a class selector overlapping a method selector fails",
           len(problems) == 1 and "BetaUITests" in problems[0] and "more than once" in problems[0], problems)

    problems, _ = check(GOOD_SHARDS + [{"id": 3, "name": "empty", "minutes": 1, "tests": []}], GOOD_SOURCES)
    expect("an empty shard fails instead of running every UI test",
           len(problems) == 1 and "no selectors" in problems[0], problems)

    problems, _ = check([GOOD_SHARDS[0], dict(GOOD_SHARDS[1], id=1)], GOOD_SOURCES)
    expect("duplicate shard ids cannot overwrite result artifacts",
           len(problems) == 1 and "unique integer" in problems[0], problems)

    problems, _ = check(with_tests(2, ["BetaUITests/testTwo", "Gamma UITests"]), GOOD_SOURCES)
    expect("a malformed selector fails", any("unsupported selector" in p for p in problems), problems)

    renamed = [s for s in GOOD_SOURCES if s[0] != "Gamma.swift"]
    problems, _ = check(GOOD_SHARDS, renamed)
    expect("a shard naming a class that does not exist fails",
           len(problems) == 1 and "GammaUITests" in problems[0] and "declares no tests" in problems[0], problems)

    problems, _ = check([], GOOD_SOURCES)
    expect("an empty shard list fails for every class", len(problems) == 3, problems)

    unmeasured = [{k: v for k, v in GOOD_SHARDS[0].items() if k != "minutes"}, GOOD_SHARDS[1]]
    problems, _ = check(unmeasured, GOOD_SOURCES)
    expect("a shard without measured minutes fails",
           len(problems) == 1 and "minutes" in problems[0], problems)

    problems, _ = check([dict(GOOD_SHARDS[0], minutes=0), GOOD_SHARDS[1]], GOOD_SOURCES)
    expect("a shard measured at zero minutes fails",
           len(problems) == 1 and "minutes" in problems[0], problems)

    problems, _ = check([GOOD_SHARDS[0], dict(GOOD_SHARDS[1], allowance=30)], GOOD_SOURCES)
    expect("an allowance under a minute fails", len(problems) == 1 and "allowance" in problems[0], problems)

    problems, _ = check([GOOD_SHARDS[0], dict(GOOD_SHARDS[1], retry="no")], GOOD_SOURCES)
    expect("a retry that is not a boolean fails", len(problems) == 1 and "retry" in problems[0], problems)

    if failures:
        print(f"\n{len(failures)} self-test failure(s). The checker is not trustworthy — fix it "
              "before reading anything it says about the tree.")
        return 1
    print("  self-test passed\n")
    return 0


def main():
    if "--self-test" in sys.argv[1:]:
        return self_test()

    if not UI_TESTS.is_dir():
        print(f"error: {UI_TESTS} does not exist", file=sys.stderr)
        return 1

    shards = json.loads(CONFIG.read_text(encoding="utf-8"))["ui_shards"]
    problems, tests = check(shards, read_sources(UI_TESTS))
    report_balance(shards, tests)

    if problems:
        print("", file=sys.stderr)
        for problem in problems:
            print(f"error: {problem}", file=sys.stderr)
        print(f"\nShards are listed in {CONFIG.relative_to(ROOT)} under ui_shards.", file=sys.stderr)
        return 1

    print(f"Every UI test method ({sum(tests.values())}) runs in exactly one shard.")
    return 0


if __name__ == "__main__":
    sys.exit(main())

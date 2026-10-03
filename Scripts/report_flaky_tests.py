#!/usr/bin/env python3
"""Names every test that failed and then passed on CI's automatic retry, so a flake stays visible.

Pull requests and pushes run their tests with `-retry-tests-on-failure -test-iterations 2`: a test
that fails runs once more, and the job stays green when the second attempt passes. That turns a
transient failure into half a minute instead of an hour-long re-run of the whole workflow. On its
own it would also hide a test that has started failing one run in three, which is how a flake grows
until it fails twice in a row. So after each test step this script reads the result bundle and, for
every test that needed the retry:

  - prints a `::warning::` annotation, which GitHub shows on the run page and the pull request;
  - appends a table to `$GITHUB_STEP_SUMMARY`;
  - with `--list FILE`, writes one Markdown line per flake, which the UI suite verdict collects from
    every shard into one list.

The nightly run never retries, so a flaky test also fails there outright.

It reads `xcrun xcresulttool get test-results tests`, the same tree `print_test_failures.sh` walks.
A test is a `Test Case` node, or an `Arguments` node for one case of a parameterised Swift Testing
test, and each attempt at it is a `Repetition` child (possibly under a `Test Case Run`, `Device` or
configuration node). A test is flaky when one attempt failed and another passed. As a fallback for a
bundle that folds the attempts together, a test that passed while carrying a failure message counts
too; a test that failed every attempt is a failure, which `print_test_failures.sh` reports.

**It always exits 0** (except `--self-test`), for the reason `print_test_failures.sh` gives: a
diagnostic that can redden the run it reads is worse than none. The workflow also runs it with
`continue-on-error`.

Usage: report_flaky_tests.py [--label NAME] [--list FILE] RESULT_BUNDLE
       report_flaky_tests.py --self-test
"""

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path

TESTS = ("Test Case", "Arguments")
# Nodes that sit between a test and its attempts without being a test of their own.
WRAPPERS = ("Test Case Run", "Device", "Test Plan Configuration")


def attempts(node):
    """The `Repetition` nodes that are attempts at `node` itself, looking through wrapper nodes."""
    found = []
    for child in node.get("children", []):
        kind = child.get("nodeType")
        if kind == "Repetition":
            found.append(child)
        elif kind in WRAPPERS:
            found += attempts(child)
    return found


def failure_messages(node):
    """The failure messages recorded directly under `node` or its wrappers."""
    messages = []
    for child in node.get("children", []):
        kind = child.get("nodeType")
        if kind == "Failure Message":
            messages.append(child.get("name", ""))
        elif kind in WRAPPERS:
            messages += failure_messages(child)
    return messages


def flaky_tests(tree):
    """`[(test, attempts, first failure message)]` for every test with a failed and a passed attempt."""
    found = []
    seen = set()

    def walk(node, test):
        kind = node.get("nodeType")
        if kind in TESTS:
            # `nodeIdentifier` reads "Suite/testName()"; an argument is named after its parent test.
            if kind == "Test Case":
                test = node.get("nodeIdentifier") or node.get("name", "")
            else:
                test = f"{test} ({node.get('name', '')})"
            runs = attempts(node)
            results = [run.get("result") for run in runs]
            if "Failed" in results and "Passed" in results:
                first = next(run for run in runs if run.get("result") == "Failed")
                entry = (test, len(runs), (failure_messages(first) or [""])[0])
            elif not runs and node.get("result") == "Passed" and failure_messages(node):
                entry = (test, 0, failure_messages(node)[0])
            else:
                entry = None
            if entry and test not in seen:
                seen.add(test)
                found.append(entry)
        for child in node.get("children", []):
            if child.get("nodeType") != "Repetition":
                walk(child, test)

    for root in tree.get("testNodes", []):
        walk(root, "")
    return found


def escape_data(text):
    """A workflow command's message: `%`, CR and LF would otherwise end or corrupt it."""
    return text.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")


def escape_property(text):
    return escape_data(text).replace(":", "%3A").replace(",", "%2C")


def cell(text, limit=200):
    """One Markdown table cell: a single line, pipes escaped, long messages cut."""
    flat = " ".join(text.split()).replace("|", "\\|")
    return flat if len(flat) <= limit else flat[: limit - 1] + "…"


def report(flakes, label):
    """`(annotations, summary, list lines)` for the flakes found in one bundle."""
    where = f" ({label})" if label else ""
    annotations = []
    lines = []
    for test, runs, message in flakes:
        # Neutral about the order: a focus run repeating until failure finds the passes first.
        tries = f"failed on one of {runs} attempts and passed on another" if runs else "passed after a retry"
        annotations.append(
            f"::warning title={escape_property('Flaky test' + where)}::"
            + escape_data(f"{test} {tries}. First failure: {message or 'no message'}")
        )
        lines.append(f"- `{test}`{where}: {tries}. First failure: {cell(message) or 'no message'}")
    if not flakes:
        return annotations, f"No test needed a retry{where}.\n", lines
    summary = [f"### Flaky tests{where}", "",
               "Each failed on one attempt and passed on another, so the job stayed green.", "",
               "| Test | Attempts | First failure |", "| --- | --- | --- |"]
    summary += [f"| `{test}` | {runs or '?'} | {cell(message)} |" for test, runs, message in flakes]
    return annotations, "\n".join(summary) + "\n", lines


def read_tree(bundle):
    output = subprocess.run(
        ["xcrun", "xcresulttool", "get", "test-results", "tests", "--path", bundle],
        capture_output=True, text=True, check=True,
    ).stdout
    return json.loads(output)


# --- self-test ---------------------------------------------------------------------------------
#
# A test tree written here as a literal, in the shape `xcresulttool get test-results tests` prints.
# Reverting flaky_tests to "every failure" or "nothing" turns these red.

def node(kind, name, result=None, children=(), identifier=None):
    out = {"nodeType": kind, "name": name, "children": list(children)}
    if result:
        out["result"] = result
    if identifier:
        out["nodeIdentifier"] = identifier
    return out


FIXTURE = {"testNodes": [node("Test Plan", "Mimic", "Passed", [
    node("UI test bundle", "MimicUITests", "Passed", [
        node("Test Suite", "MenuUITests", "Passed", [
            node("Test Case", "testFlaky()", "Passed", identifier="MenuUITests/testFlaky()", children=[
                node("Repetition", "First Run", "Failed", [
                    node("Failure Message", "MenuUITests.swift:42: The menu should open\nopen ones: none"),
                ]),
                node("Repetition", "Retry 1", "Passed"),
            ]),
            node("Test Case", "testBroken()", "Failed", identifier="MenuUITests/testBroken()", children=[
                node("Repetition", "First Run", "Failed", [node("Failure Message", "still broken")]),
                node("Repetition", "Retry 1", "Failed", [node("Failure Message", "still broken")]),
            ]),
            node("Test Case", "testSteady()", "Passed", identifier="MenuUITests/testSteady()"),
            node("Test Case", "testThroughARun()", "Passed", identifier="MenuUITests/testThroughARun()", children=[
                node("Test Case Run", "macOS", "Passed", [
                    node("Repetition", "First Run", "Failed", [node("Failure Message", "timed out")]),
                    node("Repetition", "Retry 1", "Passed"),
                ]),
            ]),
        ]),
    ]),
    node("Unit test bundle", "DesignFidelityTests", "Passed", [
        node("Test Suite", "Gallery snapshots", "Passed", [
            node("Test Case", "everyEntry(appearance:)", "Passed", identifier="Gallery/everyEntry(appearance:)",
                 children=[
                     node("Arguments", "dark", "Passed", [
                         node("Repetition", "First Run", "Failed", [node("Failure Message", "0.43% changed")]),
                         node("Repetition", "Retry 1", "Passed"),
                     ]),
                     node("Arguments", "light", "Passed"),
                 ]),
            node("Test Case", "folded()", "Passed", identifier="Gallery/folded()", children=[
                node("Failure Message", "failed on the first attempt"),
            ]),
        ]),
    ]),
])]}


def self_test():
    failures = []

    def expect(label, condition, detail=""):
        print(f"  {'ok  ' if condition else 'FAIL'} {label}" + ("" if condition else f" {detail}"))
        if not condition:
            failures.append(label)

    print("report_flaky_tests.py --self-test")
    flakes = flaky_tests(FIXTURE)
    names = [test for test, _runs, _message in flakes]
    expect("a test that failed and then passed is flaky", "MenuUITests/testFlaky()" in names, names)
    expect("a test that failed every attempt is not flaky", "MenuUITests/testBroken()" not in names, names)
    expect("a test that passed first time is not flaky", "MenuUITests/testSteady()" not in names, names)
    expect("attempts are found through a test case run", "MenuUITests/testThroughARun()" in names, names)
    expect("one argument of a parameterised test is named with its argument",
           "Gallery/everyEntry(appearance:) (dark)" in names, names)
    expect("a passed test carrying a failure counts when attempts are folded together",
           "Gallery/folded()" in names, names)
    expect("exactly the flaky tests are reported", len(flakes) == 4, flakes)
    first = dict((test, (runs, message)) for test, runs, message in flakes)["MenuUITests/testFlaky()"]
    expect("the first failure's message and the attempt count are kept",
           first == (2, "MenuUITests.swift:42: The menu should open\nopen ones: none"), first)

    annotations, summary, lines = report(flakes, "shard 3")
    expect("every flake becomes one warning", len(annotations) == 4
           and all(a.startswith("::warning title=Flaky test (shard 3)::") for a in annotations), annotations)
    expect("a multi-line message cannot end the workflow command early",
           all("\n" not in a for a in annotations) and "%0Aopen ones" in annotations[0], annotations[0])
    expect("the summary is a table with one row per flake",
           summary.count("\n| `") == 4 and "| --- |" in summary, summary)
    expect("a list line stays on one line",
           all("\n" not in line for line in lines) and len(lines) == 4, lines)
    expect("a property cannot be split by its own commas or colons",
           escape_property("a, b: c") == "a%2C b%3A c", escape_property("a, b: c"))
    _, summary, lines = report([], "unit suites")
    expect("a clean bundle says so and lists nothing", "No test needed a retry" in summary and lines == [],
           summary)

    if failures:
        print(f"{len(failures)} self-test failure(s).")
        return 1
    print("All self-tests passed.")
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--label", default="", help="where the bundle came from, e.g. the shard name")
    parser.add_argument("--list", default="", help="write one Markdown line per flake here")
    parser.add_argument("bundle", nargs="?")
    args = parser.parse_args()

    if args.self_test:
        return self_test()
    if not args.bundle or not Path(args.bundle).exists():
        print(f"report_flaky_tests.py: no result bundle at {args.bundle!r}, so nothing to report.")
        return 0
    try:
        flakes = flaky_tests(read_tree(args.bundle))
    except (subprocess.CalledProcessError, OSError, ValueError) as error:
        print(f"report_flaky_tests.py: could not read {args.bundle}: {error}")
        return 0

    annotations, summary, lines = report(flakes, args.label)
    for annotation in annotations:
        print(annotation)
    print(summary, end="")
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a", encoding="utf-8") as handle:
            handle.write(summary)
    if args.list and lines:
        Path(args.list).parent.mkdir(parents=True, exist_ok=True)
        Path(args.list).write_text("\n".join(lines) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main())

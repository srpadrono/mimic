#!/usr/bin/env python3
"""Decides which tests a change runs, so a pull request runs only what the change can break.

CI's `plan` job runs this first. It reads the files a change touched and prints, as GitHub outputs:

  - `checks`: whether the macOS build, unit suites and CLI end-to-end job runs;
  - `unit`: `all`, `none`, or the `-only-testing:` flags for the unit test targets to run;
  - `ui`: whether any UI shard runs, and `ui_matrix`, the shards themselves;
  - `full`: whether this is a full run (every suite, every shard, the Release build);
  - `coverage`: whether this run publishes the merged coverage badges.

How a changed file is classified, first match wins (lists in `Scripts/test_selection.json`):

  1. `full_paths` (build settings, the workflow, this script): everything runs.
  2. `cli_paths`: the macOS build and CLI end-to-end checks run, no unit or UI tests.
  3. A file inside a Tuist target's buildable folder (read from `Project.swift`): the unit test
     targets that depend on that target, directly or not, and the UI classes `ui_classes_by_target`
     names for that target itself. A UI test file selects its own class; a
     shared UI support file selects every shard.
  4. `linux_only_paths`: nothing on macOS. The Linux job always runs.
  5. Anything else: everything runs. An unknown path is a reason to test more, never less.

Scheduled runs (the nightly full suite) and a manual run with `full` set run everything. A manual
run naming `only_testing` selectors runs just those UI tests, optionally repeated, on one runner.

`--check` fails when a module the app links has no entry in `ui_classes_by_target`, or an entry
names a UI class that does not exist, so a new module gets a decision instead of a silent gap.
`--self-test` runs the selection over a fixture manifest written in this file.
"""

import argparse
import json
import os
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CONFIG = ROOT / "Scripts" / "test_selection.json"
MANIFEST = ROOT / "Project.swift"
UI_TESTS = ROOT / "MimicUITests"
UI_TARGET = "MimicUITests"
APP_TARGET = "Mimic"

TARGET_DEF = re.compile(r"\.target\(\s*\n\s*name:\s*\"(\w+)\"")
PRODUCT = re.compile(r"product:\s*\.(\w+)")
FOLDERS = re.compile(r"buildableFolders:\s*\[(.*?)\]", re.DOTALL)
RESOURCE_FOLDER = re.compile(r"\.folderReference\(path:\s*\"([^\"]+)\"\)")
DEPENDENCY = re.compile(r"\.target\(name:\s*\"(\w+)\"\)")
CLASS_DECL = re.compile(r"^(?:final\s+|public\s+|open\s+)*class\s+([A-Za-z_][A-Za-z0-9_]*)\s*:")
TEST_FUNC = re.compile(r"^\s+(?:@\w+\s+)*(?:final\s+|public\s+|internal\s+)*func\s+(test\w+)\s*\(")


def parse_targets(manifest_text):
    """`{name: {"product", "folders", "deps"}}` for every `.target(` definition in the manifest."""
    text = "\n".join(line.split("//", 1)[0] for line in manifest_text.splitlines())
    starts = list(TARGET_DEF.finditer(text))
    targets = {}
    for index, match in enumerate(starts):
        end = starts[index + 1].start() if index + 1 < len(starts) else len(text)
        body = text[match.end():end]
        folders_match = FOLDERS.search(body)
        folders = re.findall(r"\"([^\"]+)\"", folders_match.group(1)) if folders_match else []
        folders += RESOURCE_FOLDER.findall(body)
        product = PRODUCT.search(body)
        targets[match.group(1)] = {
            "product": product.group(1) if product else "",
            "folders": folders,
            "deps": sorted(set(DEPENDENCY.findall(body)) - {match.group(1)}),
        }
    return targets


def glob_regex(pattern):
    """`**` spans directories, `*` stays inside one path segment."""
    out = ""
    i = 0
    while i < len(pattern):
        if pattern.startswith("**/", i):
            out += "(?:.*/)?"
            i += 3
        elif pattern.startswith("**", i):
            out += ".*"
            i += 2
        elif pattern[i] == "*":
            out += "[^/]*"
            i += 1
        else:
            out += re.escape(pattern[i])
            i += 1
    return re.compile(out + r"\Z")


def matches(path, patterns):
    return any(glob_regex(pattern).match(path) for pattern in patterns)


def owner(path, targets):
    """The target whose buildable folder holds `path`, preferring the deepest folder."""
    best = None
    for name, target in targets.items():
        for folder in target["folders"]:
            if path == folder or path.startswith(folder.rstrip("/") + "/"):
                if best is None or len(folder) > best[1]:
                    best = (name, len(folder))
    return best[0] if best else None


def dependents(names, targets):
    """`names` plus every target that depends on one of them, directly or transitively."""
    found = set(names)
    changed = True
    while changed:
        changed = False
        for name, target in targets.items():
            if name not in found and found.intersection(target["deps"]):
                found.add(name)
                changed = True
    return found


def dependencies(name, targets):
    found = set()
    pending = [name]
    while pending:
        for dep in targets.get(pending.pop(), {}).get("deps", []):
            if dep not in found:
                found.add(dep)
                pending.append(dep)
    return found


def ui_classes(sources):
    """`{class: [test methods]}` for every UI test class with at least one test."""
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
    return {name: tests for name, tests in methods.items() if tests}


def read_ui_sources(root=UI_TESTS):
    return [(p.name, p.read_text(encoding="utf-8")) for p in sorted(root.rglob("*.swift"))]


def full_plan(config, reason):
    return {
        "full": True, "checks": True, "unit": "all",
        "shards": [shard["id"] for shard in config["ui_shards"]],
        "reasons": [reason],
    }


def plan_for_changes(paths, config, targets, ui_sources):
    """The plan for a set of changed paths. Pure: everything it reads is passed in."""
    class_files = {}
    for filename, text in ui_sources:
        for line in text.splitlines():
            declared = CLASS_DECL.match(line)
            if declared:
                class_files.setdefault(filename, set()).add(declared.group(1))
    known_classes = ui_classes(ui_sources)

    changed_targets = set()
    ui_selected = set()
    ui_all = False
    cli = False
    reasons = []

    for path in paths:
        if matches(path, config["full_paths"]):
            return full_plan(config, f"{path} changes how everything is built or selected")
        if matches(path, config["cli_paths"]):
            cli = True
            reasons.append(f"{path}: CLI end-to-end")
            continue
        target = owner(path, targets)
        if target == UI_TARGET:
            names = class_files.get(Path(path).name, set()) & set(known_classes)
            if names:
                ui_selected |= names
                reasons.append(f"{path}: {', '.join(sorted(names))}")
            else:
                ui_all = True
                reasons.append(f"{path}: shared UI test support, every shard")
            continue
        if target:
            changed_targets.add(target)
            reasons.append(f"{path}: {target}")
            continue
        if matches(path, config["linux_only_paths"]):
            continue
        return full_plan(config, f"{path} belongs to no target and no known group")

    affected = dependents(changed_targets, targets)
    unit = sorted(name for name in affected if targets[name]["product"] == "unitTests")

    app_modules = dependencies(APP_TARGET, targets) | {APP_TARGET}
    by_target = config["ui_classes_by_target"]
    # UI classes follow the modules that changed, not everything that links them: the app links
    # every module, so walking dependents would select every shard for any change. A hub module
    # whose changes reach every screen says so with "all" in its own entry.
    for name in changed_targets & app_modules:
        entry = by_target.get(name, "all")
        if entry == "all":
            ui_all = True
        else:
            ui_selected |= set(entry)

    shards = config["ui_shards"]
    if ui_all:
        chosen = [shard["id"] for shard in shards]
    else:
        chosen = [
            shard["id"] for shard in shards
            if any(selector.split("/")[0] in ui_selected for selector in shard["tests"])
        ]
        if chosen and config["smoke_shard"] not in chosen:
            chosen.insert(0, config["smoke_shard"])

    return {
        "full": False,
        "checks": bool(unit) or cli,
        "unit": " ".join(f"-only-testing:{name}" for name in unit) if unit else "none",
        "shards": chosen,
        "reasons": reasons,
    }


def focus_plan(selectors, iterations):
    flags = " ".join(f"-only-testing:{s if s.startswith(UI_TARGET + '/') else UI_TARGET + '/' + s}"
                     for s in selectors.split())
    extra = f"-test-iterations {iterations} -run-tests-until-failure" if iterations > 1 else ""
    return {
        "full": False, "checks": False, "unit": "none", "shards": [], "reasons": ["manual UI focus run"],
        "matrix": [{"id": 99, "name": "focus", "only": flags, "extra": extra}],
    }


def matrix(plan, config):
    if "matrix" in plan:
        return plan["matrix"]
    by_id = {shard["id"]: shard for shard in config["ui_shards"]}
    return [
        {"id": shard_id, "name": by_id[shard_id]["name"], "extra": "",
         "only": " ".join(f"-only-testing:{UI_TARGET}/{t}" for t in by_id[shard_id]["tests"])}
        for shard_id in plan["shards"]
    ]


def changed_paths(base, head):
    diff = subprocess.run(
        ["git", "diff", "--name-only", f"{base}...{head}"],
        cwd=ROOT, capture_output=True, text=True, check=True,
    )
    return [line for line in diff.stdout.splitlines() if line.strip()]


def check(config, targets, ui_sources):
    problems = []
    known = ui_classes(ui_sources)
    app_modules = dependencies(APP_TARGET, targets) | {APP_TARGET}
    for name in sorted(app_modules):
        if name not in config["ui_classes_by_target"]:
            problems.append(
                f"{name} is linked by the app but has no entry in ui_classes_by_target in "
                "Scripts/test_selection.json. Name the UI test classes its changes should run, or \"all\"."
            )
    for name, entry in sorted(config["ui_classes_by_target"].items()):
        if name not in targets:
            problems.append(f"ui_classes_by_target names {name}, which Project.swift does not define.")
        if entry != "all":
            for cls in entry:
                if cls not in known:
                    problems.append(f"ui_classes_by_target[{name}] names {cls}, which declares no UI tests.")
    if config["smoke_shard"] not in {shard["id"] for shard in config["ui_shards"]}:
        problems.append(f"smoke_shard {config['smoke_shard']} is not a shard id.")
    return problems


def write_outputs(plan, config, event, ref):
    legs = matrix(plan, config)
    coverage = plan["full"] and ref == "refs/heads/main" and event in ("schedule", "workflow_dispatch")
    outputs = {
        "full": str(plan["full"]).lower(),
        "checks": str(plan["checks"]).lower(),
        "unit": plan["unit"],
        "ui": str(bool(legs)).lower(),
        "ui_matrix": json.dumps({"include": legs}),
        "coverage": str(coverage).lower(),
        "expected_bundles": str(len(legs) + 1),
    }
    lines = [f"{key}={value}" for key, value in outputs.items()]
    target = os.environ.get("GITHUB_OUTPUT")
    if target:
        with open(target, "a", encoding="utf-8") as handle:
            handle.write("\n".join(lines) + "\n")
    print("\n".join(lines))

    summary = ["### Test selection", ""]
    if plan["full"]:
        summary.append("**Full run:** every unit suite, every UI shard and the Release build.")
    else:
        summary.append(f"**Unit targets:** {plan['unit'].replace('-only-testing:', '') or 'none'}")
        summary.append("")
        summary.append("**UI shards:** " + (", ".join(leg["name"] for leg in legs) or "none"))
    summary += ["", "Why:", ""] + [f"- {reason}" for reason in plan["reasons"][:40]]
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a", encoding="utf-8") as handle:
            handle.write("\n".join(summary) + "\n")
    print("\n".join(summary))


# --- self-test ---------------------------------------------------------------------------------
#
# A manifest, a UI suite and a selection config written here as literals. Reverting the selection
# logic to "run everything" or "run nothing" turns these red.

FIXTURE_MANIFEST = """
let project = Project(targets: [
        .target(
            name: "Domain",
            product: .staticFramework,
            buildableFolders: ["Sources/Domain"],
            dependencies: []
        ),
        .target(
            name: "DomainTests",
            product: .unitTests,
            buildableFolders: ["Tests/DomainTests"],
            dependencies: [.target(name: "Domain")]
        ),
        .target(
            name: "Journeys",
            product: .staticFramework,
            buildableFolders: ["Sources/Journeys"],
            dependencies: [.target(name: "Domain")]
        ),
        .target(
            name: "JourneysTests",
            product: .unitTests,
            buildableFolders: ["Tests/JourneysTests"],
            dependencies: [.target(name: "Journeys"), .target(name: "Domain")]
        ),
        .target(
            name: "Log",
            product: .staticFramework,
            buildableFolders: ["Sources/Log"],
            dependencies: [.target(name: "Domain")]
        ),
        .target(
            name: "Mimic",
            product: .app,
            buildableFolders: ["App/Sources"],
            dependencies: [
                .target(name: "Journeys"),
                // a comment naming .target(name: "Ghost") is ignored
                .target(name: "Log"),
            ]
        ),
        .target(
            name: "MimicTests",
            product: .unitTests,
            buildableFolders: [
                "Tests/MimicTests",
            ],
            dependencies: [.target(name: "Mimic")]
        ),
        .target(
            name: "MimicUITests",
            product: .uiTests,
            buildableFolders: ["MimicUITests"],
            dependencies: [.target(name: "Mimic")]
        ),
        .target(
            name: "Gallery",
            product: .app,
            resources: [.folderReference(path: "Design/Reference")],
            buildableFolders: ["Tools/Gallery"],
            dependencies: [.target(name: "Journeys")]
        ),
])
"""

FIXTURE_UI = [
    ("CoreUITests.swift", "final class CoreUITests: MimicUITestCase {\n    func testA() {}\n"),
    ("JourneyUITests.swift", "final class JourneyUITests: MimicUITestCase {\n    func testB() {}\n"),
    ("LogUITests.swift", "final class LogUITests: MimicUITestCase {\n    func testC() {}\n    func testD() {}\n"),
    ("MimicUITestCase.swift", "class MimicUITestCase: XCTestCase {\n}\n"),
]

FIXTURE_CONFIG = {
    "smoke_shard": 1,
    "ui_classes_by_target": {
        "Domain": "all", "Mimic": "all",
        "Journeys": ["JourneyUITests"], "Log": ["LogUITests"],
    },
    "full_paths": ["Project.swift", "Tuist/**"],
    "linux_only_paths": ["**/*.md", "docs/**", "Scripts/**"],
    "cli_paths": ["Scripts/run_cli_e2e.sh"],
    "ui_shards": [
        {"id": 1, "name": "core", "tests": ["CoreUITests"]},
        {"id": 2, "name": "journeys", "tests": ["JourneyUITests"]},
        {"id": 3, "name": "log A", "tests": ["LogUITests/testC"]},
        {"id": 4, "name": "log B", "tests": ["LogUITests/testD"]},
    ],
}


def self_test():
    failures = []

    def expect(label, condition, detail=""):
        print(f"  {'ok  ' if condition else 'FAIL'} {label}" + ("" if condition else f" {detail}"))
        if not condition:
            failures.append(label)

    print("select_tests.py --self-test")
    targets = parse_targets(FIXTURE_MANIFEST)
    expect("every target definition is parsed", sorted(targets) == sorted(
        ["Domain", "DomainTests", "Journeys", "JourneysTests", "Log", "Mimic", "MimicTests",
         "MimicUITests", "Gallery"]), sorted(targets))
    expect("commented dependencies are ignored", targets["Mimic"]["deps"] == ["Journeys", "Log"],
           targets["Mimic"]["deps"])
    expect("resource folders belong to their target",
           owner("Design/Reference/a.png", targets) == "Gallery")

    def run(*paths):
        return plan_for_changes(list(paths), FIXTURE_CONFIG, targets, FIXTURE_UI)

    plan = run("Sources/Journeys/Editor.swift")
    expect("a section change runs its own and dependent unit targets",
           plan["unit"] == "-only-testing:JourneysTests -only-testing:MimicTests", plan["unit"])
    expect("a section change runs its UI classes plus the smoke shard", plan["shards"] == [1, 2],
           plan["shards"])
    expect("a section change is not a full run", plan["full"] is False)

    plan = run("Sources/Log/Row.swift")
    expect("a class split across shards runs every part", plan["shards"] == [1, 3, 4], plan["shards"])

    plan = run("Sources/Domain/Model.swift")
    expect("a hub change runs every unit target that depends on it",
           plan["unit"] == "-only-testing:DomainTests -only-testing:JourneysTests -only-testing:MimicTests",
           plan["unit"])
    expect("a hub change runs every shard", plan["shards"] == [1, 2, 3, 4], plan["shards"])

    plan = run("Tests/DomainTests/ModelTests.swift")
    expect("a unit test change runs only that target",
           plan["unit"] == "-only-testing:DomainTests" and plan["shards"] == [], plan)

    plan = run("MimicUITests/LogUITests.swift")
    expect("a UI test file runs its own shards and no unit tests",
           plan["shards"] == [1, 3, 4] and plan["unit"] == "none" and plan["checks"] is False, plan)

    plan = run("MimicUITests/MimicUITestCase.swift")
    expect("shared UI support runs every shard", plan["shards"] == [1, 2, 3, 4], plan["shards"])

    plan = run("Tools/Gallery/Main.swift")
    expect("a module outside the app runs no UI shard", plan["shards"] == [] and plan["unit"] == "none",
           plan)

    plan = run("README.md", "docs/CLI.md", "Scripts/check_doc_counts.py")
    expect("documentation and scripts need no macOS job",
           plan["checks"] is False and plan["shards"] == [] and plan["unit"] == "none", plan)

    plan = run("Scripts/run_cli_e2e.sh")
    expect("a CLI e2e script runs the checks job alone",
           plan["checks"] is True and plan["unit"] == "none" and plan["shards"] == [], plan)

    plan = run("Sources/Log/Row.swift", "Project.swift")
    expect("a build setting change is a full run", plan["full"] is True and plan["unit"] == "all", plan)

    plan = run("Unknown/thing.txt")
    expect("an unknown path is a full run", plan["full"] is True, plan)

    plan = focus_plan("LogUITests/testC MimicUITests/CoreUITests", 5)
    expect("a focus run names its selectors once",
           plan["matrix"][0]["only"] == "-only-testing:MimicUITests/LogUITests/testC "
                                        "-only-testing:MimicUITests/CoreUITests", plan)
    expect("a focus run repeats until failure", "-test-iterations 5" in plan["matrix"][0]["extra"], plan)

    expect("a complete config passes the check", check(FIXTURE_CONFIG, targets, FIXTURE_UI) == [])
    missing = dict(FIXTURE_CONFIG, ui_classes_by_target={"Domain": "all", "Mimic": "all",
                                                        "Journeys": ["JourneyUITests"]})
    problems = check(missing, targets, FIXTURE_UI)
    expect("an app module without a UI entry fails the check",
           len(problems) == 1 and "Log" in problems[0], problems)
    ghost = dict(FIXTURE_CONFIG, ui_classes_by_target=dict(FIXTURE_CONFIG["ui_classes_by_target"],
                                                           Log=["GhostUITests"]))
    problems = check(ghost, targets, FIXTURE_UI)
    expect("an entry naming a missing UI class fails the check",
           len(problems) == 1 and "GhostUITests" in problems[0], problems)

    if failures:
        print(f"{len(failures)} self-test failure(s).")
        return 1
    print("All self-tests passed.")
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--event", default="pull_request")
    parser.add_argument("--ref", default="")
    parser.add_argument("--base", default="")
    parser.add_argument("--head", default="HEAD")
    parser.add_argument("--full", action="store_true")
    parser.add_argument("--only-testing", default="")
    parser.add_argument("--iterations", type=int, default=1)
    parser.add_argument("paths", nargs="*", help="changed paths (instead of --base/--head)")
    args = parser.parse_args()

    if args.self_test:
        return self_test()

    config = json.loads(CONFIG.read_text(encoding="utf-8"))
    targets = parse_targets(MANIFEST.read_text(encoding="utf-8"))
    ui_sources = read_ui_sources()

    if args.check:
        problems = check(config, targets, ui_sources)
        for problem in problems:
            print(f"error: {problem}", file=sys.stderr)
        if not problems:
            print("Test selection map covers every module the app links.")
        return 1 if problems else 0

    if args.only_testing.strip():
        plan = focus_plan(args.only_testing, max(1, args.iterations))
    elif args.full or args.event == "schedule":
        plan = full_plan(config, f"{args.event} run")
    elif args.paths:
        plan = plan_for_changes(args.paths, config, targets, ui_sources)
    elif not args.base or set(args.base) == {"0"}:
        plan = full_plan(config, "no base commit to compare against")
    else:
        try:
            paths = changed_paths(args.base, args.head)
        except subprocess.CalledProcessError as error:
            plan = full_plan(config, f"git diff failed ({error.stderr.strip()})")
        else:
            plan = plan_for_changes(paths, config, targets, ui_sources)

    write_outputs(plan, config, args.event, args.ref)
    return 0


if __name__ == "__main__":
    sys.exit(main())

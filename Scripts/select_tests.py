#!/usr/bin/env python3
"""Decides which tests a change runs, so a pull request runs only what the change can break.

CI's `plan` job runs this first. It reads the files a change touched and prints, as GitHub outputs:

  - `checks`: whether the macOS build, unit suites and CLI end-to-end job runs;
  - `unit`: `all`, `none`, or the `-only-testing:` flags for the unit test targets to run, and
    `unit_extra`, the retry flags that job passes with them;
  - `ui`: whether any UI shard runs, and `ui_matrix`, the shards themselves, longest first;
  - `full`: whether this is a full run (every unit suite and every UI shard);
  - `release`: whether the Release build runs;
  - `coverage`: whether this run publishes the merged coverage badges.

How a changed file is classified, first match wins (lists in `Scripts/test_selection.json`):

  1. `Scripts/test_selection.json` itself: a change confined to `ui_shards` runs the shards it adds
     or changes; any other change to it is a full run.
  2. `full_paths` (build settings, the workflow, this script): everything runs. Of those, only
     `release_paths` also run the Release build.
  3. `cli_paths`: the macOS build and CLI end-to-end checks run, no unit or UI tests.
  4. `gallery_paths`: the gallery's unit targets, and no UI shard.
  5. A file inside a Tuist target's buildable folder (read from `Project.swift`), or one
     `path_owners` gives a target: the unit test targets that depend on that target, directly or
     not, and the UI classes `ui_classes_by_target` names for that target itself.
     A UI test file in `ui_shared_support` selects every shard. Any other UI test file selects its
     own classes and every class whose file uses a type the change touched in it.
  6. `linux_only_paths`: nothing on macOS. The Linux job always runs.
  7. Anything else: everything runs, the Release build included. An unknown path is a reason to
     test more, never less.

Scheduled runs (the nightly full suite) and a manual run with `full` set run everything, Release
included, and never retry a failing test, so the nightly still counts flakes. Pull requests and
pushes run a failing test twice; `Scripts/report_flaky_tests.py` names every test that needed it. A
manual run naming `only_testing` selectors runs just those UI tests, optionally repeated until one
fails, on one runner.

`--ui-passed-at SHA` says the UI suite passed on SHA, an earlier head of the same pull request.
When everything changed since is a gallery snapshot, which only DesignFidelityTests reads, no UI
shard runs again.

`--check` fails when a module the app links has no entry in `ui_classes_by_target`, an entry names a
UI class that does not exist, or a UI class spells out an accessibility identifier a module defines
without that module's entry naming the class, so a new module or a new dependency gets a decision
instead of a silent gap. `--self-test` runs the selection over a fixture manifest written in this
file.
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
CONFIG_PATH = "Scripts/test_selection.json"
MANIFEST = ROOT / "Project.swift"
SOURCES = ROOT / "Sources"
UI_TESTS = ROOT / "MimicUITests"
UI_TARGET = "MimicUITests"
APP_TARGET = "Mimic"

# One retry: a transient failure costs one more run of that test instead of an hour-long re-run of
# the whole workflow. `report_flaky_tests.py` keeps every retried pass visible as a warning.
RETRY_FLAGS = "-retry-tests-on-failure -test-iterations 2"
# Seconds one UI test may run before XCTest fails it (and takes a spindump). The slowest test outside
# the layout audit takes about two minutes on CI; a shard can set its own `allowance`.
DEFAULT_ALLOWANCE = 300
# A focus run may name a layout audit test, which takes up to eight minutes.
FOCUS_ALLOWANCE = 900
# What a shard runs and how. Its name and measured minutes change nothing a test can see.
SHARD_BEHAVIOUR = ("tests", "allowance", "retry")

TARGET_DEF = re.compile(r"\.target\(\s*\n\s*name:\s*\"(\w+)\"")
PRODUCT = re.compile(r"product:\s*\.(\w+)")
FOLDERS = re.compile(r"buildableFolders:\s*\[(.*?)\]", re.DOTALL)
RESOURCE_FOLDER = re.compile(r"\.folderReference\(path:\s*\"([^\"]+)\"\)")
DEPENDENCY = re.compile(r"\.target\(name:\s*\"(\w+)\"\)")
CLASS_DECL = re.compile(r"^(?:final\s+|public\s+|open\s+)*class\s+([A-Za-z_][A-Za-z0-9_]*)\s*:")
TEST_FUNC = re.compile(r"^\s+(?:@\w+\s+)*(?:final\s+|public\s+|internal\s+)*func\s+(test\w+)\s*\(")
# A type declared at the top of a file: what another UI test file can use from it. An extension
# counts as declaring the type it extends, because another file can call what it adds.
TYPE_DECL = re.compile(
    r"(?:@\w+(?:\([^)]*\))?\s+)*"
    r"(?:(?:public|internal|fileprivate|private|final|open|nonisolated)\s+)*"
    r"(?:struct|enum|class|actor|protocol|extension)\s+([A-Za-z_]\w*)"
)
HUNK = re.compile(r"^@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@")
IDENTIFIER_DEF = re.compile(r"accessibilityIdentifier\(\s*\"([A-Za-z][A-Za-z0-9_.]*)")
DOTTED_LITERAL = re.compile(r"\"([A-Za-z][A-Za-z0-9_]*\.[A-Za-z0-9_.]+)\"")


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


def declared_classes(text):
    return {match.group(1) for match in map(CLASS_DECL.match, text.splitlines()) if match}


def read_ui_sources(root=UI_TESTS):
    return [(p.name, p.read_text(encoding="utf-8")) for p in sorted(root.rglob("*.swift"))]


def read_module_sources(root=SOURCES):
    return [(p.relative_to(ROOT).as_posix(), p.read_text(encoding="utf-8"))
            for p in sorted(root.rglob("*.swift"))]


def top_level_items(text):
    """`[(first line, type name or None)]` for each top-level declaration of a Swift file, in order.

    A declaration runs to the line before the next one, and the comments and attributes written
    above it are part of it. `None` is anything at the top level that is not a type (an import, a
    free function, `#if`): a change there can reach every type in the file."""
    items = []
    pending = None
    for number, line in enumerate(text.splitlines(), start=1):
        if not line.strip() or line[0].isspace() or line[0] in "})]":
            continue
        if line.startswith(("//", "/*", "*", "@")) and not TYPE_DECL.match(line):
            pending = pending or number
            continue
        declared = TYPE_DECL.match(line)
        items.append((pending or number, declared.group(1) if declared else None))
        pending = None
    return items


def changed_declarations(text, lines):
    """The type names whose top-level declarations hold any of `lines` (1-based, of `text`), or None
    when a changed line is not inside a type, so every type in the file has to count as changed."""
    items = top_level_items(text)
    names = set()
    for line in lines:
        enclosing = [name for start, name in items if start <= line]
        if not enclosing or enclosing[-1] is None:
            return None
        names.add(enclosing[-1])
    return names


def ui_classes_for_file(name, ui_sources, known, changed=None):
    """The UI test classes a change to the UI test file `name` can affect: the classes it declares,
    and every class whose file uses a type the change touched in it. `changed` is those types, or
    None for every type the file declares."""
    texts = dict(ui_sources)
    text = texts.get(name, "")
    hits = declared_classes(text) & known
    if changed is None:
        changed = {item for _start, item in top_level_items(text) if item}
    # Test classes are not used by name from other files; a page object or helper type is.
    shared = sorted(changed - known)
    if shared:
        used = re.compile(r"\b(?:" + "|".join(map(re.escape, shared)) + r")\b")
        for other, body in ui_sources:
            if other != name and used.search(body):
                hits |= declared_classes(body) & known
    return hits


def shard_changes(base_config, config):
    """For a change to the selection file itself: `(reason, None)` when it changes anything but
    `ui_shards`, which needs a full run, else `(None, ids)` of the shards it adds or changes."""
    for key in sorted(set(base_config) | set(config)):
        if key not in ("_comment", "ui_shards") and base_config.get(key) != config.get(key):
            return f"{CONFIG_PATH} changes {key}", None

    def behaviour(shard):
        return {key: shard.get(key) for key in SHARD_BEHAVIOUR}

    before = {shard.get("id"): behaviour(shard) for shard in base_config.get("ui_shards", [])}
    return None, {shard["id"] for shard in config["ui_shards"] if before.get(shard["id"]) != behaviour(shard)}


def full_plan(config, reason, release=False):
    return {
        "full": True, "checks": True, "unit": "all", "release": release,
        "shards": [shard["id"] for shard in config["ui_shards"]],
        "reasons": [reason],
    }


def plan_for_changes(paths, config, targets, ui_sources, ui_changes=None, base_config=None, head_config=None):
    """The plan for a set of changed paths. Pure: everything it reads is passed in.

    `ui_changes` maps a changed UI test file to the type names its change touched (None: all of
    them); a file it does not name counts as wholly changed. For a change to the selection file
    itself, `base_config` is that file as the change found it and `head_config` as the change left
    it (by default `config`, which on a pull request is the merge with the base branch)."""
    known_classes = set(ui_classes(ui_sources))
    release = any(matches(path, config.get("release_paths", [])) for path in paths)
    path_owners = config.get("path_owners", {})

    changed_targets = set()
    unit_targets = set()
    ui_selected = set()
    shard_ids = set()
    ui_all = False
    cli = False
    reasons = []

    for path in paths:
        if path == CONFIG_PATH:
            if base_config is None:
                return full_plan(config, f"{path} has no earlier copy to compare with", release)
            reason, changed = shard_changes(base_config, head_config or config)
            if reason:
                return full_plan(config, reason, release)
            shard_ids |= changed
            reasons.append(f"{path}: shards it adds or changes, {sorted(changed) or 'none'}")
            continue
        if matches(path, config["full_paths"]):
            return full_plan(config, f"{path} changes how everything is built or selected", release)
        if matches(path, config["cli_paths"]):
            cli = True
            reasons.append(f"{path}: CLI end-to-end")
            continue
        if matches(path, config.get("gallery_paths", [])):
            unit_targets |= set(config["gallery_unit_targets"])
            reasons.append(f"{path}: gallery only, {', '.join(config['gallery_unit_targets'])}")
            continue
        claimed = [target for pattern, target in path_owners.items() if matches(path, [pattern])]
        target = claimed[0] if claimed else owner(path, targets)
        if target == UI_TARGET:
            name = Path(path).name
            if matches(path, config.get("ui_shared_support", [])):
                ui_all = True
                reasons.append(f"{path}: every UI test launches through it, every shard")
                continue
            touched = (ui_changes or {}).get(path, None)
            names = ui_classes_for_file(name, ui_sources, known_classes, touched)
            if names:
                ui_selected |= names
                reasons.append(f"{path}: {', '.join(sorted(names))}")
            else:
                ui_all = True
                reasons.append(f"{path}: UI test support no class is known to use, every shard")
            continue
        if target:
            changed_targets.add(target)
            reasons.append(f"{path}: {target}")
            continue
        if matches(path, config["linux_only_paths"]):
            continue
        return full_plan(config, f"{path} belongs to no target and no known group", True)

    affected = dependents(changed_targets, targets) | unit_targets
    unit = sorted(name for name in affected if targets.get(name, {}).get("product") == "unitTests")

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
            if shard["id"] in shard_ids
            or any(selector.split("/")[0] in ui_selected for selector in shard["tests"])
        ]
        if chosen and config["smoke_shard"] not in chosen:
            chosen.insert(0, config["smoke_shard"])

    return {
        "full": False,
        "checks": bool(unit) or cli,
        "unit": " ".join(f"-only-testing:{name}" for name in unit) if unit else "none",
        "release": release,
        "shards": chosen,
        "reasons": reasons,
    }


def reuse_ui_verdict(plan, since, sha, config):
    """`plan` without its UI shards when the UI suite already passed on `sha`, an earlier head of the
    same pull request, and every path changed since then is a gallery snapshot. The snapshots are
    resources of DesignFidelityTests alone, which the unit job runs again, so no UI test can tell
    the difference; approving them used to cost a second full UI run."""
    snapshots = config.get("snapshot_paths", [])
    if not plan["shards"] or not since or not all(matches(path, snapshots) for path in since):
        return plan
    reason = (f"the UI suite passed on {sha[:12]} and only gallery snapshots changed since, "
              "so its verdict stands")
    return dict(plan, shards=[], reasons=plan["reasons"] + [reason])


def focus_plan(selectors, iterations):
    flags = " ".join(f"-only-testing:{s if s.startswith(UI_TARGET + '/') else UI_TARGET + '/' + s}"
                     for s in selectors.split())
    extra = f"-test-iterations {iterations} -run-tests-until-failure" if iterations > 1 else ""
    return {
        "full": False, "checks": False, "unit": "none", "release": False, "shards": [],
        "reasons": ["manual UI focus run"],
        "matrix": [{"id": 99, "name": "focus", "only": flags, "extra": extra, "allowance": FOCUS_ALLOWANCE}],
    }


def matrix(plan, config, retry):
    """The UI matrix legs, longest shard first, so they queue first: the account has five macOS
    runners, the shard that starts last decides when the run ends, and that should be a short one."""
    if "matrix" in plan:
        return plan["matrix"]
    by_id = {shard["id"]: shard for shard in config["ui_shards"]}
    ordered = sorted(plan["shards"], key=lambda shard_id: -by_id[shard_id].get("minutes", 0))
    return [
        {"id": shard_id, "name": by_id[shard_id]["name"],
         "extra": RETRY_FLAGS if retry and by_id[shard_id].get("retry", True) else "",
         "allowance": by_id[shard_id].get("allowance", DEFAULT_ALLOWANCE),
         "only": " ".join(f"-only-testing:{UI_TARGET}/{t}" for t in by_id[shard_id]["tests"])}
        for shard_id in ordered
    ]


def git(*args):
    return subprocess.run(["git", *args], cwd=ROOT, capture_output=True, text=True, check=True).stdout


def changed_paths(base, head, three_dot=True):
    # --no-renames: a moved file is its old path and its new one, so the module it left is tested
    # too. A rename otherwise reports only where the file went.
    span = f"{base}...{head}" if three_dot else f"{base}..{head}"
    return [line for line in git("diff", "--name-only", "--no-renames", span).splitlines() if line.strip()]


def changed_ui_declarations(base, head):
    """`{UI test file: type names its change touched, or None}`, read from the diff's hunks against
    the file as it is at `head` (the pull request's merge commit can number its lines differently)."""
    diff = git("diff", "--no-renames", "-U0", f"{base}...{head}", "--", f"{UI_TARGET}/")
    lines = {}
    current = None
    for line in diff.splitlines():
        if line.startswith("+++ "):
            current = line[6:] if line.startswith("+++ b/") else None
            if current:
                lines.setdefault(current, set())
            continue
        hunk = HUNK.match(line)
        if hunk and current:
            start, count = int(hunk.group(1)), int(hunk.group(2) or 1)
            # A pure deletion names the line before the gap; count both sides of it.
            lines[current].update(range(start, start + count) if count else (max(start, 1), start + 1))
    changes = {}
    for path, numbers in lines.items():
        if path.endswith(".swift"):
            changes[path] = changed_declarations(git("show", f"{head}:{path}"), numbers)
    return changes


def selection_at(base, head):
    """The selection file as the change found it (at the merge base, which is what the diff compares
    against) and as the change left it. Comparing those two, rather than the merge, keeps a change
    the base branch made since from reading as this change's."""
    merge_base = git("merge-base", base, head).strip()
    return (json.loads(git("show", f"{merge_base}:{CONFIG_PATH}")),
            json.loads(git("show", f"{head}:{CONFIG_PATH}")))


def identifier_users(module_sources, ui_sources, targets):
    """`{module: {UI test class: [identifiers]}}`: the classes whose own file spells out an
    accessibility identifier the module defines. Page objects and interpolated identifiers do not
    count, so this is a floor for `ui_classes_by_target`, never a replacement for it."""
    defined = {}
    for path, text in module_sources:
        module = owner(path, targets)
        if module:
            for identifier in IDENTIFIER_DEF.findall(text):
                defined.setdefault(identifier, set()).add(module)
    known = set(ui_classes(ui_sources))
    users = {}
    for _name, text in ui_sources:
        classes = declared_classes(text) & known
        for literal in sorted(set(DOTTED_LITERAL.findall(text))) if classes else ():
            for module in defined.get(literal, ()):
                for cls in classes:
                    users.setdefault(module, {}).setdefault(cls, []).append(literal)
    return users


def check(config, targets, ui_sources, module_sources=()):
    problems = []
    known = ui_classes(ui_sources)
    app_modules = dependencies(APP_TARGET, targets) | {APP_TARGET}
    by_target = config["ui_classes_by_target"]
    for name in sorted(app_modules):
        if name not in by_target:
            problems.append(
                f"{name} is linked by the app but has no entry in ui_classes_by_target in "
                "Scripts/test_selection.json. Name the UI test classes its changes should run, or \"all\"."
            )
    for name, entry in sorted(by_target.items()):
        if name not in targets:
            problems.append(f"ui_classes_by_target names {name}, which Project.swift does not define.")
        if entry != "all":
            for cls in entry:
                if cls not in known:
                    problems.append(f"ui_classes_by_target[{name}] names {cls}, which declares no UI tests.")
    for module, classes in sorted(identifier_users(module_sources, ui_sources, targets).items()):
        entry = by_target.get(module)
        if module not in app_modules or entry in (None, "all"):
            continue
        for cls in sorted(set(classes) - set(entry)):
            problems.append(
                f"{cls} uses accessibility identifiers {module} defines ({', '.join(classes[cls][:3])}) "
                f"but ui_classes_by_target[{module}] does not name it, so a change to {module} would not "
                "run it."
            )
    for name in config.get("gallery_unit_targets", []):
        if targets.get(name, {}).get("product") != "unitTests":
            problems.append(f"gallery_unit_targets names {name}, which is not a unit test target.")
    for pattern, name in sorted(config.get("path_owners", {}).items()):
        if name not in targets:
            problems.append(f"path_owners gives {pattern} to {name}, which Project.swift does not define.")
    if config["smoke_shard"] not in {shard["id"] for shard in config["ui_shards"]}:
        problems.append(f"smoke_shard {config['smoke_shard']} is not a shard id.")
    return problems


def write_outputs(plan, config, event, ref, retry):
    legs = matrix(plan, config, retry)
    coverage = plan["full"] and ref == "refs/heads/main" and event in ("schedule", "workflow_dispatch")
    outputs = {
        "full": str(plan["full"]).lower(),
        "checks": str(plan["checks"]).lower(),
        "unit": plan["unit"],
        "unit_extra": RETRY_FLAGS if retry else "",
        "ui": str(bool(legs)).lower(),
        "ui_matrix": json.dumps({"include": legs}),
        "release": str(plan["release"]).lower(),
        "coverage": str(coverage).lower(),
        "expected_bundles": str(len(legs) + 1),
    }
    lines = [f"{key}={value}" for key, value in outputs.items()]
    target = os.environ.get("GITHUB_OUTPUT")
    if target:
        with open(target, "a", encoding="utf-8") as handle:
            handle.write("\n".join(lines) + "\n")
    print("\n".join(lines))

    total = len(config["ui_shards"])
    summary = ["### Test selection", ""]
    if plan["full"]:
        summary.append("**Full run:** every unit suite.")
    else:
        summary.append(f"**Unit targets:** {plan['unit'].replace('-only-testing:', '') or 'none'}")
    summary.append("")
    if legs and len(legs) == total and "matrix" not in plan:
        summary.append(f"**UI shards:** all {total}")
    else:
        summary.append("**UI shards:** " + (", ".join(leg["name"] for leg in legs) or "none"))
    summary += [
        "",
        f"**Release build:** {'yes' if plan['release'] else 'no'}"
        f" · **Retries:** {'one per failing test' if retry else 'none'}",
        "", "Why:", "",
    ] + [f"- {reason}" for reason in plan["reasons"][:40]]
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
        .target(
            name: "GalleryTests",
            product: .unitTests,
            buildableFolders: ["Tests/GalleryTests"],
            dependencies: [.target(name: "Gallery")]
        ),
])
"""

FIXTURE_UI = [
    ("CoreUITests.swift", "final class CoreUITests: MimicUITestCase {\n    func testA() {}\n"),
    ("JourneyUITests.swift",
     "import XCTest\n\n"
     "/// The journeys navigator.\n"
     "struct JourneysPage {\n    let app: XCUIApplication\n}\n\n"
     "final class JourneyUITests: MimicUITestCase {\n    func testB() {}\n}\n"),
    ("LogUITests.swift",
     "final class LogUITests: MimicUITestCase {\n    func testC() { _ = JourneysPage(app: app) }\n"
     "    func testD() {}\n"),
    ("MimicUITestCase.swift", "class MimicUITestCase: XCTestCase {\n}\n"),
    ("Orphan.swift", "struct NobodyUsesThis {}\n"),
]

FIXTURE_CONFIG = {
    "smoke_shard": 1,
    "ui_classes_by_target": {
        "Domain": "all", "Mimic": "all",
        "Journeys": ["JourneyUITests"], "Log": ["LogUITests"],
    },
    "ui_shared_support": ["MimicUITests/MimicUITestCase.swift"],
    "full_paths": ["Project.swift", "Tuist/**", ".github/workflows/ci.yml"],
    "release_paths": ["Project.swift", "Tuist/**"],
    "gallery_paths": ["Sources/Domain/Catalog/**", "Tools/Gallery/**"],
    "gallery_unit_targets": ["GalleryTests", "DomainTests"],
    "path_owners": {"Vendor/Editor/Sources/**": "Log"},
    "snapshot_paths": ["Tests/GalleryTests/Snapshots/*.png"],
    "linux_only_paths": ["**/*.md", "docs/**", "Scripts/**"],
    "cli_paths": ["Scripts/run_cli_e2e.sh"],
    "ui_shards": [
        {"id": 1, "name": "core", "minutes": 4, "tests": ["CoreUITests"]},
        {"id": 2, "name": "journeys", "minutes": 9, "tests": ["JourneyUITests"]},
        {"id": 3, "name": "log A", "minutes": 6, "allowance": 600, "retry": False, "tests": ["LogUITests/testC"]},
        {"id": 4, "name": "log B", "minutes": 7, "tests": ["LogUITests/testD"]},
    ],
}

FIXTURE_MODULES = [
    ("Sources/Log/Row.swift", 'Text(row).accessibilityIdentifier("log.row")\n'),
    ("Sources/Journeys/Editor.swift", 'List {}.accessibilityIdentifier( "journey.steps")\n'),
]


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
         "MimicUITests", "Gallery", "GalleryTests"]), sorted(targets))
    expect("commented dependencies are ignored", targets["Mimic"]["deps"] == ["Journeys", "Log"],
           targets["Mimic"]["deps"])
    expect("resource folders belong to their target",
           owner("Design/Reference/a.png", targets) == "Gallery")

    def run(*paths, **options):
        return plan_for_changes(list(paths), FIXTURE_CONFIG, targets, FIXTURE_UI, **options)

    plan = run("Sources/Journeys/Editor.swift")
    expect("a section change runs its own and dependent unit targets",
           plan["unit"] == "-only-testing:GalleryTests -only-testing:JourneysTests -only-testing:MimicTests",
           plan["unit"])
    expect("a section change runs its UI classes plus the smoke shard", plan["shards"] == [1, 2],
           plan["shards"])
    expect("a section change is not a full run and builds no Release", plan["full"] is False
           and plan["release"] is False)

    plan = run("Sources/Log/Row.swift")
    expect("a class split across shards runs every part", plan["shards"] == [1, 3, 4], plan["shards"])

    plan = run("Sources/Domain/Model.swift")
    expect("a hub change runs every unit target that depends on it",
           plan["unit"] == "-only-testing:DomainTests -only-testing:GalleryTests "
                           "-only-testing:JourneysTests -only-testing:MimicTests", plan["unit"])
    expect("a hub change runs every shard", plan["shards"] == [1, 2, 3, 4], plan["shards"])

    plan = run("Tests/DomainTests/ModelTests.swift")
    expect("a unit test change runs only that target",
           plan["unit"] == "-only-testing:DomainTests" and plan["shards"] == [], plan)

    plan = run("MimicUITests/CoreUITests.swift")
    expect("a UI test file runs its own shards and no unit tests",
           plan["shards"] == [1] and plan["unit"] == "none" and plan["checks"] is False, plan)

    plan = run("MimicUITests/JourneyUITests.swift")
    expect("a UI test file declaring a page object runs every class that uses it",
           plan["shards"] == [1, 2, 3, 4], plan["shards"])

    text = dict(FIXTURE_UI)["JourneyUITests.swift"]
    expect("a change inside a test class touches only that class",
           changed_declarations(text, {9, 10}) == {"JourneyUITests"}, changed_declarations(text, {9, 10}))
    expect("a doc comment belongs to the declaration below it",
           changed_declarations(text, {3}) == {"JourneysPage"}, changed_declarations(text, {3}))
    expect("an import touches every type in the file", changed_declarations(text, {1}) is None)
    journeys = "MimicUITests/JourneyUITests.swift"
    plan = run(journeys, ui_changes={journeys: {"JourneyUITests"}})
    expect("a change to only the test class leaves the page object's users alone",
           plan["shards"] == [1, 2], plan["shards"])
    plan = run(journeys, ui_changes={journeys: {"JourneysPage"}})
    expect("a change to the page object runs the classes that use it", plan["shards"] == [1, 2, 3, 4],
           plan["shards"])

    plan = run("MimicUITests/MimicUITestCase.swift")
    expect("shared UI support runs every shard", plan["shards"] == [1, 2, 3, 4], plan["shards"])

    plan = run("MimicUITests/Orphan.swift")
    expect("UI support nobody is known to use runs every shard", plan["shards"] == [1, 2, 3, 4],
           plan["shards"])

    plan = run("Tools/Gallery/Main.swift", "Sources/Domain/Catalog/Cards.swift")
    expect("gallery-only code runs the gallery's unit targets and no UI shard",
           plan["shards"] == [] and plan["unit"] == "-only-testing:DomainTests -only-testing:GalleryTests",
           plan)

    plan = run("Vendor/Editor/Sources/Editor.swift")
    expect("a vendored source runs with the target that compiles it",
           plan["shards"] == [1, 3, 4] and plan["full"] is False and plan["release"] is False, plan)

    plan = run("README.md", "docs/CLI.md", "Scripts/check_doc_counts.py")
    expect("documentation and scripts need no macOS job",
           plan["checks"] is False and plan["shards"] == [] and plan["unit"] == "none", plan)

    plan = run("Scripts/run_cli_e2e.sh")
    expect("a CLI e2e script runs the checks job alone",
           plan["checks"] is True and plan["unit"] == "none" and plan["shards"] == [], plan)

    plan = run("Sources/Log/Row.swift", "Project.swift")
    expect("a build setting change is a full run with the Release build",
           plan["full"] is True and plan["unit"] == "all" and plan["release"] is True, plan)

    plan = run(".github/workflows/ci.yml")
    expect("a workflow change is a full run without the Release build",
           plan["full"] is True and plan["release"] is False, plan)

    plan = run("Unknown/thing.txt")
    expect("an unknown path is a full run with the Release build",
           plan["full"] is True and plan["release"] is True, plan)

    # testD moves into log A and log B goes; the journeys shard's measured minutes change.
    moved = json.loads(json.dumps(FIXTURE_CONFIG))
    moved["ui_shards"] = moved["ui_shards"][:3]
    moved["ui_shards"][2]["tests"] = ["LogUITests/testC", "LogUITests/testD"]
    moved["ui_shards"][1]["minutes"] = 12
    plan = plan_for_changes([CONFIG_PATH], moved, targets, FIXTURE_UI, base_config=FIXTURE_CONFIG)
    expect("moving tests between shards runs only the shards that changed, and the smoke shard",
           plan["full"] is False and plan["shards"] == [1, 3] and plan["checks"] is False, plan)
    remapped = dict(FIXTURE_CONFIG,
                    ui_classes_by_target=dict(FIXTURE_CONFIG["ui_classes_by_target"], Log="all"))
    plan = plan_for_changes([CONFIG_PATH], remapped, targets, FIXTURE_UI, base_config=FIXTURE_CONFIG)
    expect("any other change to the selection file is a full run without Release",
           plan["full"] is True and plan["release"] is False, plan)
    merged = dict(moved, cli_paths=["Scripts/run_cli_e2e.sh", "Scripts/new_e2e.sh"])
    plan = plan_for_changes([CONFIG_PATH], merged, targets, FIXTURE_UI, base_config=FIXTURE_CONFIG,
                            head_config=moved)
    expect("a key the base branch changed meanwhile does not count as the change's",
           plan["full"] is False and plan["shards"] == [1, 3], plan)
    plan = plan_for_changes([CONFIG_PATH], FIXTURE_CONFIG, targets, FIXTURE_UI)
    expect("a selection file with no earlier copy is a full run", plan["full"] is True, plan)

    plan = run("Sources/Journeys/Editor.swift")
    reused = reuse_ui_verdict(plan, ["Tests/GalleryTests/Snapshots/card.dark.png"], "a" * 40, FIXTURE_CONFIG)
    expect("a snapshot-only push after a green UI suite runs no UI shard",
           reused["shards"] == [] and reused["unit"] == plan["unit"], reused)
    kept = reuse_ui_verdict(plan, ["Tests/GalleryTests/Snapshots/card.png", "Sources/Log/Row.swift"],
                            "a" * 40, FIXTURE_CONFIG)
    expect("a push with anything besides snapshots keeps its UI shards", kept["shards"] == [1, 2], kept)

    legs = matrix(run("Sources/Domain/Model.swift"), FIXTURE_CONFIG, retry=True)
    expect("the matrix lists the longest shard first", [leg["id"] for leg in legs] == [2, 4, 3, 1],
           [leg["id"] for leg in legs])
    expect("a pull request retries a failing test once, unless the shard opts out",
           [leg["extra"] for leg in legs] == [RETRY_FLAGS, RETRY_FLAGS, "", RETRY_FLAGS], legs)
    expect("a shard's allowance reaches its leg", [leg["allowance"] for leg in legs] == [300, 300, 600, 300],
           legs)
    legs = matrix(run("Sources/Domain/Model.swift"), FIXTURE_CONFIG, retry=False)
    expect("the nightly retries nothing", all(leg["extra"] == "" for leg in legs), legs)

    plan = focus_plan("LogUITests/testC MimicUITests/CoreUITests", 5)
    expect("a focus run names its selectors once",
           plan["matrix"][0]["only"] == "-only-testing:MimicUITests/LogUITests/testC "
                                        "-only-testing:MimicUITests/CoreUITests", plan)
    expect("a focus run repeats until failure and never retries",
           plan["matrix"][0]["extra"] == "-test-iterations 5 -run-tests-until-failure"
           and matrix(plan, FIXTURE_CONFIG, retry=True) == plan["matrix"], plan)

    expect("a complete config passes the check",
           check(FIXTURE_CONFIG, targets, FIXTURE_UI, FIXTURE_MODULES) == [],
           check(FIXTURE_CONFIG, targets, FIXTURE_UI, FIXTURE_MODULES))
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
    spelled = FIXTURE_UI + [("Steps.swift", 'final class StepsUITests: MimicUITestCase {\n'
                                            '    func testE() { _ = app.tables["journey.steps"] }\n')]
    problems = check(FIXTURE_CONFIG, targets, spelled, FIXTURE_MODULES)
    expect("a class spelling a module's identifier must be in that module's entry",
           len(problems) == 1 and "StepsUITests" in problems[0] and "journey.steps" in problems[0], problems)
    wrong = dict(FIXTURE_CONFIG, gallery_unit_targets=["Gallery"], path_owners={"Vendor/**": "Ghost"})
    problems = check(wrong, targets, FIXTURE_UI)
    expect("gallery targets and path owners must exist",
           len(problems) == 2 and "Gallery" in problems[0] and "Ghost" in problems[1], problems)

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
    parser.add_argument("--ui-passed-at", default="",
                        help="an earlier head of this pull request whose UI suite passed")
    parser.add_argument("paths", nargs="*", help="changed paths (instead of --base/--head)")
    args = parser.parse_args()

    if args.self_test:
        return self_test()

    config = json.loads(CONFIG.read_text(encoding="utf-8"))
    targets = parse_targets(MANIFEST.read_text(encoding="utf-8"))
    ui_sources = read_ui_sources()

    if args.check:
        problems = check(config, targets, ui_sources, read_module_sources())
        for problem in problems:
            print(f"error: {problem}", file=sys.stderr)
        if not problems:
            print("Test selection map covers every module the app links.")
        return 1 if problems else 0

    focus = bool(args.only_testing.strip())
    if focus:
        plan = focus_plan(args.only_testing, max(1, args.iterations))
    elif args.full or args.event == "schedule":
        plan = full_plan(config, f"{args.event} run", release=True)
    elif args.paths:
        base_config = None
        if CONFIG_PATH in args.paths:
            try:
                base_config = json.loads(git("show", f"HEAD:{CONFIG_PATH}"))
            except (subprocess.CalledProcessError, ValueError):
                pass
        plan = plan_for_changes(args.paths, config, targets, ui_sources, base_config=base_config)
    elif not args.base or set(args.base) == {"0"}:
        plan = full_plan(config, "no base commit to compare against", release=True)
    else:
        try:
            paths = changed_paths(args.base, args.head)
        except subprocess.CalledProcessError as error:
            plan = full_plan(config, f"git diff failed ({error.stderr.strip()})", release=True)
        else:
            # Both refinements narrow the selection; without them a UI test file counts as wholly
            # changed and a change to the selection file is a full run.
            ui_changes = base_config = head_config = None
            try:
                ui_changes = changed_ui_declarations(args.base, args.head)
            except subprocess.CalledProcessError:
                pass
            if CONFIG_PATH in paths:
                try:
                    base_config, head_config = selection_at(args.base, args.head)
                except (subprocess.CalledProcessError, ValueError):
                    pass
            plan = plan_for_changes(paths, config, targets, ui_sources, ui_changes, base_config, head_config)

    if args.ui_passed_at and not focus:
        sha = args.ui_passed_at
        try:
            # An earlier head that is not an ancestor was rewritten (a rebase or a force-push), so
            # what passed then is not what is here now.
            subprocess.run(["git", "merge-base", "--is-ancestor", sha, args.head], cwd=ROOT, check=True,
                           capture_output=True)
            since = changed_paths(sha, args.head, three_dot=False)
        except subprocess.CalledProcessError:
            print(f"{sha} is not an earlier head of {args.head}; its UI verdict is not reused.")
        else:
            plan = reuse_ui_verdict(plan, since, sha, config)

    # The nightly keeps no retries, so it still counts every flake; a focus run repeats until failure.
    retry = args.event in ("pull_request", "push") and not focus
    write_outputs(plan, config, args.event, args.ref, retry)
    return 0


if __name__ == "__main__":
    sys.exit(main())

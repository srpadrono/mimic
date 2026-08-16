#!/usr/bin/env python3

"""Reads line coverage out of `.xcresult` bundles. One reader, five callers.

**The two figures land in two different places, written by two different people, and that split is
the design rather than an accident.** The badges at the top of README.md are published by CI, from
`main`, as shields.io *endpoint* payloads on an orphan `badges` branch — nothing in the tracked tree
moves when they change. The detailed per-target table between README.md's `coverage:generated`
markers is written **only** by a local full-suite run on a Mac; no CI path writes it, and no mode of
this script writes it from anything but `--results-dir`.

**`--results-dir`** is the mode `Scripts/run_full_test_suite.sh` uses: one bundle per scheme, on a
Mac, after a full suite run. It rewrites the block between the `coverage:generated` markers, in
place, and **does not touch the badges** — it checks them instead, see `check_badges`.

**`--result-bundle`** is the mode `.github/workflows/ci.yml` uses for the job summary: one bundle —
the workspace-wide unit run — printed as Markdown on stdout. It reads the bundle and changes
nothing, so it is safe on a pull request from a fork, where the token is read-only.

**`--result-bundle --emit-json`** writes those same numbers to a small JSON file instead of printing
them. It is what the macOS job hands to the job that publishes them, so a several-hundred-megabyte
`.xcresult` never has to leave the runner that produced it.

**`--from-json --emit-badges`** turns that file into the two shields.io endpoint payloads the
`badges` branch carries. It needs neither Xcode nor a bundle, which is what lets the publishing job
run on Linux holding `contents: write` while the job that compiles code out of a pull request keeps
a read-only token.

**`--print-badge-branch`** prints the branch name the workflow force-pushes those payloads to, so
the branch is written down once — here, beside the URLs the README has to carry — rather than once
in YAML and once in Markdown.

Every mode goes through `target_metrics`, so the numbers a reviewer reads in a job summary, the
numbers on the badges and the numbers in the README table come out of one piece of code rather than
three that agree by hand.

**Nothing generated here carries a timestamp, a run number or a run URL, deliberately.** Everything
written is a pure function of the coverage figures. That property no longer has to hold for CI — the
badge branch is force-pushed to a single commit every time, so it cannot accumulate history whatever
the payload says — but it still has to hold for the README block, which a human commits: an
unchanged local measurement must leave the file byte-identical, or every full-suite run leaves a
dirty tree and a diff nobody wants to read.

`--self-test` exercises the JSON round trip, the badge payloads, the block rewriter and the refusals
against fixtures written out longhand in this file, so the half of it that needs no Mac is checked
on every Linux CI run.

Stdlib only, so the Linux CI container's `python3-minimal` and a Mac's system Python both run it.
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
from dataclasses import asdict, dataclass
from pathlib import Path


APP_TARGET = ("Mimic.app", "Mimic.app", "MimicApp.xcresult")
MODULE_TARGETS = [
    ("Domain.framework", "Domain.framework", "Domain.xcresult"),
    ("MockServerEngine.framework", "MockServerEngine.framework", "MockServerEngine.xcresult"),
    ("Persistence.framework", "Persistence.framework", "Persistence.xcresult"),
    ("DesignSystem.framework", "DesignSystem.framework", "DesignSystem.xcresult"),
    ("SpecImport.framework", "SpecImport.framework", "SpecImport.xcresult"),
    # ControlPlane and MimicCLICore are the automation surface the README leads with, and both were
    # missing here while `run_full_test_suite.sh` produced their bundles anyway — so the generated
    # "modules at or above 95%: n/6" counted six of the eight modules actually measured, and the two
    # left out were invisible.
    ("ControlPlane.framework", "ControlPlane.framework", "ControlPlane.xcresult"),
    ("MimicCLICore.framework", "MimicCLICore.framework", "MimicCLICore.xcresult"),
    # AppFeatures has no standalone test scheme; its coverage is captured in the app test run.
    ("AppFeatures.framework", "AppFeatures.framework", "MimicApp.xcresult"),
]

# The order the summary table lists targets in: the README's order first, then anything else the
# bundle happens to carry, alphabetically. A workspace-wide run reports more targets than the
# per-scheme runs do — the test bundles themselves among them — and inventing a second ordering for
# them would be one more list to keep in step with this one.
SUMMARY_ORDER = [APP_TARGET[1]] + [xccov_name for _, xccov_name, _ in MODULE_TARGETS]


# ---------------------------------------------------------------------------
# The published badges.
#
# `main` is protected: changes to it must arrive through a pull request, and the Actions bot is not
# exempt. Every push the recording job ever made to `main` was refused with GH006, for six merges,
# while the job itself went green — so the badges read `not measured` for this repository's whole
# history. The owner declined to weaken the rule for a badge, so the figures go somewhere the rule
# does not apply: an **orphan branch carrying nothing but these two files**, force-pushed to a single
# commit on every push to `main`, holding no source and therefore needing no review.
#
# The four names below are the whole contract between three files — this script writes the payloads,
# `.github/workflows/ci.yml` pushes them (asking `--print-badge-branch` for the branch rather than
# repeating it), and README.md links them. `check_badges` holds the README to them, so renaming a
# payload here fails the next full-suite run rather than silently turning both badges into
# shields.io's "invalid" placeholder.
BADGE_REPO = "srpadrono/mimic"
BADGE_BRANCH = "badges"
APP_BADGE_FILE = "app-coverage.json"
MODULE_BADGE_FILE = "module-coverage.json"

# The labels the badges have always carried, kept verbatim so the two badges do not change wording
# on the day they start carrying a number.
APP_BADGE_LABEL = "Mimic.app coverage"
MODULE_BADGE_LABEL = "modules at or above 95%"


def raw_url(filename: str) -> str:
    """Where shields.io fetches one payload from."""
    return f"https://raw.githubusercontent.com/{BADGE_REPO}/{BADGE_BRANCH}/{filename}"


def endpoint_badge_url(filename: str) -> str:
    """The `img.shields.io/endpoint` URL README.md must carry for one payload.

    The inner URL is percent-encoded by hand rather than with `urllib.parse.quote`, because this
    file's one hard constraint is that it imports nothing outside what the Linux container's
    `python3-minimal` ships. Only `:` and `/` need escaping in a raw.githubusercontent.com URL —
    everything else in one is unreserved — and `%` is escaped first so the transformation stays
    correct if a name ever contains one.
    """
    encoded = raw_url(filename).replace("%", "%25").replace(":", "%3A").replace("/", "%2F")
    return f"https://img.shields.io/endpoint?url={encoded}"


@dataclass(frozen=True)
class CoverageMetrics:
    percent: float
    covered_lines: int
    executable_lines: int


def run_xccov(result_bundle: Path) -> str:
    completed = subprocess.run(
        ["xcrun", "xccov", "view", "--report", "--only-targets", str(result_bundle)],
        check=True,
        capture_output=True,
        text=True,
    )
    return completed.stdout


# The fallback parser for the command above. Deliberately looser than the columns any one Xcode
# prints: the leading and trailing `\d+` groups are optional, so both the bare
# `Domain.framework 93.21% (2345/2516)` shape and an indexed one are read the same way. What is not
# optional is the `%` and the `(covered/executable)` pair, which is what keeps a header row or a
# stray line from being mistaken for a target.
TEXT_ROW = re.compile(
    r"^\s*(?:\d+\s+)?(?P<name>[A-Za-z0-9_.+-]+)\s+(?:\d+\s+)?"
    r"(?P<percent>\d+\.\d+)%\s*\((?P<covered>\d+)/(?P<executable>\d+)\)",
    re.MULTILINE,
)


def target_metrics(result_bundle: Path) -> dict[str, CoverageMetrics]:
    """Every target in one bundle, keyed by the name `xccov` reports it under.

    JSON first, because it is a documented structure with named fields rather than a column layout
    that has to be matched by eye — and this file could not be run against a real bundle where it
    was last edited, so the parse that does not depend on spacing is the one to prefer. The text
    report is kept as a fallback for an `xccov` whose `--json` is unavailable, and a failure of both
    is raised with whatever `xccov` said, since "could not read the bundle" and "the bundle has no
    coverage in it" want different fixes from whoever reads the message.
    """
    if not result_bundle.exists():
        raise RuntimeError(f"no result bundle at {result_bundle}")

    completed = subprocess.run(
        ["xcrun", "xccov", "view", "--report", "--only-targets", "--json", str(result_bundle)],
        capture_output=True,
        text=True,
    )
    if completed.returncode == 0:
        try:
            report = json.loads(completed.stdout)
            return {
                target["name"]: CoverageMetrics(
                    percent=100.0 * float(target["lineCoverage"]),
                    covered_lines=int(target["coveredLines"]),
                    executable_lines=int(target["executableLines"]),
                )
                for target in report["targets"]
            }
        except (json.JSONDecodeError, KeyError, TypeError, ValueError):
            pass

    try:
        report_text = run_xccov(result_bundle)
    except subprocess.CalledProcessError as error:
        detail = (error.stderr or "").strip() or f"exit {error.returncode}"
        raise RuntimeError(f"`xcrun xccov` could not read {result_bundle}: {detail}") from error

    return {
        match.group("name"): CoverageMetrics(
            percent=float(match.group("percent")),
            covered_lines=int(match.group("covered")),
            executable_lines=int(match.group("executable")),
        )
        for match in TEXT_ROW.finditer(report_text)
    }


def metrics_for_target(result_bundle: Path, target_name: str) -> CoverageMetrics:
    metrics = target_metrics(result_bundle)
    if target_name not in metrics:
        found = ", ".join(sorted(metrics)) or "no targets at all"
        raise RuntimeError(
            f"Could not find target '{target_name}' in the xccov report for {result_bundle} — it has {found}."
        )
    return metrics[target_name]


def badge_color(percent: float) -> str:
    if percent >= 95.0:
        return "brightgreen"
    if percent >= 90.0:
        return "green"
    if percent >= 80.0:
        return "yellow"
    return "red"


def format_percent(percent: float) -> str:
    return f"{percent:.2f}%"


def format_lines(metrics: CoverageMetrics) -> str:
    return f"{metrics.covered_lines:,}/{metrics.executable_lines:,}"


def build_coverage_block(
    app_metrics: CoverageMetrics,
    module_metrics: list[tuple[str, CoverageMetrics]],
    *,
    generated_from: str,
    provenance: str,
) -> str:
    lines = [
        "<!-- coverage:generated:start -->",
        f"This section is auto-generated — do not edit it by hand. {generated_from}",
        "",
        "Latest measured line coverage:",
        "",
        "| Target | Coverage | Lines |",
        "| --- | ---: | ---: |",
        f"| `Mimic.app` | `{format_percent(app_metrics.percent)}` | `{format_lines(app_metrics)}` |",
    ]

    for target_name, metrics in module_metrics:
        lines.append(f"| `{target_name}` | `{format_percent(metrics.percent)}` | `{format_lines(metrics)}` |")

    at_or_above = modules_at_or_above_95(module_metrics)
    total_executable_lines = app_metrics.executable_lines + sum(metrics.executable_lines for _, metrics in module_metrics)
    lines.extend(
        [
            "",
            "Coverage notes:",
            "",
            f"- App coverage is currently `{format_percent(app_metrics.percent)}`.",
            f"- Modules at or above `95%`: `{at_or_above}/{len(module_metrics)}`.",
            f"- Total executable lines tracked in this table: `{total_executable_lines:,}`.",
            "- `Lines` shows covered/executable lines reported by `xcrun xccov`.",
            "- Coverage is gathered with `xcodebuild` and `xcrun xccov` from fresh `.xcresult` bundles.",
            f"- {provenance}",
            "<!-- coverage:generated:end -->",
        ]
    )
    return "\n".join(lines)


def summary_order(names: list[str]) -> list[str]:
    known = [name for name in SUMMARY_ORDER if name in names]
    return known + sorted(name for name in names if name not in set(SUMMARY_ORDER))


def build_summary(result_bundle: Path, metrics: dict[str, CoverageMetrics], title: str) -> str:
    lines = [
        f"### {title}",
        "",
        f"Line coverage read with `xcrun xccov` from `{result_bundle}`.",
        "",
        "| Target | Coverage | Lines |",
        "| --- | ---: | ---: |",
    ]
    for name in summary_order(list(metrics)):
        entry = metrics[name]
        lines.append(f"| `{name}` | {format_percent(entry.percent)} | {format_lines(entry)} |")

    products = [entry for name, entry in metrics.items() if not name.endswith(".xctest")]
    covered = sum(entry.covered_lines for entry in products)
    executable = sum(entry.executable_lines for entry in products)
    lines.append("")
    if executable:
        lines.append(
            f"**Product targets together: {format_percent(100.0 * covered / executable)}** "
            f"({covered:,}/{executable:,} lines)."
        )
    if any(name.endswith(".xctest") for name in metrics):
        lines.append(
            "Rows ending `.xctest` are the test bundles themselves — coverage of the tests, not of "
            "the app — and are left out of that figure."
        )
    lines.extend(
        [
            "",
            "No coverage floor is enforced: this run measures and reports, nothing more. A floor is "
            "the next step, once there is a baseline to set it against.",
        ]
    )
    return "\n".join(lines)


def replace_coverage_block(readme: str, new_block: str) -> str:
    pattern = re.compile(
        r"<!-- coverage:generated:start -->.*?<!-- coverage:generated:end -->",
        re.DOTALL,
    )
    if not pattern.search(readme):
        raise RuntimeError("README.md is missing coverage generation markers.")
    return pattern.sub(new_block, readme, count=1)


def modules_at_or_above_95(module_metrics: list[tuple[str, CoverageMetrics]]) -> int:
    return sum(1 for _, metrics in module_metrics if metrics.percent >= 95.0)


def badge_payloads(
    app_metrics: CoverageMetrics, module_metrics: list[tuple[str, CoverageMetrics]]
) -> dict[str, dict]:
    """The two shields.io endpoint payloads, keyed by the file name each is published under.

    Endpoint schema, which shields.io fetches and renders: `schemaVersion` pins the contract,
    `label` is the grey half, `message` the coloured half, `color` the colour. Nothing else, and
    no `cacheSeconds` — shields caches an endpoint response for a few minutes of its own accord and
    a badge that is five minutes stale is not a problem worth a knob.
    """
    at_or_above = modules_at_or_above_95(module_metrics)
    module_count = len(module_metrics)
    return {
        APP_BADGE_FILE: {
            "schemaVersion": 1,
            "label": APP_BADGE_LABEL,
            "message": format_percent(app_metrics.percent),
            "color": badge_color(app_metrics.percent),
        },
        MODULE_BADGE_FILE: {
            "schemaVersion": 1,
            "label": MODULE_BADGE_LABEL,
            "message": f"{at_or_above}/{module_count}",
            # Coloured by the *proportion* of modules clearing the bar, on the same ladder as a
            # percentage, so "8/8" is bright green and "4/8" is red.
            "color": badge_color(100.0 * at_or_above / module_count),
        },
    }


def write_badges(
    destination: Path,
    app_metrics: CoverageMetrics,
    module_metrics: list[tuple[str, CoverageMetrics]],
) -> list[Path]:
    destination.mkdir(parents=True, exist_ok=True)
    written = []
    for filename, payload in badge_payloads(app_metrics, module_metrics).items():
        path = destination / filename
        path.write_text(json.dumps(payload, indent=2) + "\n")
        written.append(path)
    return written


def check_badges(readme: str) -> None:
    """Refuse a README whose badges do not point at the payloads this script publishes.

    The badges are no longer *written* here — CI publishes them to the `badges` branch and the
    README carries a fixed endpoint URL per payload, so the local writer must leave them alone. What
    it can still do is notice when the two have come apart, which is the drift this arrangement
    invites: rename a payload, or move the branch, and both badges quietly become shields.io's
    "invalid" placeholder with nothing going red.

    Its ancestor, `replace_badges`, existed for the mirror-image reason — `re.sub` with no match
    returns the string unchanged and raises nothing, so a README with no badges at all made the
    rewrite a guaranteed silent no-op while `run_full_test_suite.sh` printed "README coverage
    section updated." Neither failure is allowed to be silent.
    """
    for filename in (APP_BADGE_FILE, MODULE_BADGE_FILE):
        if endpoint_badge_url(filename) not in readme:
            raise RuntimeError(
                f"README.md does not carry the endpoint badge for {filename}. It must link "
                f"{endpoint_badge_url(filename)} — that is the URL shields.io reads the figure "
                f"from, and it names the branch `{BADGE_BRANCH}` that CI force-pushes to."
            )


def report_one_bundle(result_bundle: Path, title: str) -> int:
    """Print a Markdown report for a single bundle. Never edits anything.

    A failure prints its reason *on stdout* rather than only on stderr, because the caller pipes
    this into `$GITHUB_STEP_SUMMARY`: a reviewer who sees no table should see why in the same place,
    not have to open the raw log for it. The non-zero exit is what puts the warning annotation on
    the step, which is why the workflow marks that step `continue-on-error` instead of dropping the
    status.
    """
    try:
        metrics = target_metrics(result_bundle)
    except RuntimeError as error:
        print(f"### {title}\n\nNot reported: {error}.")
        return 1

    if not metrics:
        print(
            f"### {title}\n\nNot reported: `xcrun xccov` read `{result_bundle}` and found no target "
            "with coverage data in it. Either the test run was not built with "
            "`-enableCodeCoverage YES`, or the scheme gathers coverage for no target."
        )
        return 1

    print(build_summary(result_bundle, metrics, title))
    return 0


# The one provenance wording left. There used to be two, because CI wrote this block as well and a
# reader had to be told which of the two writers a number came from. It does not any more: the block
# is local-only by design, and the badges above it are CI-only, so the answer to "how stale is this"
# is the same every time.
FULL_SUITE_GENERATED_FROM = (
    "It is written from the coverage-enabled `.xcresult` bundles `./Scripts/run_full_test_suite.sh` "
    "produces on a Mac, one per scheme."
)
FULL_SUITE_PROVENANCE = (
    "This table is as fresh as whoever last ran the full suite on a Mac, and nothing in CI writes "
    "it. The two badges at the top of this file are the other way round — CI measures them on every "
    "push to `main` and publishes them to the `badges` branch — so when the two disagree, the badges "
    "are the current ones."
)


def render_readme(
    readme: str,
    app_metrics: CoverageMetrics,
    module_metrics: list[tuple[str, CoverageMetrics]],
    *,
    generated_from: str,
    provenance: str,
) -> str:
    """The whole rewrite as a string function, so `--self-test` can check it without touching disk.

    The badges are checked and left alone; only the block between the markers is rewritten. A README
    edited between a measurement and a rewrite therefore keeps every other change it picked up.
    """
    check_badges(readme)
    return replace_coverage_block(
        readme,
        build_coverage_block(
            app_metrics,
            module_metrics,
            generated_from=generated_from,
            provenance=provenance,
        ),
    )


def write_readme(
    readme_path: Path,
    app_metrics: CoverageMetrics,
    module_metrics: list[tuple[str, CoverageMetrics]],
    *,
    generated_from: str,
    provenance: str,
) -> None:
    readme_path.write_text(
        render_readme(
            readme_path.read_text(),
            app_metrics,
            module_metrics,
            generated_from=generated_from,
            provenance=provenance,
        )
    )


def update_readme(readme_path: Path, results_dir: Path) -> None:
    app_metrics = metrics_for_target(results_dir / APP_TARGET[2], APP_TARGET[1])

    module_metrics: list[tuple[str, CoverageMetrics]] = []
    for display_name, xccov_name, filename in MODULE_TARGETS:
        module_metrics.append((display_name, metrics_for_target(results_dir / filename, xccov_name)))

    write_readme(
        readme_path,
        app_metrics,
        module_metrics,
        generated_from=FULL_SUITE_GENERATED_FROM,
        provenance=FULL_SUITE_PROVENANCE,
    )


def split_workspace_metrics(
    metrics: dict[str, CoverageMetrics],
) -> tuple[CoverageMetrics, list[tuple[str, CoverageMetrics]]]:
    """Pick the README's nine targets out of one workspace-wide report.

    Every one of them has to be there. A partial table is worse than none: the badge's denominator
    is `len(module_metrics)`, so a module that silently dropped out of the bundle would shrink
    "modules at or above 95%: n/8" to `n/7` and read as a pass. That exact failure is why
    `ControlPlane` and `MimicCLICore` were once measured and invisible — see `MODULE_TARGETS`.
    """
    wanted = [APP_TARGET[1]] + [xccov_name for _, xccov_name, _ in MODULE_TARGETS]
    missing = [name for name in wanted if name not in metrics]
    if missing:
        found = ", ".join(sorted(metrics)) or "no targets at all"
        raise RuntimeError(
            f"the report is missing {', '.join(missing)} — it has {found}. Refusing to write a "
            "partial coverage table."
        )
    return metrics[APP_TARGET[1]], [
        (display_name, metrics[xccov_name]) for display_name, xccov_name, _ in MODULE_TARGETS
    ]


def emit_json(result_bundle: Path, destination: Path) -> None:
    app_metrics, module_metrics = split_workspace_metrics(target_metrics(result_bundle))
    payload = {
        "app": {"name": APP_TARGET[0], **asdict(app_metrics)},
        "modules": [{"name": name, **asdict(metrics)} for name, metrics in module_metrics],
    }
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")


def metrics_from_json(
    json_path: Path,
) -> tuple[CoverageMetrics, list[tuple[str, CoverageMetrics]]]:
    """Read back what `--emit-json` wrote, on a machine with no Xcode and no bundle."""
    try:
        payload = json.loads(json_path.read_text())
        app_metrics = CoverageMetrics(
            percent=float(payload["app"]["percent"]),
            covered_lines=int(payload["app"]["covered_lines"]),
            executable_lines=int(payload["app"]["executable_lines"]),
        )
        module_metrics = [
            (
                str(entry["name"]),
                CoverageMetrics(
                    percent=float(entry["percent"]),
                    covered_lines=int(entry["covered_lines"]),
                    executable_lines=int(entry["executable_lines"]),
                ),
            )
            for entry in payload["modules"]
        ]
    except (json.JSONDecodeError, KeyError, TypeError, ValueError) as error:
        raise RuntimeError(f"{json_path} is not a coverage payload this script wrote: {error}") from error

    if not module_metrics:
        # The module badge's denominator is `len(module_metrics)`, so an empty list is not an empty
        # badge — it is a division by zero, and a payload of eight modules that arrived carrying
        # three would read `3/3` and look like a clean sweep. `split_workspace_metrics` refuses the
        # partial table upstream for the same reason; this is the same refusal at the other end of
        # the hand-off, where the file could have been truncated in between.
        raise RuntimeError(f"{json_path} carries no modules; refusing to publish a badge with none.")

    return app_metrics, module_metrics


# Both URLs are written out longhand, character by character, and are **not** built from
# `endpoint_badge_url`. A fixture derived from the mechanism moves with the mechanism: point
# `BADGE_BRANCH` at a branch nothing is pushed to and a generated fixture would follow it, the check
# would still pass, and both badges would 404 in silence. Written as literals, the same edit fails
# here — which is the reminder that README.md carries these strings too and has to be edited with
# them.
FIXTURE_APP_BADGE_URL = (
    "https://img.shields.io/endpoint?url=https%3A%2F%2Fraw.githubusercontent.com"
    "%2Fsrpadrono%2Fmimic%2Fbadges%2Fapp-coverage.json"
)
FIXTURE_MODULE_BADGE_URL = (
    "https://img.shields.io/endpoint?url=https%3A%2F%2Fraw.githubusercontent.com"
    "%2Fsrpadrono%2Fmimic%2Fbadges%2Fmodule-coverage.json"
)

FIXTURE_README = f"""# Fixture

[![App Coverage]({FIXTURE_APP_BADGE_URL})](#coverage)
[![Module Coverage]({FIXTURE_MODULE_BADGE_URL})](#coverage)

Prose that must survive untouched.

<!-- coverage:generated:start -->
<!-- coverage:generated:end -->

Trailing prose.
"""

# What the README looked like before the badges were published — kept as a fixture because it is
# exactly what `check_badges` has to refuse, and because it is what a reader will find in this
# repository's history.
FIXTURE_README_WITH_STATIC_BADGES = """# Fixture

[![App Coverage](https://img.shields.io/badge/Mimic.app%20coverage-not%20measured-lightgrey)](#coverage)
[![Module Coverage](https://img.shields.io/badge/modules%20at%20or%20above%2095%25-not%20measured-lightgrey)](#coverage)

<!-- coverage:generated:start -->
<!-- coverage:generated:end -->
"""


def self_test() -> int:
    """Check the Mac-free half: the badge URLs, the badge payloads, the JSON round trip, the block
    rewriter and every refusal.

    This is the only automated coverage the file has. The bundle-reading half needs `xcrun xccov`
    and a real `.xcresult`, so it is exercised only by the macOS job; everything below runs in a
    tenth of a second on the Linux gate alongside the other checkers.

    Every expected value here is written out longhand. Nothing asks a function under test what the
    right answer is — the badge URLs, the payload dictionaries and the colour ladder are all pinned
    to literals, so reverting any of those mechanisms turns this red instead of moving the fixture
    along with the bug.
    """
    import tempfile

    failures: list[str] = []

    def check(condition: bool, message: str) -> None:
        if not condition:
            failures.append(message)

    # ---- the URLs, pinned to the strings README.md carries -------------------------------------
    check(
        endpoint_badge_url(APP_BADGE_FILE) == FIXTURE_APP_BADGE_URL,
        "the app badge URL is not the one README.md links",
    )
    check(
        endpoint_badge_url(MODULE_BADGE_FILE) == FIXTURE_MODULE_BADGE_URL,
        "the module badge URL is not the one README.md links",
    )
    check(
        raw_url("app-coverage.json")
        == "https://raw.githubusercontent.com/srpadrono/mimic/badges/app-coverage.json",
        "the raw URL is not where the badges branch publishes",
    )
    # Not a fixture, a consistency assertion: whatever `--print-badge-branch` tells the workflow to
    # force-push to has to be the branch the URL above reads from, or CI publishes to one place and
    # shields.io fetches from another.
    check(
        f"%2F{BADGE_BRANCH}%2F" in FIXTURE_APP_BADGE_URL,
        "--print-badge-branch names a branch the badge URL does not read from",
    )

    # ---- the colour ladder, at every boundary --------------------------------------------------
    for percent, expected_color in [
        (100.0, "brightgreen"),
        (95.0, "brightgreen"),
        (94.99, "green"),
        (90.0, "green"),
        (89.99, "yellow"),
        (80.0, "yellow"),
        (79.99, "red"),
        (0.0, "red"),
    ]:
        check(
            badge_color(percent) == expected_color,
            f"badge_color({percent}) is not {expected_color}",
        )

    app = CoverageMetrics(percent=41.5, covered_lines=1_000, executable_lines=2_409)
    modules = [
        ("Domain.framework", CoverageMetrics(percent=96.0, covered_lines=960, executable_lines=1_000)),
        ("ControlPlane.framework", CoverageMetrics(percent=80.25, covered_lines=321, executable_lines=400)),
    ]

    # ---- the payloads, as whole dictionaries ---------------------------------------------------
    # Compared whole rather than key by key, so a fifth key appearing — a timestamp, a run URL, a
    # `cacheSeconds` — fails here. shields.io ignores what it does not know, so an extra field would
    # never show up on the badge; it would only make the payload stop being a pure function of the
    # figures.
    check(
        badge_payloads(app, modules)
        == {
            "app-coverage.json": {
                "schemaVersion": 1,
                "label": "Mimic.app coverage",
                "message": "41.50%",
                "color": "red",
            },
            "module-coverage.json": {
                "schemaVersion": 1,
                "label": "modules at or above 95%",
                # One of two modules clears 95%, and 50% of them is red on the same ladder.
                "message": "1/2",
                "color": "red",
            },
        },
        "the badge payloads are not the two shields.io endpoint documents expected",
    )

    # ---- the block rewriter --------------------------------------------------------------------
    rendered = render_readme(
        FIXTURE_README, app, modules, generated_from="From a fixture.", provenance="Fixture note."
    )
    check("`Domain.framework` | `96.00%` | `960/1,000`" in rendered, "a module row is missing or misformatted")
    check("- Modules at or above `95%`: `1/2`." in rendered, "the at-or-above-95 count is wrong in the block")
    check("Prose that must survive untouched." in rendered, "prose outside the markers was lost")
    check("Trailing prose." in rendered, "prose after the block was lost")
    check(rendered.count("coverage:generated:start") == 1, "the start marker was duplicated or dropped")
    check(rendered.count("coverage:generated:end") == 1, "the end marker was duplicated or dropped")
    # The badges are published, not written: a local full-suite run must leave them exactly as it
    # found them, or the next person to run the suite commits a static badge over the live one.
    check(FIXTURE_APP_BADGE_URL in rendered, "the app badge was rewritten by the local writer")
    check(FIXTURE_MODULE_BADGE_URL in rendered, "the module badge was rewritten by the local writer")
    check("41.50%25" not in rendered, "the local writer baked a figure into a badge URL")

    # Idempotence: rewriting the *rendered* README with the same figures has to produce the same
    # bytes. Nothing in CI depends on that any more — the badge branch is force-pushed whatever it
    # says — but a human commits this block, and a full-suite run that dirties the tree on identical
    # figures is a diff nobody can review.
    again = render_readme(
        rendered, app, modules, generated_from="From a fixture.", provenance="Fixture note."
    )
    check(again == rendered, "rewriting with unchanged figures produced a different README")

    # ---- the JSON round trip, and out the other side as files ----------------------------------
    with tempfile.TemporaryDirectory() as tmp:
        json_path = Path(tmp) / "coverage.json"
        json_path.write_text(
            json.dumps(
                {
                    "app": {"name": "Mimic.app", **asdict(app)},
                    "modules": [{"name": name, **asdict(metrics)} for name, metrics in modules],
                }
            )
        )
        round_tripped_app, round_tripped_modules = metrics_from_json(json_path)
        check(round_tripped_app == app, "the app figures did not survive the JSON round trip")
        check(round_tripped_modules == modules, "the module figures did not survive the JSON round trip")

        badge_dir = Path(tmp) / "badges"
        written = write_badges(badge_dir, round_tripped_app, round_tripped_modules)
        check(
            sorted(path.name for path in written) == ["app-coverage.json", "module-coverage.json"],
            "--emit-badges wrote something other than the two payload files",
        )
        check(
            json.loads((badge_dir / "app-coverage.json").read_text())
            == {
                "schemaVersion": 1,
                "label": "Mimic.app coverage",
                "message": "41.50%",
                "color": "red",
            },
            "the app payload on disk is not the document shields.io expects",
        )
        check(
            (badge_dir / "module-coverage.json").read_text().endswith("}\n"),
            "a payload was written without a trailing newline",
        )

        json_path.write_text("{\"app\": {}}")
        try:
            metrics_from_json(json_path)
            failures.append("a malformed payload was accepted")
        except RuntimeError:
            pass

        json_path.write_text(json.dumps({"app": {"name": "Mimic.app", **asdict(app)}, "modules": []}))
        try:
            metrics_from_json(json_path)
            failures.append("a payload carrying no modules was accepted")
        except RuntimeError:
            pass

    # ---- the refusals --------------------------------------------------------------------------
    try:
        split_workspace_metrics({"Domain.framework": app})
        failures.append("a report missing eight of nine targets was accepted")
    except RuntimeError as error:
        check("Mimic.app" in str(error), "the refusal does not name what was missing")

    try:
        render_readme("# No badges here", app, modules, generated_from="x", provenance="y")
        failures.append("a README with no badges was accepted")
    except RuntimeError:
        pass

    try:
        render_readme(
            FIXTURE_README_WITH_STATIC_BADGES, app, modules, generated_from="x", provenance="y"
        )
        failures.append("a README still carrying the old static badges was accepted")
    except RuntimeError as error:
        check(APP_BADGE_FILE in str(error), "the refusal does not name the payload the README must link")

    for failure in failures:
        print(f"  FAIL {failure}")
    print(
        "update_readme_coverage self-test: "
        + ("all checks passed." if not failures else f"{len(failures)} failure(s).")
    )
    return 1 if failures else 0


def main() -> None:
    parser = argparse.ArgumentParser(
        description=(
            "Read coverage from .xcresult bundles: rewrite the README's generated block, print a "
            "Markdown report, or write the two shields.io endpoint payloads CI publishes."
        )
    )
    parser.add_argument(
        "--readme", default="README.md", help="Path to README.md (--results-dir mode)"
    )
    parser.add_argument(
        "--results-dir",
        help=(
            "Directory of per-scheme bundles, as Scripts/run_full_test_suite.sh produces. Rewrites "
            "the README's generated block. Never touches the badges."
        ),
    )
    parser.add_argument(
        "--result-bundle",
        help="A single .xcresult. Prints a Markdown report on stdout and edits nothing.",
    )
    parser.add_argument(
        "--emit-json",
        help="With --result-bundle: write the figures to this path instead of printing them.",
    )
    parser.add_argument(
        "--from-json",
        help="A file written by --emit-json. Needs no Xcode. Requires --emit-badges.",
    )
    parser.add_argument(
        "--emit-badges",
        help=(
            "With --from-json: write the two shields.io endpoint payloads into this directory, for "
            "the workflow to force-push to the badges branch."
        ),
    )
    parser.add_argument(
        "--print-badge-branch",
        action="store_true",
        help="Print the branch the badge payloads are published to, and exit.",
    )
    parser.add_argument(
        "--self-test",
        action="store_true",
        help="Check the badge payloads, the rewriter and the JSON round trip. Needs no Xcode.",
    )
    parser.add_argument("--title", default="Code coverage", help="Heading for --result-bundle output.")
    args = parser.parse_args()

    modes = [
        bool(args.results_dir),
        bool(args.result_bundle),
        bool(args.from_json),
        args.print_badge_branch,
        args.self_test,
    ]
    if sum(modes) != 1:
        parser.error(
            "pass exactly one of --results-dir, --result-bundle, --from-json, "
            "--print-badge-branch or --self-test"
        )
    if args.emit_json and not args.result_bundle:
        parser.error("--emit-json only means something with --result-bundle")
    if args.emit_badges and not args.from_json:
        parser.error("--emit-badges only means something with --from-json")
    # `--from-json` used to rewrite README.md, and refusing it without `--emit-badges` is what stops
    # a caller written against that shape from silently doing nothing. The README's generated block
    # is written by `--results-dir` and by nothing else now.
    if args.from_json and not args.emit_badges:
        parser.error("--from-json needs --emit-badges: it no longer writes the README")

    if args.self_test:
        raise SystemExit(self_test())

    if args.print_badge_branch:
        print(BADGE_BRANCH)
        return

    if args.from_json:
        app_metrics, module_metrics = metrics_from_json(Path(args.from_json).resolve())
        for path in write_badges(Path(args.emit_badges).resolve(), app_metrics, module_metrics):
            print(f"{path}\n{path.read_text()}", end="")
        return

    if args.result_bundle:
        bundle = Path(args.result_bundle).resolve()
        if args.emit_json:
            # Raises rather than printing a reason and exiting 1, unlike `report_one_bundle` above:
            # nobody is reading this step's stdout as a report, and the caller wants a file or a
            # failure. The workflow marks the step `continue-on-error`, so the failure surfaces as a
            # warning and the badges go on showing whatever was last published.
            emit_json(bundle, Path(args.emit_json).resolve())
            return
        raise SystemExit(report_one_bundle(bundle, args.title))

    update_readme(Path(args.readme).resolve(), Path(args.results_dir).resolve())


if __name__ == "__main__":
    main()

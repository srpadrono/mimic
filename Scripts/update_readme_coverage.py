#!/usr/bin/env python3

"""Reads line coverage out of `.xcresult` bundles. Two modes, one reader.

**`--results-dir`** is the mode `Scripts/run_full_test_suite.sh` uses: one bundle per scheme, on a
Mac, after a full suite run. It rewrites README.md's two coverage badges and the block between the
`coverage:generated` markers, in place.

**`--result-bundle`** is the mode `.github/workflows/ci.yml` uses: one bundle — the workspace-wide
unit run — printed as Markdown on stdout and appended to the job summary. It reads the bundle and
changes nothing, so it is safe on a pull request from a fork, where the token is read-only and a
README rewrite could not be committed anyway.

Both modes go through `target_metrics`, so the numbers a reviewer reads in a job summary and the
numbers a Mac writes into the README come out of one piece of code rather than two that agree by
hand.

Stdlib only, so the Linux CI container's `python3-minimal` and a Mac's system Python both run it.
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
from dataclasses import dataclass
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


def build_coverage_block(app_metrics: CoverageMetrics, module_metrics: list[tuple[str, CoverageMetrics]]) -> str:
    lines = [
        "<!-- coverage:generated:start -->",
        "This section is auto-generated from the latest coverage-enabled `.xcresult` bundles produced by `./Scripts/run_full_test_suite.sh`.",
        "",
        "Latest measured coverage from the most recent successful full-suite run:",
        "",
        "| Target | Coverage | Lines |",
        "| --- | ---: | ---: |",
        f"| `Mimic.app` | `{format_percent(app_metrics.percent)}` | `{format_lines(app_metrics)}` |",
    ]

    for target_name, metrics in module_metrics:
        lines.append(f"| `{target_name}` | `{format_percent(metrics.percent)}` | `{format_lines(metrics)}` |")

    modules_at_or_above_95 = sum(1 for _, metrics in module_metrics if metrics.percent >= 95.0)
    total_executable_lines = app_metrics.executable_lines + sum(metrics.executable_lines for _, metrics in module_metrics)
    lines.extend(
        [
            "",
            "Coverage notes:",
            "",
            f"- App coverage is currently `{format_percent(app_metrics.percent)}`.",
            f"- Modules at or above `95%`: `{modules_at_or_above_95}/{len(module_metrics)}`.",
            f"- Total executable lines tracked in this table: `{total_executable_lines:,}`.",
            "- `Lines` shows covered/executable lines reported by `xcrun xccov`.",
            "- Coverage is gathered with `xcodebuild` and `xcrun xccov` from fresh `.xcresult` bundles.",
            "- The macOS CI job measures the same thing per run and prints it in its job summary; these numbers are from whoever last ran the full suite on a Mac.",
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


def replace_badges(readme: str, app_percent: float, modules_at_or_above_95: int, module_count: int) -> str:
    app_badge = (
        f"[![App Coverage](https://img.shields.io/badge/Mimic.app%20coverage-"
        f"{app_percent:.2f}%25-{badge_color(app_percent)})](#coverage)"
    )
    modules_badge = (
        "[![Module Coverage](https://img.shields.io/badge/modules%20at%20or%20above%2095%25-"
        f"{modules_at_or_above_95}%2F{module_count}-{badge_color(100.0 * modules_at_or_above_95 / module_count)})](#coverage)"
    )

    # `re.sub` with no match returns the string unchanged and raises nothing, so when the README
    # carried no coverage badges at all this function was a guaranteed silent no-op: the full suite
    # ran, the script exited 0, `run_full_test_suite.sh` printed "README coverage section updated."
    # and neither badge had ever existed. `replace_coverage_block` above defends itself; this did not.
    readme, replaced = re.subn(r"\[!\[App Coverage\]\([^)]+\)\]\(#coverage\)", app_badge, readme, count=1)
    if replaced != 1:
        raise RuntimeError("README.md is missing the App Coverage badge.")
    readme, replaced = re.subn(r"\[!\[Module Coverage\]\([^)]+\)\]\(#coverage\)", modules_badge, readme, count=1)
    if replaced != 1:
        raise RuntimeError("README.md is missing the Module Coverage badge.")
    return readme


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


def update_readme(readme_path: Path, results_dir: Path) -> None:
    app_metrics = metrics_for_target(results_dir / APP_TARGET[2], APP_TARGET[1])

    module_metrics: list[tuple[str, CoverageMetrics]] = []
    for display_name, xccov_name, filename in MODULE_TARGETS:
        module_metrics.append((display_name, metrics_for_target(results_dir / filename, xccov_name)))

    readme = readme_path.read_text()
    modules_at_or_above_95 = sum(1 for _, metrics in module_metrics if metrics.percent >= 95.0)
    readme = replace_badges(readme, app_metrics.percent, modules_at_or_above_95, len(module_metrics))
    readme = replace_coverage_block(readme, build_coverage_block(app_metrics, module_metrics))
    readme_path.write_text(readme)


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Read coverage from .xcresult bundles: rewrite README, or print a Markdown report."
    )
    parser.add_argument("--readme", default="README.md", help="Path to README.md (--results-dir mode only)")
    parser.add_argument(
        "--results-dir",
        help="Directory of per-scheme bundles, as Scripts/run_full_test_suite.sh produces. Rewrites the README.",
    )
    parser.add_argument(
        "--result-bundle",
        help="A single .xcresult. Prints a Markdown report on stdout and edits nothing.",
    )
    parser.add_argument("--title", default="Code coverage", help="Heading for --result-bundle output.")
    args = parser.parse_args()

    if bool(args.results_dir) == bool(args.result_bundle):
        parser.error("pass exactly one of --results-dir or --result-bundle")

    if args.result_bundle:
        raise SystemExit(report_one_bundle(Path(args.result_bundle).resolve(), args.title))

    update_readme(Path(args.readme).resolve(), Path(args.results_dir).resolve())


if __name__ == "__main__":
    main()

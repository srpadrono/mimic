#!/usr/bin/env python3

from __future__ import annotations

import argparse
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
    # AppFeatures has no standalone test scheme; its coverage is captured in the app test run.
    ("AppFeatures.framework", "AppFeatures.framework", "MimicApp.xcresult"),
]


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


def extract_coverage_metrics(report: str, target_name: str) -> CoverageMetrics:
    pattern = re.compile(
        rf"^\s*\d+\s+{re.escape(target_name)}\s+\d+\s+([0-9]+\.[0-9]+)% \(([0-9]+)/([0-9]+)\)",
        re.MULTILINE,
    )
    match = pattern.search(report)
    if not match:
        raise RuntimeError(f"Could not find target '{target_name}' in xccov report.")
    return CoverageMetrics(
        percent=float(match.group(1)),
        covered_lines=int(match.group(2)),
        executable_lines=int(match.group(3)),
    )


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
            "<!-- coverage:generated:end -->",
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

    readme = re.sub(r"\[!\[App Coverage\]\([^)]+\)\]\(#coverage\)", app_badge, readme, count=1)
    readme = re.sub(r"\[!\[Module Coverage\]\([^)]+\)\]\(#coverage\)", modules_badge, readme, count=1)
    return readme


def main() -> None:
    parser = argparse.ArgumentParser(description="Update README coverage badges and section from xcresult bundles.")
    parser.add_argument("--readme", default="README.md", help="Path to README.md")
    parser.add_argument("--results-dir", required=True, help="Directory containing coverage result bundles")
    args = parser.parse_args()

    readme_path = Path(args.readme).resolve()
    results_dir = Path(args.results_dir).resolve()

    app_report = run_xccov(results_dir / APP_TARGET[2])
    app_metrics = extract_coverage_metrics(app_report, APP_TARGET[1])

    module_metrics: list[tuple[str, CoverageMetrics]] = []
    for display_name, xccov_name, filename in MODULE_TARGETS:
        report = run_xccov(results_dir / filename)
        module_metrics.append((display_name, extract_coverage_metrics(report, xccov_name)))

    readme = readme_path.read_text()
    modules_at_or_above_95 = sum(1 for _, metrics in module_metrics if metrics.percent >= 95.0)
    readme = replace_badges(readme, app_metrics.percent, modules_at_or_above_95, len(module_metrics))
    readme = replace_coverage_block(readme, build_coverage_block(app_metrics, module_metrics))
    readme_path.write_text(readme)


if __name__ == "__main__":
    main()

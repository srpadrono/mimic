#!/usr/bin/env python3

"""Read coverage without running tests or inferring whether a test run passed.

--result-bundle prints a report; --emit-json requires the app and all eight modules.
CI merges its unit and UI result bundles before exporting those figures. The Linux
publisher uses --from-json --emit-badges to write two shields.io endpoint payloads
on the orphan badges branch. --print-badge-branch exposes that branch contract.

--results-dir writes only README's generated table from existing per-scheme bundles,
as the CI-only run_full_test_suite.sh produces. It does not publish badges. Reports
describe their input bundles; neither timestamps nor badge freshness are inferred.

--self-test uses literal fixtures for parsers, denominators, payloads and refusals.
This script uses only the standard library available in python3-minimal.
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


# CI publishes only badge payloads on a separate branch; it never writes the protected main branch.
BADGE_REPO = "srpadrono/mimic"
BADGE_BRANCH = "badges"
APP_BADGE_FILE = "app-coverage.json"
MODULE_BADGE_FILE = "module-coverage.json"

# Preserve the published URL even though its payload aggregates the app and all eight modules.
TOTAL_BADGE_LABEL = "line coverage"
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


def validated_metrics(percent: object, covered: object, executable: object) -> CoverageMetrics:
    """Use counts as the authority; tolerate only the text report's percentage rounding."""
    if type(covered) is not int or type(executable) is not int:
        raise ValueError("line counts must be integers")
    if not 0 <= covered <= executable:
        raise ValueError("line counts must satisfy 0 <= covered <= executable")
    if type(percent) not in (int, float) or not 0 <= percent <= 100:
        raise ValueError("coverage percentage must be finite and between 0 and 100")
    actual = 100.0 * covered / executable if executable else 0.0
    if abs(percent - actual) > 0.00501:
        raise ValueError("coverage percentage disagrees with line counts")
    return CoverageMetrics(actual, covered, executable)


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


def parse_xccov_json(report_text: str) -> dict[str, CoverageMetrics]:
    report = json.loads(report_text)
    # --only-targets returns an array; a full --report JSON object wraps it in targets.
    targets = report.get("targets") if isinstance(report, dict) else report
    if not isinstance(targets, list):
        raise ValueError("coverage targets must be an array")
    metrics = {}
    for target in targets:
        if not isinstance(target, dict):
            raise ValueError("each coverage target must be an object")
        name = target["name"]
        fraction = target["lineCoverage"]
        if not isinstance(name, str) or not name or name in metrics:
            raise ValueError("coverage target names must be nonempty and unique")
        if type(fraction) not in (int, float) or not 0 <= fraction <= 1:
            raise ValueError("lineCoverage must be finite and between 0 and 1")
        metrics[name] = validated_metrics(
            100.0 * fraction, target["coveredLines"], target["executableLines"]
        )
    return metrics


def parse_xccov_text(report_text: str) -> dict[str, CoverageMetrics]:
    metrics = {}
    for match in TEXT_ROW.finditer(report_text):
        name = match.group("name")
        if name in metrics:
            raise ValueError("coverage target names must be unique")
        metrics[name] = validated_metrics(
            float(match.group("percent")),
            int(match.group("covered")),
            int(match.group("executable")),
        )
    return metrics


def target_metrics(result_bundle: Path) -> dict[str, CoverageMetrics]:
    """Every target in one bundle, keyed by the name `xccov` reports it under.

    Prefer named JSON fields; keep the text fallback for older xccov versions.
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
            return parse_xccov_json(completed.stdout)
        except (json.JSONDecodeError, KeyError, TypeError, ValueError):
            pass

    try:
        report_text = run_xccov(result_bundle)
    except subprocess.CalledProcessError as error:
        detail = (error.stderr or "").strip() or f"exit {error.returncode}"
        raise RuntimeError(f"`xcrun xccov` could not read {result_bundle}: {detail}") from error

    try:
        return parse_xccov_text(report_text)
    except ValueError as error:
        raise RuntimeError(f"invalid coverage report for {result_bundle}: {error}") from error


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
        "Line coverage in the supplied result bundles:",
        "",
        "| Target | Coverage | Lines |",
        "| --- | ---: | ---: |",
        f"| `Mimic.app` | `{format_percent(app_metrics.percent)}` | `{format_lines(app_metrics)}` |",
    ]

    for target_name, metrics in module_metrics:
        lines.append(f"| `{target_name}` | `{format_percent(metrics.percent)}` | `{format_lines(metrics)}` |")

    at_or_above = modules_at_or_above_95(module_metrics)
    total = total_metrics(app_metrics, module_metrics)
    target_count = len(module_metrics) + 1
    lines.append(f"| **All {target_count} measured targets** | **`{format_percent(total.percent)}`** | **`{format_lines(total)}`** |")
    lines.extend(
        [
            "",
            "Coverage notes:",
            "",
            f"- Total line coverage across the {target_count} measured targets is `{format_percent(total.percent)}`.",
            f"- `Mimic.app` is the app *bundle* target: `App/Sources/MimicApp.swift`, the `@main` "
            f"entry point, currently `{format_percent(app_metrics.percent)}` of "
            f"`{app_metrics.executable_lines:,}` executable lines. The application itself is "
            "`AppFeatures`.",
            f"- Modules at or above `95%`: `{at_or_above}/{len(module_metrics)}`.",
            f"- Total executable lines tracked in this table: `{total.executable_lines:,}`.",
            "- `Lines` shows covered/executable lines reported by `xcrun xccov`.",
            "- Coverage is read with `xcrun xccov`; these figures do not establish test success.",
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

    products = [metrics[name] for name in SUMMARY_ORDER
                if name in metrics and metrics[name].executable_lines > 0]
    covered = sum(entry.covered_lines for entry in products)
    executable = sum(entry.executable_lines for entry in products)
    lines.append("")
    if executable:
        lines.append(
            f"**Measured Mimic targets ({len(products)}/{len(SUMMARY_ORDER)}): "
            f"{format_percent(100.0 * covered / executable)}** "
            f"({covered:,}/{executable:,} lines)."
        )
    if any(name not in SUMMARY_ORDER for name in metrics):
        lines.append(
            "Test bundles and dependency targets are shown separately and excluded from the Mimic total."
        )
    lines.extend(
        [
            "",
            "No coverage floor is enforced. Coverage measurements do not establish test success "
            "or verify user-visible behavior.",
        ]
    )
    return "\n".join(lines)


def replace_coverage_block(readme: str, new_block: str) -> str:
    if any(readme.count(marker) != 1 for marker in (
        "<!-- coverage:generated:start -->", "<!-- coverage:generated:end -->"
    )):
        raise RuntimeError("README.md must contain exactly one pair of coverage generation markers.")
    pattern = re.compile(
        r"<!-- coverage:generated:start -->.*?<!-- coverage:generated:end -->",
        re.DOTALL,
    )
    if not pattern.search(readme):
        raise RuntimeError("README.md is missing coverage generation markers.")
    return pattern.sub(lambda _: new_block, readme, count=1)


def modules_at_or_above_95(module_metrics: list[tuple[str, CoverageMetrics]]) -> int:
    return sum(1 for _, metrics in module_metrics if metrics.percent >= 95.0)


def total_metrics(
    app_metrics: CoverageMetrics, module_metrics: list[tuple[str, CoverageMetrics]]
) -> CoverageMetrics:
    """All nine targets as one figure: covered lines over executable lines, not a mean of percents.

    A mean would weight `ControlPlane`'s 413 lines the same as `AppFeatures`' 17,848 and produce a
    number that describes nothing. Summing the two counts and dividing once is the only honest
    aggregate, and it is what a reader assumes a coverage badge already is.

    **Summing across targets is sound, and it looks like the thing the workflow refuses to do.** It
    is not the same operation. Merging four *test runs* cannot be done by adding, because a line the
    unit suites reach and a UI test also reaches is one covered line in the union and adding counts
    it twice — that is why `.github/workflows/ci.yml` merges the result bundles instead. These nine
    targets are disjoint sets of source files, measured in one already-merged report, so no line
    appears in two of them and the sum is exact.
    """
    covered = app_metrics.covered_lines + sum(m.covered_lines for _, m in module_metrics)
    executable = app_metrics.executable_lines + sum(m.executable_lines for _, m in module_metrics)
    if executable == 0:
        raise RuntimeError("the coverage figures carry no executable lines at all.")
    return CoverageMetrics(
        percent=100.0 * covered / executable,
        covered_lines=covered,
        executable_lines=executable,
    )


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
    total = total_metrics(app_metrics, module_metrics)
    return {
        APP_BADGE_FILE: {
            "schemaVersion": 1,
            "label": TOTAL_BADGE_LABEL,
            "message": format_percent(total.percent),
            "color": badge_color(total.percent),
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

    if not any(metrics[name].executable_lines > 0 for name in SUMMARY_ORDER if name in metrics):
        print(
            f"### {title}\n\nNot reported: `xcrun xccov` read `{result_bundle}` and found no Mimic "
            "product target with executable lines. Either the test run was not built with "
            "`-enableCodeCoverage YES`, or the scheme gathers coverage for no target."
        )
        return 1

    print(build_summary(result_bundle, metrics, title))
    return 0


FULL_SUITE_GENERATED_FROM = (
    "It is written from existing coverage-enabled `.xcresult` bundles, one per scheme."
)
FULL_SUITE_PROVENANCE = (
    "This table describes the supplied per-scheme runs. Badges describe the latest successfully "
    "published main-branch CI coverage, merging unit and UI runs. Different revisions and test "
    "selections can produce different figures; neither report proves the other's freshness."
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

    app_metrics, module_metrics = split_workspace_metrics(
        {APP_TARGET[0]: app_metrics, **dict(module_metrics)}
    )

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

    Refuse missing or unmeasured targets so the published denominator cannot shrink.
    """
    wanted = [APP_TARGET[1]] + [xccov_name for _, xccov_name, _ in MODULE_TARGETS]
    missing = [name for name in wanted if name not in metrics]
    if missing:
        found = ", ".join(sorted(metrics)) or "no targets at all"
        raise RuntimeError(
            f"the report is missing {', '.join(missing)} — it has {found}. Refusing to write a "
            "partial coverage table."
        )
    unmeasured = [name for name in wanted if metrics[name].executable_lines == 0]
    if unmeasured:
        raise RuntimeError(f"the report has no executable lines for {', '.join(unmeasured)}")
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
        app = payload["app"]
        modules = payload["modules"]
        if app["name"] != APP_TARGET[0] or not isinstance(modules, list):
            raise ValueError("expected Mimic.app and a module list")
        expected_modules = {name for name, _, _ in MODULE_TARGETS}
        names = [entry["name"] for entry in modules]
        if len(names) != len(expected_modules) or set(names) != expected_modules:
            raise ValueError("expected each of the eight Mimic modules exactly once")
        metrics = {
            entry["name"]: validated_metrics(
                entry["percent"], entry["covered_lines"], entry["executable_lines"]
            )
            for entry in [app, *modules]
        }
    except (json.JSONDecodeError, KeyError, TypeError, ValueError) as error:
        raise RuntimeError(f"{json_path} is not a coverage payload this script wrote: {error}") from error

    return split_workspace_metrics(metrics)


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

# The publication boundary requires all nine named products. Keep this input independent
# of MODULE_TARGETS and the serializer so a missing or renamed target fails the contract.
FIXTURE_COVERAGE_JSON = """{
  "app": {"name": "Mimic.app", "percent": 50, "covered_lines": 50, "executable_lines": 100},
  "modules": [
    {"name": "Domain.framework", "percent": 95, "covered_lines": 95, "executable_lines": 100},
    {"name": "MockServerEngine.framework", "percent": 96, "covered_lines": 96, "executable_lines": 100},
    {"name": "Persistence.framework", "percent": 97, "covered_lines": 97, "executable_lines": 100},
    {"name": "DesignSystem.framework", "percent": 98, "covered_lines": 98, "executable_lines": 100},
    {"name": "SpecImport.framework", "percent": 99, "covered_lines": 99, "executable_lines": 100},
    {"name": "ControlPlane.framework", "percent": 100, "covered_lines": 100, "executable_lines": 100},
    {"name": "MimicCLICore.framework", "percent": 94, "covered_lines": 94, "executable_lines": 100},
    {"name": "AppFeatures.framework", "percent": 93, "covered_lines": 93, "executable_lines": 100}
  ]
}"""


def self_test() -> int:
    """Exercise parsing and publication with literal fixtures; no Xcode or test run required."""
    import tempfile

    failures: list[str] = []

    def check(condition: bool, message: str) -> None:
        if not condition:
            failures.append(message)

    def refuses(operation, message: str, error_type=RuntimeError) -> None:
        try:
            operation()
            failures.append(message)
        except error_type:
            pass

    parsed = parse_xccov_json('''{"targets": [
        {"name": "Mimic.app", "lineCoverage": 0.5, "coveredLines": 50, "executableLines": 100},
        {"name": "Domain.framework", "lineCoverage": 0.96, "coveredLines": 96, "executableLines": 100}
    ]}''')
    check(parsed == {
        "Mimic.app": CoverageMetrics(50.0, 50, 100),
        "Domain.framework": CoverageMetrics(96.0, 96, 100),
    }, "the xccov JSON parser changed the reported target metrics")
    target_array = '''[
        {"name": "Algorithms.framework", "lineCoverage": 0, "coveredLines": 0, "executableLines": 566},
        {"name": "Mimic.app", "lineCoverage": 0.5, "coveredLines": 50, "executableLines": 100}
    ]'''
    check(parse_xccov_json(target_array) == {
        "Algorithms.framework": CoverageMetrics(0, 0, 566),
        "Mimic.app": CoverageMetrics(50, 50, 100),
    }, "the actual --only-targets JSON array shape was not parsed")

    # Exercise the reader boundary: valid JSON must not silently fall back to rounded text.
    commands = []

    def fixture_xccov(command, **_):
        commands.append(command)
        check("--json" in command, "a valid --only-targets JSON array triggered text fallback")
        return subprocess.CompletedProcess(command, 0, stdout=target_array, stderr="")

    with tempfile.TemporaryDirectory() as tmp:
        bundle = Path(tmp) / "Fixture.xcresult"
        bundle.mkdir()
        original_run = subprocess.run
        subprocess.run = fixture_xccov
        try:
            read_metrics = target_metrics(bundle)
        finally:
            subprocess.run = original_run
        check(read_metrics == {
            "Algorithms.framework": CoverageMetrics(0, 0, 566),
            "Mimic.app": CoverageMetrics(50, 50, 100),
        }, "the reader did not return the literal JSON array metrics")
        check(commands == [["xcrun", "xccov", "view", "--report", "--only-targets", "--json", str(bundle)]],
              "the JSON reader made an unexpected command or fallback call")
    for invalid_report in [
        '{"targets": {}}', 'null', '[null]',
        '{"targets":[{"name":"Mimic.app","lineCoverage":NaN,"coveredLines":0,"executableLines":100}]}',
        '{"targets":[{"name":"Mimic.app","lineCoverage":true,"coveredLines":100,"executableLines":100}]}',
        '{"targets":[{"name":"Mimic.app","lineCoverage":1,"coveredLines":1,"executableLines":100}]}',
        '''{"targets":[
            {"name":"Mimic.app","lineCoverage":0.5,"coveredLines":1,"executableLines":2},
            {"name":"Mimic.app","lineCoverage":1,"coveredLines":2,"executableLines":2}
        ]}''',
    ]:
        refuses(lambda: parse_xccov_json(invalid_report),
                "invalid or duplicate xccov JSON metrics were accepted", ValueError)
    text_metrics = parse_xccov_text("1 Domain.framework 12 95.00% (94999/100000)\n")
    check(text_metrics["Domain.framework"] == CoverageMetrics(94.999, 94999, 100000),
          "the text parser did not derive its percentage from line counts")
    check(modules_at_or_above_95(list(text_metrics.items())) == 0,
          "a rounded text percentage incorrectly cleared the 95% threshold")
    refuses(lambda: parse_xccov_text("Domain.framework 100.00% (1/100)"),
            "contradictory xccov text metrics were accepted", ValueError)
    refuses(lambda: parse_xccov_text("Domain.framework 50.00% (1/2)\nDomain.framework 100.00% (2/2)"),
            "duplicate xccov text targets were accepted", ValueError)
    for percent, covered, executable in [
        (100, True, 1), (50, 1.5, 3), (50, "1", 2), (0, -1, 10),
        (100, 11, 10), (0, 0, -1), (float("nan"), 0, 1),
        (float("inf"), 1, 1), (True, 1, 100), (100, 1, 100),
    ]:
        refuses(lambda: validated_metrics(percent, covered, executable),
                f"invalid metrics were accepted: {percent}, {covered}, {executable}", ValueError)

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

    app = CoverageMetrics(percent=41.51, covered_lines=1_000, executable_lines=2_409)
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
                "label": "line coverage",
                # The weighted total, computed by hand from the fixtures above and written out as a
                # literal: (1,000 + 960 + 321) / (2,409 + 1,000 + 400) = 2,281 / 3,809 = 59.8845…%.
                # Deliberately *not* the mean of 41.5, 96.0 and 80.25 — that is 72.58%, and a badge
                # showing it would be weighting a 400-line module the same as a 2,409-line one.
                # Deliberately not `app.percent` either, which is 41.50% and is what this badge used
                # to publish about a thirty-four-line entry point.
                "message": "59.88%",
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
    # The same literal as the badge fixture above, and the point of pinning it in both places is that
    # the block and the badge must not be able to disagree: a reader who checks one against the other
    # is doing what this row exists for.
    check(
        "| **All 3 measured targets** | **`59.88%`** | **`2,281/3,809`** |" in rendered,
        "the total row is missing, or is not the weighted total of the rows above it",
    )
    check(
        "Total line coverage across the 3 measured targets is `59.88%`" in rendered,
        "the block does not state the figure the first badge publishes",
    )
    check("Prose that must survive untouched." in rendered, "prose outside the markers was lost")
    check("Trailing prose." in rendered, "prose after the block was lost")
    check(rendered.count("coverage:generated:start") == 1, "the start marker was duplicated or dropped")
    check(rendered.count("coverage:generated:end") == 1, "the end marker was duplicated or dropped")
    # Rewriting the optional table must preserve the published endpoint URLs.
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
    check(replace_coverage_block(FIXTURE_README, r"literal\path\1")
          == FIXTURE_README.replace(
              "<!-- coverage:generated:start -->\n<!-- coverage:generated:end -->", r"literal\path\1"),
          "the block writer interpreted backslashes as replacement syntax")
    refuses(lambda: replace_coverage_block(FIXTURE_README + FIXTURE_README, "replacement"),
            "duplicate marker pairs were accepted")
    report = build_summary(Path("fixture.xcresult"), {
        "Mimic.app": app, **dict(modules),
        "Persistence.framework": CoverageMetrics(0, 0, 0),
        "Dependency.framework": CoverageMetrics(100, 10000, 10000),
        "DomainTests.xctest": CoverageMetrics(100, 10000, 10000),
    }, "Fixture")
    check("**Measured Mimic targets (3/9): 59.88%** (2,281/3,809 lines)." in report,
          "the report included test or dependency lines in the Mimic total")

    # ---- the JSON round trip, and out the other side as files ----------------------------------
    with tempfile.TemporaryDirectory() as tmp:
        json_path = Path(tmp) / "coverage.json"
        json_path.write_text(FIXTURE_COVERAGE_JSON)
        round_tripped_app, round_tripped_modules = metrics_from_json(json_path)
        check(round_tripped_app == CoverageMetrics(50, 50, 100), "the app figures did not survive the JSON hand-off")
        check(round_tripped_modules == [
            ("Domain.framework", CoverageMetrics(95, 95, 100)),
            ("MockServerEngine.framework", CoverageMetrics(96, 96, 100)),
            ("Persistence.framework", CoverageMetrics(97, 97, 100)),
            ("DesignSystem.framework", CoverageMetrics(98, 98, 100)),
            ("SpecImport.framework", CoverageMetrics(99, 99, 100)),
            ("ControlPlane.framework", CoverageMetrics(100, 100, 100)),
            ("MimicCLICore.framework", CoverageMetrics(94, 94, 100)),
            ("AppFeatures.framework", CoverageMetrics(93, 93, 100)),
        ], "the module identities or figures did not survive the JSON hand-off")

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
                "label": "line coverage",
                "message": "91.33%",
                "color": "green",
            },
            "the app payload on disk is not the document shields.io expects",
        )
        check(
            json.loads((badge_dir / "module-coverage.json").read_text()) == {
                "schemaVersion": 1,
                "label": "modules at or above 95%",
                "message": "6/8",
                "color": "red",
            },
            "the module payload does not retain the full denominator",
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

        for defect in ("missing", "duplicate", "unknown", "wrong-app", "unmeasured", "contradictory"):
            payload = json.loads(FIXTURE_COVERAGE_JSON)
            if defect == "missing":
                payload["modules"].pop()
            elif defect == "duplicate":
                payload["modules"][-1] = payload["modules"][0]
            elif defect == "unknown":
                payload["modules"][-1]["name"] = "Dependency.framework"
            elif defect == "wrong-app":
                payload["app"]["name"] = "Other.app"
            elif defect == "unmeasured":
                payload["modules"][0].update(percent=0, covered_lines=0, executable_lines=0)
            elif defect == "contradictory":
                payload["modules"][0]["percent"] = 100
            json_path.write_text(json.dumps(payload))
            refuses(lambda: metrics_from_json(json_path), f"a {defect} publication payload was accepted")

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

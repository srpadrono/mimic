#!/usr/bin/env python3
"""Enforce compiler parity for every portable target, without invoking a toolchain.

The manifests use literal target names, settings arrays and build-setting values. Unsupported
expressions fail instead of being treated as absent settings. Xcode's approachable-concurrency
umbrella adds two features in Swift 6; its other features are already language defaults.
"""

import os
import pathlib
import re
import sys

from check_module_edges import balanced_span, strip_comments, target_definitions

ROOT = pathlib.Path(__file__).resolve().parent.parent
APPROACHABLE_FEATURES = {"InferIsolatedConformances", "NonisolatedNonsendingByDefault"}
FEATURE_SETTINGS = {
    "SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY": "MemberImportVisibility",
    "SWIFT_UPCOMING_FEATURE_INFER_ISOLATED_CONFORMANCES": "InferIsolatedConformances",
    "SWIFT_UPCOMING_FEATURE_NONISOLATED_NONSENDING_BY_DEFAULT": "NonisolatedNonsendingByDefault",
}
KNOWN_SETTINGS = set(FEATURE_SETTINGS) | {
    "SWIFT_VERSION", "SWIFT_DEFAULT_ACTOR_ISOLATION", "SWIFT_APPROACHABLE_CONCURRENCY",
    "MACOSX_DEPLOYMENT_TARGET",
}
FEATURE_CALL = re.compile(r'\.enableUpcomingFeature\s*\(\s*"([^"\n]+)"\s*\)')


def normalized_version(text):
    parts = [int(p) for p in re.findall(r"\d+", text)]
    while len(parts) > 1 and parts[-1] == 0:
        parts.pop()
    return tuple(parts)


def build_settings(text):
    result = {}
    for field in re.finditer(r'"(SWIFT_[A-Z_0-9]+|MACOSX_DEPLOYMENT_TARGET)"\s*:\s*', text):
        value = re.match(r'"([^"\n]*)"', text[field.end():])
        if value is None:
            raise ValueError(f"{field.group(1)} must use a literal build-setting value")
        if field.group(1) in result:
            raise ValueError(f"duplicate build setting {field.group(1)}")
        result[field.group(1)] = value.group(1)
    return result


def features_in(array):
    features = set(FEATURE_CALL.findall(array))
    remainder = FEATURE_CALL.sub("", array)
    if re.sub(r"[\s,\[\]]", "", remainder):
        raise ValueError("unsupported Swift settings; declare unconditional upcoming features explicitly")
    return features


def package_features(package, targets):
    shared = {}
    for declaration in re.finditer(r"\blet\s+(\w+)\s*:\s*\[SwiftSetting\]\s*=\s*\[", package):
        start = declaration.end() - 1
        shared[declaration.group(1)] = features_in(package[start:balanced_span(package, start)])
    result = {}
    for name, body in targets.items():
        field = re.search(r"\bswiftSettings\s*:\s*", body)
        if field is None:
            result[name] = set()
        elif body[field.end()] == "[":
            start = field.end()
            result[name] = features_in(body[start:balanced_span(body, start)])
        else:
            reference = re.match(r"(\w+)\s*(?:,|\))", body[field.end():])
            if reference is None or reference.group(1) not in shared:
                raise ValueError(f"{name}: swiftSettings must reference a declared [SwiftSetting] array")
            result[name] = shared[reference.group(1)]
    return result


def macos_floor(package):
    match = re.search(r'\.macOS\(\s*(?:"([0-9.]+)"|\.v([0-9_]+))\s*\)', package)
    if match is None:
        raise ValueError("missing literal .macOS(...) deployment floor")
    return normalized_version(match.group(1) or match.group(2))


def disagreements(project_text, package_text, tuist_package_text):
    project, package, tuist_package = map(strip_comments, (project_text, package_text, tuist_package_text))
    shared_call = re.search(r"\blet\s+sharedSettings\b[^=]*=\s*\.settings\s*\(", project)
    if shared_call is None:
        raise ValueError("Project.swift: missing sharedSettings declaration")
    start = shared_call.end() - 1
    shared = build_settings(project[start:balanced_span(project, start)])
    floor = normalized_version(shared.get("MACOSX_DEPLOYMENT_TARGET", ""))
    if not floor:
        raise ValueError("Project.swift: missing shared MACOSX_DEPLOYMENT_TARGET")

    problems = []
    for name, manifest in (("Package.swift", package), ("Tuist/Package.swift", tuist_package)):
        if macos_floor(manifest) != floor:
            problems.append(f"{name}: deployment floor differs from Project.swift")
    tools = re.search(r"^//\s*swift-tools-version:\s*([0-9.]+)", package_text)
    if tools is None or normalized_version(tools.group(1)) < (6, 2):
        problems.append("Package.swift: Swift 6.2 or newer is required for these upcoming features")
    if re.search(r"\bswiftLanguageModes\s*:\s*\[\s*\.v6\s*,?\s*\]", package) is None:
        problems.append("Package.swift: explicitly declare swiftLanguageModes: [.v6]")

    portable, xcode = target_definitions(package), target_definitions(project)
    if not portable:
        raise ValueError("Package.swift: no targets found")
    enabled = package_features(package, portable)
    for name in portable:
        xcode_name = "MimicCLI" if name == "mimic" else name
        if xcode_name not in xcode:
            problems.append(f"{name}: no corresponding Tuist target {xcode_name}")
            continue
        effective = shared | build_settings(xcode[xcode_name])
        unknown = effective.keys() - KNOWN_SETTINGS
        if unknown:
            problems.append(f"{name}: unmapped Tuist settings: {', '.join(sorted(unknown))}")
        if normalized_version(effective.get("SWIFT_VERSION", ""))[:1] != (6,):
            problems.append(f"{name}: Tuist must use Swift 6 language mode")
        if effective.get("SWIFT_DEFAULT_ACTOR_ISOLATION") != "none":
            problems.append(f"{name}: Tuist default actor isolation differs from SwiftPM's nonisolated default")
        if normalized_version(effective.get("MACOSX_DEPLOYMENT_TARGET", "")) != floor:
            problems.append(f"{name}: target deployment floor differs from Package.swift")
        expected = set()
        approachable = effective.get("SWIFT_APPROACHABLE_CONCURRENCY", "NO")
        if approachable not in {"YES", "NO"}:
            problems.append(f"{name}: unsupported approachable-concurrency value {approachable!r}")
        elif approachable == "YES":
            expected |= APPROACHABLE_FEATURES
        for setting, feature in FEATURE_SETTINGS.items():
            if setting not in effective:
                continue
            value = effective[setting]
            if value == "YES":
                expected.add(feature)
            elif value == "NO":
                expected.discard(feature)
            else:
                problems.append(f"{name}: unsupported {setting} value {value!r}")
        missing, extra = expected - enabled[name], enabled[name] - expected
        if missing:
            problems.append(f"{name}: SwiftPM is missing {', '.join(sorted(missing))}")
        if extra:
            problems.append(f"{name}: SwiftPM enables features absent from Tuist: {', '.join(sorted(extra))}")
    return problems


def self_test():
    project = '''let sharedSettings: Settings = .settings(base: [
        "SWIFT_VERSION": "6.2", "SWIFT_DEFAULT_ACTOR_ISOLATION": "MainActor",
        "SWIFT_APPROACHABLE_CONCURRENCY": "YES",
        "SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY": "YES",
        "MACOSX_DEPLOYMENT_TARGET": "26.0"], configurations: [])
    let project = Project(targets: [.target(name: "Domain", dependencies: [],
        settings: .settings(base: ["SWIFT_DEFAULT_ACTOR_ISOLATION": "none"]))])'''
    package = '''// swift-tools-version: 6.2
    let flags: [SwiftSetting] = [.enableUpcomingFeature("MemberImportVisibility"),
        .enableUpcomingFeature("InferIsolatedConformances"),
        .enableUpcomingFeature("NonisolatedNonsendingByDefault")]
    let package = Package(platforms: [.macOS("26.0")], targets: [
        .target(name: "Domain", swiftSettings: flags)], swiftLanguageModes: [.v6])'''
    cases = [
        (project, package, False),
        (project, package.replace(", swiftSettings: flags", ""), True),
        (project, package.replace('.enableUpcomingFeature("MemberImportVisibility"),',
                                 '// .enableUpcomingFeature("MemberImportVisibility"),'), True),
        (project, package.replace('"NonisolatedNonsendingByDefault"', '"OtherFeature"'), True),
        (project.replace('"none"', '"MainActor"'), package, True),
        (project.replace('"SWIFT_VERSION": "6.2"', '"SWIFT_VERSION": "5.0"'), package, True),
        (project, package.replace('swiftLanguageModes: [.v6]', 'swiftLanguageModes: [.v5]'), True),
    ]
    for index, (tuist, spm, should_fail) in enumerate(cases):
        if bool(disagreements(tuist, spm, 'Package(platforms: [.macOS("26.0")])')) != should_fail:
            raise AssertionError(f"compiler parity fixture {index} gave the wrong result")
    print(f"{len(cases)} compiler-parity fixtures passed")


def main():
    try:
        if sys.argv[1:] == ["--self-test"]:
            self_test()
        elif sys.argv[1:]:
            raise ValueError("usage: check_compiler_settings.py [--self-test]")
        problems = disagreements(*((ROOT / path).read_text(encoding="utf-8") for path in
                                    ("Project.swift", "Package.swift", "Tuist/Package.swift")))
    except (OSError, ValueError) as error:
        sys.exit(f"Compiler parity could not be checked: {error}")
    for problem in problems:
        prefix = "::error file=Package.swift::" if os.environ.get("GITHUB_ACTIONS") else "ERROR: "
        print(prefix + problem)
    if problems:
        sys.exit(f"{len(problems)} compiler-setting disagreement(s)")
    print("All portable targets match Tuist's Swift 6 language mode, isolation and upcoming features; deployment floors agree.")


if __name__ == "__main__":
    main()

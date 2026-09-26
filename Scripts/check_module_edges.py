#!/usr/bin/env python3
"""Check transitive module boundaries in both SwiftPM and Tuist manifests.

The CLI must remain a client without Vapor, GRDB, or SpecImport. ControlPlane
must not acquire SpecImport, Persistence, or MockServerEngine. Required edges
make a parser that has stopped seeing dependencies fail instead of passing.
Print the path of any forbidden reachability. Stdlib only.
"""

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent

# (manifest, root target, forbidden module, why the documents say so)
FORBIDDEN = [
    ("Package.swift", "ControlPlane", "SpecImport", "spec import has no HTTP control command"),
    ("Package.swift", "MimicCLICore", "SpecImport", "there is no `mimic import`"),
    ("Package.swift", "mimic", "SpecImport", "there is no `mimic import`"),
    ("Package.swift", "MimicCLICore", "Vapor", "the CLI is a client, never a host"),
    ("Package.swift", "MimicCLICore", "GRDB", "the CLI is a client, never a host"),
    ("Package.swift", "mimic", "Vapor", "the CLI is a client, never a host"),
    ("Package.swift", "mimic", "GRDB", "the CLI is a client, never a host"),
    ("Project.swift", "ControlPlane", "SpecImport", "spec import has no HTTP control command"),
    ("Project.swift", "MimicCLICore", "SpecImport", "there is no `mimic import`"),
    ("Project.swift", "MimicCLI", "SpecImport", "there is no `mimic import`"),
    ("Project.swift", "MimicCLICore", "Vapor", "the CLI is a client, never a host"),
    ("Project.swift", "MimicCLICore", "GRDB", "the CLI is a client, never a host"),
    ("Project.swift", "MimicCLI", "Vapor", "the CLI is a client, never a host"),
    ("Project.swift", "MimicCLI", "GRDB", "the CLI is a client, never a host"),
    # The owner resolved the two-host fork by deleting `MimicControlService` and `MimicDaemon` —
    # the module's only users of a store and an engine. ControlPlane is the HTTP layer and the
    # discovery file over the `ControlHost` protocol; the host is supplied by the app. An edge onto
    # either module reappearing means a second host is growing back, which is a decision to argue
    # (docs/ARCHITECTURE.md, "One rule and one host"), not a dependency to add in passing.
    ("Package.swift", "ControlPlane", "Persistence", "ControlPlane holds no host of its own"),
    ("Package.swift", "ControlPlane", "MockServerEngine", "ControlPlane holds no host of its own"),
    ("Project.swift", "ControlPlane", "Persistence", "ControlPlane holds no host of its own"),
    ("Project.swift", "ControlPlane", "MockServerEngine", "ControlPlane holds no host of its own"),
]

# (manifest, target, direct dependency). These are what make the absences above mean something:
# each of the three forbidden module names is required to appear on some edge in the same manifest,
# so a parser that stopped seeing `.external(name:)`, `.product(name:)` or the bare-string shorthand
# cannot report a clean tree.
REQUIRED_EDGES = [
    ("Package.swift", "MimicCLICore", "Domain"),
    ("Package.swift", "MimicCLICore", "ArgumentParser"),
    ("Package.swift", "mimic", "MimicCLICore"),
    ("Package.swift", "ControlPlane", "Vapor"),
    # The forbidden list above says Persistence and MockServerEngine must not appear under
    # ControlPlane, so something must prove the parser still sees those names at all — otherwise a
    # parser gone blind to a dependency shape reports the absences as compliance. `AppFeatures`
    # carries both edges in Project.swift; Package.swift declares no app-level targets, so there the
    # proof is each module's own test target, which necessarily names it.
    ("Package.swift", "PersistenceTests", "Persistence"),
    ("Package.swift", "MockServerEngineTests", "MockServerEngine"),
    ("Package.swift", "Persistence", "GRDB"),
    ("Package.swift", "SpecImportTests", "SpecImport"),
    ("Project.swift", "MimicCLICore", "Domain"),
    ("Project.swift", "MimicCLICore", "ArgumentParser"),
    ("Project.swift", "MimicCLI", "MimicCLICore"),
    ("Project.swift", "ControlPlane", "Vapor"),
    ("Project.swift", "AppFeatures", "Persistence"),
    ("Project.swift", "AppFeatures", "MockServerEngine"),
    ("Project.swift", "Persistence", "GRDB"),
    ("Project.swift", "AppFeatures", "SpecImport"),
]


def strip_comments(text):
    """Remove line and nested block comments, preserving strings and line boundaries."""
    out, i, n, in_string = [], 0, len(text), False
    while i < n:
        c = text[i]
        if in_string:
            out.append(c)
            if c == "\\" and i + 1 < n:
                out.append(text[i + 1])
                i += 2
                continue
            if c == '"':
                in_string = False
            i += 1
            continue
        if c == '"':
            in_string = True
            out.append(c)
            i += 1
            continue
        if c == "/" and text.startswith("//", i):
            while i < n and text[i] != "\n":
                i += 1
            continue
        if text.startswith("/*", i):
            depth = 1
            i += 2
            out.append(" ")
            while i < n and depth:
                if text.startswith("/*", i):
                    depth += 1
                    i += 2
                elif text.startswith("*/", i):
                    depth -= 1
                    i += 2
                else:
                    if text[i] == "\n":
                        out.append("\n")
                    i += 1
            if depth:
                raise ValueError("unterminated block comment")
            continue
        out.append(c)
        i += 1
    return "".join(out)


def balanced_span(text, open_index):
    """The index just past the bracket that closes the one at `open_index`, ignoring strings."""
    pairs = {"(": ")", "[": "]"}
    stack, i, n, in_string = [], open_index, len(text), False
    while i < n:
        c = text[i]
        if in_string:
            if c == "\\":
                i += 2
                continue
            if c == '"':
                in_string = False
        elif c == '"':
            in_string = True
        elif c in pairs:
            stack.append(pairs[c])
        elif c in (")", "]"):
            if not stack or c != stack.pop():
                raise ValueError(f"mismatched bracket at offset {i}")
            if not stack:
                return i + 1
        i += 1
    raise ValueError(f"unbalanced bracket opened at offset {open_index}")


TARGET_CALL = re.compile(r"\.(?:executableTarget|testTarget|target)\s*\(")
NAME_FIELD = re.compile(r'^\(\s*name:\s*"([^"]+)"')
DEPENDENCIES_FIELD = re.compile(r"\bdependencies:\s*\[")
# `.product(name: "Vapor", package: "vapor")`, `.target(name: "Domain")`, `.external(name: "GRDB")`.
# The product/target/external *name* is the first `name:` in the call; the `package:` that follows a
# product is the repository, not a module, and naming it here would invent an edge onto "grdb.swift".
QUALIFIED_DEPENDENCY = re.compile(r'\.(?:product|target|external|byName)\s*\(\s*name:\s*"([^"]+)"')
BARE_DEPENDENCY = re.compile(r'"([^"]+)"')


def dependencies_of(target_body):
    """Every module named in one target's `dependencies:` array."""
    match = DEPENDENCIES_FIELD.search(target_body)
    if not match:
        if re.search(r"\bdependencies\s*:", target_body):
            raise ValueError("dependencies must use a literal array for the boundary check")
        return []
    open_index = match.end() - 1
    body = target_body[open_index:balanced_span(target_body, open_index)]

    names, remainder = [], []
    cursor = 0
    for call in QUALIFIED_DEPENDENCY.finditer(body):
        names.append(call.group(1))
        span_end = balanced_span(body, body.index("(", call.start()))
        remainder.append(body[cursor:call.start()])
        cursor = span_end
    remainder.append(body[cursor:])
    # Whatever is left is SwiftPM's bare-string shorthand: `dependencies: ["Domain"]`.
    remainder = "".join(remainder)
    names += BARE_DEPENDENCY.findall(remainder)
    if re.sub(r"[\s,\[\]]", "", BARE_DEPENDENCY.sub("", remainder)):
        raise ValueError("unsupported dependency expression in target manifest")
    return names


def target_definitions(text):
    """Return the literal body of every target declaration.

    Only *declarations* — a match that starts inside the span of one already taken is skipped.
    Tuist spells a dependency `.target(name: "Domain")`, the same call the declaration uses, so
    without that guard every referenced target is re-declared with an empty dependency list by
    whatever mentions it last: `MockServerEngine` came back with no edges at all because
    `MockServerEngineTests` names it. Which is to say the naive version answered "nothing depends on
    Vapor" — a clean bill of health, arrived at by seeing nothing.
    """
    text = strip_comments(text)
    targets, taken_until = {}, 0
    for call in TARGET_CALL.finditer(text):
        if call.start() < taken_until:
            continue
        open_index = call.end() - 1
        end = balanced_span(text, open_index)
        body = text[open_index:end]
        name = NAME_FIELD.search(body)
        if not name:
            # Tuist schemes refer to an existing target with `.target("Mimic")`.
            if re.match(r'^\(\s*"[^"\n]+"\s*\)$', body):
                continue
            raise ValueError("target declarations must begin with a literal name")
        if name.group(1) in targets:
            raise ValueError(f"duplicate target {name.group(1)}")
        targets[name.group(1)] = body
        taken_until = end
    return targets


def graph(manifest):
    return {name: dependencies_of(body) for name, body in
            target_definitions((ROOT / manifest).read_text()).items()}


def path_to(edges, start, goal):
    """The first path from `start` to `goal` through the declared targets, or None."""
    queue, seen = [(start, [start])], {start}
    while queue:
        node, trail = queue.pop(0)
        for dependency in edges.get(node, []):
            if dependency == goal:
                return trail + [dependency]
            if dependency not in seen:
                seen.add(dependency)
                queue.append((dependency, trail + [dependency]))
    return None


def source_disagreements(portable, xcode):
    """The two build systems must compile the same directory for each portable target."""
    problems = []
    for name, body in portable.items():
        xcode_name = "MimicCLI" if name == "mimic" else name
        path = re.search(r'\bpath:\s*"([^"\n]+)"', body)
        other = xcode.get(xcode_name, "")
        folders = re.search(r"\bbuildableFolders:\s*\[", other)
        if path is None or folders is None:
            problems.append(f"{name}: missing literal source directory in one manifest")
            continue
        start = folders.end() - 1
        folder_names = BARE_DEPENDENCY.findall(other[start:balanced_span(other, start)])
        if folder_names != [path.group(1)]:
            problems.append(f"{name}: SwiftPM source {path.group(1)!r} differs from Tuist {folder_names!r}")
    return problems


def self_test():
    fixture = '''let targets = [
        /* ignored .target(name: "Fake", dependencies: ["Vapor"]) /* nested */ */
        .target(name: "Domain", path: "Sources/Domain", dependencies: []),
        .target(name: "Client", dependencies: [.target(name: "Domain"),
            .product(name: "ArgumentParser", package: "https://example.com/parser")])]
        let scheme = .target("Client") // reference, not a declaration
    '''
    definitions = target_definitions(fixture)
    edges = {name: dependencies_of(body) for name, body in definitions.items()}
    cases = [
        edges == {"Domain": [], "Client": ["Domain", "ArgumentParser"]},
        path_to({"Client": ["Helper"], "Helper": ["Client", "Vapor"]}, "Client", "Vapor")
            == ["Client", "Helper", "Vapor"],
        not source_disagreements({"Domain": '(name: "Domain", path: "Sources/Domain")'},
                                 {"Domain": '(name: "Domain", buildableFolders: ["Sources/Domain"])'}),
        bool(source_disagreements({"Domain": '(name: "Domain", path: "Sources/Other")'},
                                  {"Domain": '(name: "Domain", buildableFolders: ["Sources/Domain"])'})),
    ]
    for invalid in (
        '.target(name: "Domain") .target(name: "Domain")',
        '.target(name: variableName)',
        '/* unterminated',
        '.target(name: "Domain", dependencies: ["Vapor"))',
    ):
        try:
            target_definitions(invalid)
        except ValueError:
            cases.append(True)
        else:
            cases.append(False)
    for invalid in ('(name: "Domain", dependencies: shared)',
                    '(name: "Domain", dependencies: [shared])'):
        try:
            dependencies_of(invalid)
        except ValueError:
            cases.append(True)
        else:
            cases.append(False)
    if not all(cases):
        raise AssertionError(f"module-boundary fixtures failed: {[i for i, passed in enumerate(cases) if not passed]}")
    print(f"{len(cases)} module-boundary fixtures passed")


def main():
    try:
        if sys.argv[1:] == ["--self-test"]:
            self_test()
        elif sys.argv[1:]:
            raise ValueError("usage: check_module_edges.py [--self-test]")
        graphs = {name: graph(name) for name in ("Package.swift", "Project.swift")}
        problems = source_disagreements(
            target_definitions((ROOT / "Package.swift").read_text(encoding="utf-8")),
            target_definitions((ROOT / "Project.swift").read_text(encoding="utf-8")),
        )
    except (OSError, ValueError) as error:
        sys.exit(f"Module boundaries could not be checked: {error}")

    for manifest, target, dependency in REQUIRED_EDGES:
        edges = graphs[manifest]
        if target not in edges:
            problems.append(f"{manifest}: no target named {target} — this check has gone blind")
        elif dependency not in edges[target]:
            problems.append(
                f"{manifest}: {target} no longer depends on {dependency}. If that is intended, "
                f"the absences this program checks stop meaning anything until it is updated."
            )

    for manifest, root, forbidden, why in FORBIDDEN:
        edges = graphs[manifest]
        if root not in edges:
            problems.append(f"{manifest}: no target named {root} — this check has gone blind")
            continue
        found = path_to(edges, root, forbidden)
        if found:
            problems.append(
                f"{manifest}: {' -> '.join(found)} — {root} must not reach {forbidden} ({why}). "
                "See docs/ARCHITECTURE.md for the module contract."
            )

    for line in problems:
        print(line)
    if problems:
        sys.exit(f"{len(problems)} module-edge problem(s) — see "
                 "docs/ARCHITECTURE.md \"Modules\" for the boundaries this enforces")

    print(f"{len(FORBIDDEN)} forbidden edges absent, {len(REQUIRED_EDGES)} required edges present, "
          f"across {len(graphs['Package.swift'])} SwiftPM and {len(graphs['Project.swift'])} Tuist targets")


if __name__ == "__main__":
    main()

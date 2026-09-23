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
    """Blanks `//` comments without ever cutting inside a string literal.

    `Package.swift` carries four `.package(url: "https://…")` lines, so the naive substitution cuts
    every one of them in half and takes the dependency list with it. Neither manifest contains a
    `/* */` block comment (`grep -n '/\\*' Package.swift Project.swift` finds none), so this only
    knows about `//` — if one appears, this has to learn about it.
    """
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
        out.append(c)
        i += 1
    return "".join(out)


def balanced_span(text, open_index):
    """The index just past the bracket that closes the one at `open_index`, ignoring strings."""
    pairs = {"(": ")", "[": "]"}
    closer = pairs[text[open_index]]
    depth, i, n, in_string = 0, open_index, len(text), False
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
            depth += 1
        elif c in (")", "]"):
            depth -= 1
            if depth == 0:
                if c != closer:
                    raise ValueError(f"mismatched bracket at offset {i}")
                return i + 1
        i += 1
    raise ValueError(f"unbalanced bracket opened at offset {open_index}")


TARGET_CALL = re.compile(r"\.(?:executableTarget|testTarget|target)\s*\(")
NAME_FIELD = re.compile(r'\bname:\s*"([^"]+)"')
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
    names += BARE_DEPENDENCY.findall("".join(remainder))
    return names


def graph(manifest):
    """`{target: [dependency, …]}` for every target the manifest declares.

    Only *declarations* — a match that starts inside the span of one already taken is skipped.
    Tuist spells a dependency `.target(name: "Domain")`, the same call the declaration uses, so
    without that guard every referenced target is re-declared with an empty dependency list by
    whatever mentions it last: `MockServerEngine` came back with no edges at all because
    `MockServerEngineTests` names it. Which is to say the naive version answered "nothing depends on
    Vapor" — a clean bill of health, arrived at by seeing nothing.
    """
    text = strip_comments((ROOT / manifest).read_text())
    edges, taken_until = {}, 0
    for call in TARGET_CALL.finditer(text):
        if call.start() < taken_until:
            continue
        open_index = call.end() - 1
        end = balanced_span(text, open_index)
        body = text[open_index:end]
        name = NAME_FIELD.search(body)
        if not name:
            continue
        edges[name.group(1)] = dependencies_of(body)
        taken_until = end
    return edges


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


def main():
    graphs = {name: graph(name) for name in ("Package.swift", "Project.swift")}
    problems = []

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
                f"Six documents state this edge does not exist; adding it makes all of them false."
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

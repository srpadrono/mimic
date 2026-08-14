#!/usr/bin/env python3
"""Recounts what the documentation hand-counts, and fails when the tree no longer agrees.

A handful of numbers in this repository are written by hand into prose and can only be checked by
counting something else. Most had drifted at least once before this file held them:

  - **The test counts.** README.md's Tests badge and its Testing table are hand-maintained, and the
    README says so — along with the fact that they have twice claimed a figure the tree did not
    support: 469 / 34 / 181 against an actual 487 / 49 / 173, and then 173 for the app row while a
    new parity suite was landing 13 more in the same afternoon. Its advice is "recount before you
    change them", followed by the two shell one-liners to do it with. This is those one-liners with
    the comparison written down, so that recounting is something that happens whether or not
    somebody remembers to.

  - **The operation count** — how many `CommandKind` cases the CLI and the control API expose. It is
    stated in five places across four documents, and `DomainTests` used to assert it with a literal
    that had to be hand-edited alongside them. That assertion was removed as a hand-maintained
    mirror of a fact the type system already knows; this recomputes it from the enum instead, which
    is the same removal done in the direction that cannot go stale. The journey library's two
    counts — templates on the shelf, match modes — are held the same way, recomputed from
    `JourneyTemplates.all` and `JourneyMatchMode`'s cases: they had never drifted, but nothing was
    recounting them, and a count nobody recounts is the state the operation count was in the day
    it went stale.

  - **The suites themselves**, which is a count of a different kind: a folder under `Tests/` that no
    build target names is a suite nobody runs. That is not hypothetical — `Project.swift` still
    carries the comment recording the mirror image of it, a `buildableFolders` line naming
    `Tests/JourneyFeatureTests` from the first commit with no directory behind it, which Tuist
    tolerated silently while the manifest read as though the journey UI had tests.

  - **The suites that bind a port**, which is a list rather than a number and is the shape of claim
    this repository keeps getting wrong. CONTRIBUTING.md and docs/ARCHITECTURE.md both name them in
    a parenthesis, and both named two for several waves while `MimicTests` was standing a real
    `ControlServer` up in `ComposedControlServerTests` — an enumeration presented as complete, gone
    stale in the direction nobody notices, since the sentence still reads fine. It is recomputed
    here from whatever in `Sources/` actually opens a listening socket, rather than from a list kept
    beside the prose.

It counts tests the way the README says it counts them: `@Test` declarations under `Tests/` and
`func test…` methods under `MimicUITests/`. A parameterized case runs many times and is one
declaration — the same convention the README states, and the reason this cannot be checked against a
test *run*.

These disagreements fail — deliberately not introduced as "four kinds" or "five", since a list in a
docstring is the same hand-maintained mirror the rest of this file exists to remove:

  - a stated number that no longer matches the tree;
  - a claim a document has stopped making at all, which would leave this check silently agreeing
    with nothing (the failure mode that lets a doc rot while its checker stays green);
  - a suite folder that exists on disk but appears in none of the README's groups, which is what a
    newly added suite looks like before anybody has written it into the table;
  - a suite folder that exists on disk and that neither manifest declares — or that a manifest
    declares and that does not exist;
  - a suite that binds a port and is missing from a document's list of the suites that bind a port,
    or named there without binding one;
  - `CommandKind` written in a shape that makes the count itself unreliable, because certifying a
    wrong number as right is worse than not checking.

It never edits a document. It prints the true numbers, in the shape the documents state them, so
whoever owns those files can paste them in.

Stdlib only. Paths resolve from this file's location, so it answers the same from anywhere.
`--self-test` is the one argument: it runs the port-binding comparison against fixtures written
inside this file and exits non-zero if any of them comes out wrong, which is how you check that the
comparison can still fail. Nothing in CI passes that flag today.
"""

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent

# How the README groups the suites. The names are the folder names under Tests/; the check asserts
# below that these three groups between them account for every folder that exists.
PORTABLE = ["DomainTests", "SpecImportTests", "MockServerEngineTests",
            "PersistenceTests", "MimicCLICoreTests", "ControlPlaneTests"]
DESIGN_SYSTEM = ["DesignSystemTests"]
APP = ["WorkspaceFeatureTests", "MimicTests", "ImportFeatureTests",
       "ProjectFeatureTests", "EndpointFeatureTests", "JourneyFeatureTests"]

# `@Test` at the start of a line (after indentation) is a Swift Testing declaration; `func testX(`
# is an XCTest one. Anchoring to the line start is what keeps a mention inside prose or a doc
# comment from counting — verified against this tree, where every `@Test` occurrence under Tests/ is
# a declaration and none appears mid-line or in a comment. The count itself is deliberately not
# written here: it is what this script computes, and a number in a comment beside it would be one
# more hand-maintained mirror to go stale.
SWIFT_TESTING = re.compile(r"^\s*@Test\b", re.M)
XCTEST = re.compile(r"^\s*(?:@MainActor\s+)?func test[A-Za-z0-9_]*\s*\(", re.M)

# The source of truth for the operation count, and the two manifests that decide which suites are
# built at all.
COMMAND_KIND = "Sources/Domain/Control/CommandKind.swift"
MANIFESTS = ["Package.swift", "Project.swift"]
# Where the port-binding check looks for a listener: production code only, so a test's own stub
# cannot nominate itself as a server type.
SOURCES = "Sources"
# The journey library's two other counted claims: the template shelf is the `all` array — the list
# `mimic journey templates` serves — and the match modes are `JourneyMatchMode`'s cases.
JOURNEY_TEMPLATES = "Sources/Domain/Journeys/JourneyTemplates.swift"
JOURNEY_MODEL = "Sources/Domain/Models/Journey.swift"
# The first path component after `Tests/` in either manifest. Every form the two use takes this
# shape — `path:` in Package.swift, `buildableFolders:` and `entitlements:` in Project.swift — and
# each of them is a target naming a directory it owns, which is the fact being looked for.
DECLARED_SUITE = re.compile(r'"Tests/([A-Za-z0-9_]+)')

# How a listening socket is opened anywhere in this tree: Vapor's `server.start(address:)`, which
# `MockServerEngine` and `ControlServer` each call once, both on `127.0.0.1`. Looking for the call
# rather than for a list of type names is what makes a *new* server type count without anybody
# adding it here — the failure this check exists to prevent, one level up.
BIND_CALL = re.compile(r"\bserver\.start\(address:")
# The declaration a bind sits inside. Both are top-level `public actor X {`; the pattern accepts the
# other declaration kinds so a type that changes shape is still found rather than silently dropped.
TYPE_DECLARATION = re.compile(r"^public (?:actor|struct|enum|(?:final )?class) ([A-Za-z0-9_]+)")
# The sentence both documents use, deliberately identical in shape so one pattern reads both. The
# names inside are backticked suite folders; the check compares that set, not its order.
PORT_SUITE_SENTENCE = re.compile(r"Suites that bind a port\s*\(([^)]*)\)")
PORT_SUITE_SITES = [
    ("CONTRIBUTING.md", "tests paragraph"),
    ("docs/ARCHITECTURE.md", "conventions list"),
]

# The documents this script reads. `.agents/skills/` is vendored from elsewhere and is not ours to
# hold to this repo's numbers. CHANGELOG.md is left out for a different and more important reason:
# a changelog records what was true at a release, so a checker that dragged it forward with the tree
# would be demanding that shipped history be rewritten every time a command is added.
DOCS = ["README.md", "AGENTS.md", "CLAUDE.md", "CONTRIBUTING.md", "SECURITY.md",
        "docs/ARCHITECTURE.md", "docs/CLI.md", "docs/GRAPHQL.md", "docs/JOURNEYS.md",
        "docs/ROADMAP.md", "docs/SECURITY-REVIEW.md"]

# Every place the operation count is written down, as (document, what it is, regex with one
# capturing group). The list came out of grepping the docs for the number rather than from anyone's
# memory of where it appears:
#
#     grep -rn --include='*.md' -E '\b47\b|forty-seven' .
#
# which is also how two entries turned out not to be sites at all. `docs/CLI.md` states no count —
# it documents the verbs one at a time — and README's *other* 47 was its Design system test-count
# row, which happened to equal the operation count on the day of that grep and has since moved on.
# No current value is quoted beside it here: this comment held the row's old number after the row
# changed, which is the drift the rest of this file exists to catch, caught in the checker itself.
# Those two near-misses are why every pattern below is anchored on the words around the number
# rather than on the number.
#
# One genuine mention is deliberately absent: AGENTS.md quotes the deleted assertion
# `CommandKind.allCases.count == 47` while explaining why it was deleted. That literal was correct
# when the assertion existed, and holding a sentence about a removed test to today's count would be
# asking for history to be edited — the same objection that keeps CHANGELOG.md out of DOCS above.
OPERATION_CLAIMS = [
    ("README.md", "control API expose", r"control API expose (\d+) operations"),
    ("AGENTS.md", "CommandCatalog surface", r"expose the ([a-z]+(?:-[a-z]+)?) operations in `CommandCatalog`"),
    ("AGENTS.md", "one CLI verb per kind", r"maps onto exactly one `CommandKind` case — (\d+) of them"),
    ("docs/ROADMAP.md", "automation row", r"control API covering (\d+) operations"),
    ("docs/ARCHITECTURE.md", "testing platform", r"testing platform: (\d+) operations"),
]

# The template and match-mode sites, found the same way — grepping the docs for the number — and
# anchored on the words around it for the same reason.
TEMPLATE_CLAIMS = [
    ("README.md", "template shelf", r"([A-Za-z-]+|\d+) templates cover the flows"),
    ("docs/ROADMAP.md", "journeys row", r"restart and loop, ([a-z-]+|\d+) templates"),
]
MATCH_MODE_CLAIMS = [
    ("docs/ROADMAP.md", "journeys row", r"sequences, ([a-z-]+|\d+) match modes"),
]

# Spelled-out numbers, because AGENTS.md writes the count as "forty-seven" — prose in that position
# reads badly as a digit, and a document is allowed to say a number in words. Built rather than
# listed, so the parser and the printed suggestion cannot disagree about what 47 is called.
_UNITS = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
          "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen",
          "eighteen", "nineteen"]
_TENS = ["twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety"]
WORD_NUMBERS = {word: value for value, word in enumerate(_UNITS)}
for _i, _ten in enumerate(_TENS):
    WORD_NUMBERS[_ten] = 20 + 10 * _i
    for _j, _unit in enumerate(_UNITS[1:10], start=1):
        WORD_NUMBERS[f"{_ten}-{_unit}"] = 20 + 10 * _i + _j
NUMBER_WORDS = {value: word for word, value in WORD_NUMBERS.items()}

# The net for a *new* site. OPERATION_CLAIMS fails when a known claim goes stale or vanishes; this
# fails when somebody writes the number down in a sixth place and it is wrong there. Digits, or a
# hyphenated spelled-out number — never a bare word, because docs/GRAPHQL.md says "Two operations on
# the same route are not treated as duplicates" and is not talking about the command surface.
OPERATIONS_MENTION = re.compile(r"\b(\d+|[a-z]+-[a-z]+)\s+operations\b", re.I)

# The same nets for the other two counts. These accept a bare spelled-out word where the pattern
# above refuses one, because their genuine sites are bare words ("Nine templates") and the false
# positives ("journey templates", "built-in templates") are not numbers at all, so `as_number`
# already drops them.
TEMPLATES_MENTION = re.compile(r"\b(\d+|[A-Za-z]+(?:-[A-Za-z]+)?)\s+templates\b")
MATCH_MODES_MENTION = re.compile(r"\b(\d+|[A-Za-z]+(?:-[A-Za-z]+)?)\s+match modes\b")


def count(directory, pattern):
    total = 0
    for file in sorted((ROOT / directory).rglob("*.swift")):
        total += len(pattern.findall(file.read_text()))
    return total


def suite_counts():
    return {d.name: count(f"Tests/{d.name}", SWIFT_TESTING)
            for d in sorted((ROOT / "Tests").iterdir()) if d.is_dir()}


def operation_count():
    r"""How many cases `CommandKind` declares, counted the way AGENTS.md tells a reader to count it.

    AGENTS.md hands out this pipeline to confirm the figure:

        awk '/^public enum CommandKind/,/^}/' Sources/Domain/Control/CommandKind.swift \
          | grep -c '^    case '

    so this reproduces it rather than parsing Swift a second, cleverer way. A checker that counted
    differently from the command the documentation publishes would leave two answers in play, which
    is the whole failure this file exists to remove. awk's range is inclusive and ends on the first
    line that begins `}` — the enum's own closing brace, reached before `CommandScope` further down
    the same file declares `case project` and `case host` at the same indentation.

    Returns the count and any reason the count cannot be trusted, because both the pipeline above
    and this function count *lines*: a day when somebody writes `case a, b` on one line is a day
    both of them undercount, and a wrong number certified as right is worse than no check.
    """
    lines = (ROOT / COMMAND_KIND).read_text().splitlines()
    start = next(i for i, line in enumerate(lines) if line.startswith("public enum CommandKind"))
    end = next(i for i, line in enumerate(lines[start + 1:], start + 1) if line.startswith("}"))
    cases = [line for line in lines[start:end + 1] if line.startswith("    case ")]

    problems = []
    if not cases:
        problems.append(f"{COMMAND_KIND}: no `case` lines between the enum declaration and its "
                        "closing brace — the awk range AGENTS.md documents has stopped working")
    for line in (c for c in cases if "," in c):
        problems.append(f"{COMMAND_KIND}: `{line.strip()}` declares more than one case on a line, "
                        "so this check and the awk pipeline in AGENTS.md both undercount — put one "
                        "case per line, or teach both to count differently")
    return len(cases), problems


def template_count():
    """How many templates `JourneyTemplates.all` exposes.

    Counted from the `all` array rather than from the `Template(` constructors beside it, because
    the array is what `mimic journey templates` serves: a template defined in the file but left out
    of `all` is not on the shelf, and the shelf is what the documents count. Line-based like
    `operation_count`, and with the same distrust of a line that lists two.
    """
    lines = (ROOT / JOURNEY_TEMPLATES).read_text().splitlines()
    start = next((i for i, line in enumerate(lines)
                  if re.search(r"static let all: \[Template\] = \[", line)), None)
    if start is None:
        return 0, [f"{JOURNEY_TEMPLATES}: no `static let all: [Template]` array — the template "
                   "count cannot be recomputed, so it cannot be checked"]

    entries = []
    for line in lines[start + 1:]:
        stripped = line.strip()
        if stripped.startswith("]"):
            break
        if stripped and not stripped.startswith("//"):
            entries.append(stripped)

    problems = []
    if not entries:
        problems.append(f"{JOURNEY_TEMPLATES}: the `all` array is empty or unreadable — a wrong "
                        "number certified as right is worse than no check")
    for entry in (e for e in entries if "," in e.rstrip(",")):
        problems.append(f"{JOURNEY_TEMPLATES}: `{entry}` lists more than one template on a line, "
                        "so this check undercounts — put one per line, or teach it to count "
                        "differently")
    return len(entries), problems


def match_mode_count():
    """`JourneyMatchMode`'s cases, counted by the same line rule as `operation_count`."""
    lines = (ROOT / JOURNEY_MODEL).read_text().splitlines()
    start = next((i for i, line in enumerate(lines)
                  if line.startswith("public enum JourneyMatchMode")), None)
    if start is None:
        return 0, [f"{JOURNEY_MODEL}: no `public enum JourneyMatchMode` declaration — the "
                   "match-mode count cannot be recomputed, so it cannot be checked"]
    end = next(i for i, line in enumerate(lines[start + 1:], start + 1) if line.startswith("}"))
    cases = [line for line in lines[start:end + 1] if line.startswith("    case ")]

    problems = []
    if not cases:
        problems.append(f"{JOURNEY_MODEL}: no `case` lines between `JourneyMatchMode` and its "
                        "closing brace — the range this counts over has stopped working")
    for line in (c for c in cases if "," in c):
        problems.append(f"{JOURNEY_MODEL}: `{line.strip()}` declares more than one case on a line, "
                        "so this check undercounts — put one case per line, or teach it to count "
                        "differently")
    return len(cases), problems


def declared_suites():
    """Folders under `Tests/` that a build target names, and which manifest names each.

    The union of the two manifests, not either alone: `Package.swift` declares the six portable
    suites and `Project.swift` declares all thirteen, so "declared by neither" is the condition that
    means no runner compiles it. Checking them separately would need this file to know which suites
    are portable — a fourth hand-maintained list, which is the thing being removed.
    """
    found = {}
    for manifest in MANIFESTS:
        for name in DECLARED_SUITE.findall((ROOT / manifest).read_text()):
            found.setdefault(name, set()).add(manifest)
    return found


def binding_types():
    """Every type in `Sources/` that opens a listening socket, with anything that makes the answer
    untrustworthy.

    Found rather than listed. A type binds a port when its body calls Vapor's
    `server.start(address:)` — the one route to a socket in this tree — and the type is the nearest
    top-level declaration above that call, which is how both of the current two are written
    (`public actor MockServerEngine`, `public actor ControlServer`). A list of names here would be
    one more hand-maintained mirror of the kind this file exists to remove, and would go stale
    exactly when a new server type appeared — the moment the documents need checking most.

    An empty result is a problem rather than an answer: it means the call has changed shape, and
    "no suite binds a port" would then agree with any sentence at all.
    """
    types, problems = set(), []
    for file in sorted((ROOT / SOURCES).rglob("*.swift")):
        enclosing = None
        for line in file.read_text().splitlines():
            declared = TYPE_DECLARATION.match(line)
            if declared:
                enclosing = declared.group(1)
            elif BIND_CALL.search(line):
                if enclosing is None:
                    problems.append(f"{file.relative_to(ROOT)}: a `server.start(address:)` call sits "
                                    "above any top-level type declaration, so the type that binds "
                                    "cannot be named — the suites-that-bind-a-port check would "
                                    "silently miss whatever constructs it")
                else:
                    types.add(enclosing)
    if not types:
        problems.append(f"{SOURCES}/: no `server.start(address:)` call anywhere — nothing in this "
                        "tree appears to bind a port, which is either false or a sign the call has "
                        "changed shape; either way the documented list cannot be checked")
    return types, problems


def port_binding_suites(types):
    """Suite folders under `Tests/` that construct one of those types.

    Constructing the listener is the fact, not calling `start` on it: `MockServerEngineTests` binds
    through `MockServerEngine()` and `ComposedControlServerTests` through `ControlServer(host:…)`,
    and a suite that builds one has taken on the entitlement question whether or not the binding
    line is in the same file. The word boundary is what keeps a stub named `StubControlServer(`
    from counting.
    """
    constructors = {name: re.compile(rf"\b{re.escape(name)}\(") for name in types}
    found = set()
    for directory in sorted((ROOT / "Tests").iterdir()):
        if not directory.is_dir():
            continue
        for file in directory.rglob("*.swift"):
            text = file.read_text()
            if any(pattern.search(text) for pattern in constructors.values()):
                found.add(directory.name)
                break
    return found


def port_binding_claims(texts, suites):
    """Each document's list of the suites that bind a port, against the tree's answer.

    Reported as prose rather than through `counted_claims`, because what goes wrong here is a
    missing *name*, not a wrong number, and naming it is the whole of the fix.
    """
    for document, what in PORT_SUITE_SITES:
        found = PORT_SUITE_SENTENCE.search(re.sub(r"\s+", " ", texts[document]))
        if found is None:
            yield (f"{document} ({what}): no longer says \"Suites that bind a port (…)\" — a "
                   "document that has stopped naming them is exactly as stale as one naming the "
                   "wrong set, and this check cannot see it go wrong from here")
            continue
        stated = set(re.findall(r"`([A-Za-z0-9_]+)`", found.group(1)))
        for name in sorted(suites - stated):
            yield (f"{document} ({what}): Tests/{name} binds a port and is not in the list — add "
                   "it, and say what it does about the sandbox")
        for name in sorted(stated - suites):
            yield (f"{document} ({what}): names Tests/{name}, which constructs nothing that binds "
                   "a port — remove it, or the reader is being pointed at the wrong suite")


def claims(readme, counts, ui, portable, design, app, total):
    """Every number README.md states, paired with what the tree says it should be.

    Each entry is (what it is, regex with one capturing group, expected). A regex that matches
    nothing is reported as a lost claim rather than passed over, because a README that has stopped
    saying something is exactly as stale as one that says the wrong thing — and much harder to
    notice from a green check.
    """
    stated = [
        ("Tests badge", r"tests-(\d+)%20passing", total),
        ("headline total", r"(\d+) tests, counted as", total),
        ("table: portable row", r"import, CLI \| (\d+) \|", portable),
        ("table: design system row", r"Design system \| (\d+) \|", design),
        ("table: app row", r"App and coordination \| (\d+) \|", app),
        ("table: UI row", r"macOS UI \(XCUITest\) \| (\d+) \|", ui),
        ("prose: portable break down", r"The portable (\d+) break down as", portable),
        ("prose: app folders", r"The app's (\d+) are the", app),
        ("shell block: swift test", r"swift test\s+# the portable (\d+)", portable),
    ]
    # The two per-suite breakdowns. Written as "Domain 166, SpecImport 105, …" — module names, no
    # `Tests` suffix — and "`WorkspaceFeatureTests` 88, …" — folder names in backticks. Both are
    # parsed as name/number pairs out of the sentence that introduces them, so the check does not
    # depend on their order.
    for what, sentence_pattern, suffix in [
        ("portable breakdown", r"break down as (.+?)\.\s", "Tests"),
        # Deliberately not anchored on how many folders the sentence names. Writing "five" here is
        # the same hand-maintained mirror this script exists to remove: adding a suite made the
        # README say "six" and this pattern match nothing, which reports as a lost claim rather than
        # as the passing check it should be.
        ("app breakdown", r"The app's \d+ are the \w+ folders `MimicTests` builds —(.+?)—", ""),
    ]:
        sentence = re.search(sentence_pattern, readme, re.S)
        if sentence is None:
            yield (what, None, None, "README no longer contains this sentence")
            continue
        for name, number in re.findall(r"`?([A-Za-z]+)`? (\d+)", sentence.group(1)):
            folder = name + suffix
            if folder not in counts:
                yield (f"{what}: {name}", int(number), None,
                       f"names {folder}, which is not a folder under Tests/")
                continue
            yield (f"{what}: {name}", int(number), counts[folder], None)

    for what, pattern, expected in stated:
        found = re.search(pattern, readme)
        if found is None:
            yield (what, None, expected, "README no longer states this")
        else:
            yield (what, int(found.group(1)), expected, None)


def as_number(token):
    """A digit string or a spelled-out number as an int; None for anything else."""
    return int(token) if token.isdigit() else WORD_NUMBERS.get(token.lower())


def counted_claims(texts, label, table, mention, expected, surface):
    """Every stated count of one recomputed thing, in the same (what, stated, expected, note) shape
    as `claims`. Shared by the operation, template and match-mode counts, so a fourth counted claim
    cannot grow its own slightly different checker.

    Two passes over the same documents, because they fail on opposite mistakes. The table catches a
    known site going stale *or going missing*; the sweep catches the number appearing somewhere the
    table does not know about. Neither subsumes the other, and a document that quietly stopped
    stating the count would slip past a sweep alone without anything going red.
    """
    # What each table entry matched, so the sweep below can tell a site it already reported from a
    # new one. Without this, changing the count reports every site twice — once from each pass —
    # which reads as more places to edit than there are.
    seen = {}
    for document, what, pattern in table:
        # Whitespace-normalised, so reflowing a paragraph cannot break a pattern that spans a line
        # end — several of these sentences already wrap mid-claim.
        found = re.search(pattern, re.sub(r"\s+", " ", texts[document]))
        if found is None:
            yield (f"{document} ({what})", None, expected, f"no longer states the {label} count")
            continue
        seen.setdefault(document, []).append(found.group(0))
        stated = as_number(found.group(1))
        if stated is None:
            yield (f"{document} ({what})", None, expected,
                   f"states the count as {found.group(1)!r}, which is not a number this check "
                   "can read — write it as digits or as a spelled-out number")
        else:
            yield (f"{document} ({what})", stated, expected, None)

    for document, text in texts.items():
        for found in mention.finditer(text):
            stated = as_number(found.group(1))
            phrase = re.sub(r"\s+", " ", found.group(0))
            if stated is None or stated == expected:
                continue
            if any(phrase in already for already in seen.get(document, [])):
                continue
            line = text.count("\n", 0, found.start()) + 1
            yield (f"{document}:{line} ({phrase!r})", stated, expected,
                   f"says {stated} somewhere this check did not know about — if that is "
                   f"{surface} it is stale ({expected} now); if it is not, reword it so the "
                   "number does not sit directly before the word")


def self_test():
    """Drives `port_binding_claims` over fixtures written here, and fails if one comes out wrong.

    Every input is a literal — the sentences below, and a suite set of invented names. Neither
    comes from `binding_types` or `port_binding_suites`, and that is the whole point: a check fed by
    the function it is checking passes just as happily after that function is reverted, which is a
    mistake this repository has shipped. Invented names rather than the real three so a fixture
    cannot quietly start agreeing with the tree instead of with what is written here.
    """
    tree = {"AlphaTests", "BetaTests"}
    cases = [
        ("names both", "Suites that bind a port (`AlphaTests`, `BetaTests`) bind loopback only.", 0),
        ("order does not matter",
         "Suites that bind a port (`BetaTests`, `AlphaTests`) bind loopback only.", 0),
        ("one missing", "Suites that bind a port (`AlphaTests`) bind loopback only.", 1),
        ("both missing", "Suites that bind a port () bind loopback only.", 2),
        ("one too many",
         "Suites that bind a port (`AlphaTests`, `BetaTests`, `GammaTests`) bind loopback only.", 1),
        ("wrapped across a line end",
         "Suites that bind a port\n(`AlphaTests`, `BetaTests`) bind loopback only.", 0),
        ("sentence gone", "Tests: Swift Testing for units.", 1),
    ]

    failures = []
    for what, sentence, expected in cases:
        texts = {document: sentence for document, _ in PORT_SUITE_SITES}
        # One fixture stands in for both documents, so every case is reported once per site.
        found = len(list(port_binding_claims(texts, tree))) // len(PORT_SUITE_SITES)
        print(f"  {what:<28} {found} problem(s), expected {expected}")
        if found != expected:
            failures.append(f"{what}: reported {found} problem(s), expected {expected}")

    if failures:
        print("\nThe port-binding check is not behaving as written:")
        for line in failures:
            print(f"  {line}")
        sys.exit("\nA checker that cannot fail is not a check.")
    print("\nThe port-binding check reports what these fixtures expect.")


def main():
    if "--self-test" in sys.argv[1:]:
        print("Port-binding comparison, against fixtures in this file:")
        self_test()
        return

    counts = suite_counts()
    ui = count("MimicUITests", XCTEST)
    portable = sum(counts[name] for name in PORTABLE)
    design = sum(counts[name] for name in DESIGN_SYSTEM)
    app = sum(counts[name] for name in APP)
    total = sum(counts.values()) + ui
    kinds, problems = operation_count()
    templates, template_problems = template_count()
    modes, mode_problems = match_mode_count()
    listeners, listener_problems = binding_types()
    problems += template_problems + mode_problems + listener_problems
    binding = port_binding_suites(listeners)
    declared = declared_suites()
    texts = {document: (ROOT / document).read_text() for document in DOCS}

    print("Counted in the tree:")
    for name in sorted(counts):
        print(f"  Tests/{name:<24} {counts[name]:>4}")
    print(f"  MimicUITests{'':<20} {ui:>4}  (func test)")
    print(f"  portable {portable} · design system {design} · app {app} · UI {ui} · total {total}")
    print(f"  CommandKind cases {kinds} ({NUMBER_WORDS.get(kinds, kinds)}) — the operation count")
    print(f"  journey templates {templates} ({NUMBER_WORDS.get(templates, templates)}) · "
          f"match modes {modes} ({NUMBER_WORDS.get(modes, modes)})")
    print(f"  binds a port: {', '.join(sorted(binding)) or '(none)'} "
          f"— via {', '.join(sorted(listeners)) or '(no listener type found)'}")

    grouped = set(PORTABLE) | set(DESIGN_SYSTEM) | set(APP)
    for name in sorted(set(counts) - grouped):
        problems.append(f"Tests/{name} ({counts[name]} tests) is in none of the README's groups — "
                        "add it to the table and to the group lists in this file")
    for name in sorted(grouped - set(counts)):
        problems.append(f"Tests/{name} is in this file's group lists and no longer exists on disk")

    # A suite nobody runs, and its mirror image. Both have happened here: the folder-with-no-target
    # is the shape a suite takes when it is added without touching a manifest, and the
    # target-with-no-folder is what `Project.swift` carried from the first commit — a
    # `buildableFolders` line naming `Tests/JourneyFeatureTests` with nothing behind it, which Tuist
    # accepted in silence while the manifest read as though the journey UI had tests. The comment
    # recording that is still above the line.
    for name in sorted(set(counts) - set(declared)):
        problems.append(f"Tests/{name} ({counts[name]} tests) is declared by no build target — "
                        f"neither {' nor '.join(MANIFESTS)} names it, so nothing compiles or runs "
                        "it; add a target, or add the folder to an existing one's buildableFolders")
    for name in sorted(set(declared) - set(counts)):
        problems.append(f"Tests/{name} is named by {' and '.join(sorted(declared[name]))} and does "
                        "not exist on disk — a manifest naming a directory that is not there reads "
                        "as coverage that was never written")

    problems += list(port_binding_claims(texts, binding))

    for what, stated, expected, note in claims(texts["README.md"], counts,
                                               ui, portable, design, app, total):
        if note is not None:
            problems.append(f"{what}: {note}")
        elif stated != expected:
            problems.append(f"{what}: README says {stated}, the tree says {expected}")

    for label, table, mention, expected, surface, declares in [
        ("operation", OPERATION_CLAIMS, OPERATIONS_MENTION, kinds,
         "the command surface", "`CommandKind` declares"),
        ("template", TEMPLATE_CLAIMS, TEMPLATES_MENTION, templates,
         "the template shelf", "`JourneyTemplates.all` holds"),
        ("match-mode", MATCH_MODE_CLAIMS, MATCH_MODES_MENTION, modes,
         "the match modes", "`JourneyMatchMode` declares"),
    ]:
        for what, stated, target, note in counted_claims(texts, label, table, mention,
                                                         expected, surface):
            if note is not None:
                problems.append(f"{what}: {note}")
            elif stated != target:
                problems.append(f"{what}: says {stated}, {declares} {target}")

    if problems:
        print("\nThe documentation disagrees with the tree:")
        for line in problems:
            print(f"  {line}")
        sys.exit(f"\n{len(problems)} stale count(s). Update the documents to the numbers above — "
                 "and only after checking they are the ones you meant to change.")

    print("\nEvery documented count agrees with the tree.")


if __name__ == "__main__":
    main()

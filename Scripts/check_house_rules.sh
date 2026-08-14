#!/bin/bash
# Mechanical enforcement for the handful of AGENTS.md rules that nothing else checks.
#
# Most of that document is judgement and cannot be automated. A few of its rules are not judgement at
# all: they are absolute prohibitions on a literal string, every one of them has been broken at least
# once, and each was found by a human reading a diff. A rule kept only by review is a rule that comes
# back — so the ones that a grep can decide are decided here, and the ones that need an opinion stay
# where they are.
#
# bash, not zsh like the other scripts in this directory: the Linux CI job runs inside the `swift:6.2`
# container, which ships bash and no zsh at all, and this check is meant to run there before anything
# is compiled. Nothing beyond find/awk/grep for the same reason — it has to be able to run before the
# toolchain is set up, because its whole value is answering in a second instead of twenty minutes.
# The comment stripper below is awk rather than sed, and uses nothing outside POSIX awk, so `mawk` —
# what Debian and Ubuntu install as `awk`, and therefore what that container has — runs it.
#
# `--self-test` checks the scanner instead of the tree: every rule plants its own probes in a
# throwaway file and asserts the scanner reports every one of them. CI runs it beside the real check.
# It exists because the defect described above `STRIP_COMMENTS` survived review of the script that had
# it, and a linter with no test for its own scanner is a linter that can report "no violations" for
# any reason it likes.
#
# Adding a rule: the prohibition must be decidable by a grep, the tree must already obey it, and it
# must carry probes — the canonical spelling *and* at least two of the evasions described above
# `WS`/`DOT`. `selftest_rule` enforces that floor rather than trusting it. A check that starts red is
# a check everyone learns to scroll past, and then it is worth less than nothing, because a green
# build no longer means anything either.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

self_test=0
case "${1:-}" in
    --self-test) self_test=1 ;;
    "") ;;
    *)
        printf 'usage: %s [--self-test]\n' "$(basename "$0")" >&2
        exit 2
        ;;
esac

# Production Swift. `App/Sources` is a single file, `MimicApp.swift`, but it is the scene definition —
# SwiftUI rules bind it exactly as much as they bind the feature modules, and leaving it out would put
# the one file that owns the menu bar outside the check that governs casing.
#
# `Tools` is the third, and until this line no rule here could see it — nor could anything else in
# `Scripts/`, none of which so much as names the directory. It is not a scratch tree: both manifests
# build it as the `mimic` executable, `Package.swift` with
# `.executableTarget(name: "mimic", … path: "Tools/mimic")` and `Project.swift` with
# `buildableFolders: ["Tools/mimic"]`, so it ships. With it added, every `.swift` file in the
# repository that is not a build manifest is now in scope for these rules.
#
# Adding it surfaces nothing today, because `Tools/mimic/main.swift` is six lines that do no more than
# `exit(await MimicCommand.run())`. That is the argument for adding it now rather than later: a tree
# is free to put in scope while it is empty of violations, and an argument once it is not.
PRODUCTION_SOURCES=(Sources App/Sources Tools)

# Every suite folder under `Tests/`, and until this line they were in scope for *none* of the
# rules — including the sleep rule, which exists because of tests. Nothing about `.textCase(`,
# `@AppStorage` or `asyncAfter` stops being a defect in a fixture: a test is where each of them is
# most likely to be reached for, because "it is only a test" is the argument that makes all three feel
# harmless, and a view fixture that shouts is one copy-paste from a view that ships.
UNIT_TESTS=(Tests)

UI_TESTS=(MimicUITests)

# Blanks `//` comments before any rule looks at a file, without ever cutting inside a string literal.
#
# The stripping is not tidiness, it is the difference between this script working and not. Every rule
# below is *quoted* wherever it is explained: AGENTS.md rule 9 is spelled out verbatim in three doc
# comments across MimicUITests, and `PanelLayoutStore` spends a paragraph on why it does not use
# `@AppStorage`. A naive grep reports each of those explanations as an instance of the thing it warns
# about — the check would open red on a tree that obeys it perfectly, which is the one failure mode
# that makes a lint worthless.
#
# This used to be `sed 's|//.*||'`, which knows nothing about string literals and so cut at the `//`
# in every URL. That made the whole check evadable by accident: planting
# `Text("see https://example.com").textCase(.uppercase)` in Sources/DesignSystem printed
# "…house rules checked, no violations" and exited 0, while the same line with the URL removed
# exited 1 — both run against this tree. The hazard was already known one directory over. The compiler-settings
# check in .github/workflows/ci.yml deliberately declines to strip trailing comments from
# Package.swift, saying "`//` also appears inside every `.package(url:)`"; nobody connected that to
# the scanner standing on it.
#
# So this is a small lexer rather than a substitution. It tracks plain `"…"` strings and their `\`
# escapes, `#"…"#` raw strings and their `\#` escapes, and `"""` literals across line boundaries, and
# only a `//` outside all of those ends a line.
#
# String *contents* are kept rather than blanked, on purpose. A house rule can legitimately be about
# a literal — "never widen the control plane's binding beyond 127.0.0.1" is one this could grow into
# — and blanking would make that rule unwritable here. It costs nothing today, which was re-measured
# rather than carried forward: running each rule's pattern over the trees *that rule* scans, with no
# stripping at all, every hit is either inside a `//` comment or on one of the two lines an
# allow-list already names, and none is inside a string literal.
#
# The scope qualifier is load-bearing and this sentence used to leave it out — it claimed the run
# over "Sources, App/Sources, Tests and MimicUITests" put every hit in a comment, which is false for
# the sleep rule: `ControlPlaneCoordinator.swift` and `DSJSONEditor.swift` both sleep in production
# code, on purpose, and that rule does not scan `Sources` for exactly that reason.
#
# There are no `/* */` block comments anywhere in those four trees (`grep -rn '/\*'` over them returns
# nothing), so the lexer does not know about them; if one appears it will need to. Every line is
# printed whether or not anything was cut, so the line numbers a later `grep -n` reports still point
# at the real source line.
STRIP_COMMENTS='
function hashes(k,   s, j) { s = ""; for (j = 0; j < k; j++) s = s "#"; return s }
BEGIN { ml = 0; mlterm = "" }
{
    line = $0; n = length(line); out = ""; i = 1
    while (i <= n) {
        if (ml) {
            p = index(substr(line, i), mlterm)
            if (p == 0) { out = out substr(line, i); i = n + 1; continue }
            out = out substr(line, i, p - 1 + length(mlterm))
            i = i + p - 1 + length(mlterm)
            ml = 0
            continue
        }
        c = substr(line, i, 1)
        if (c == "/" && substr(line, i + 1, 1) == "/") break
        h = 0; j = i
        if (c == "#") { while (substr(line, j, 1) == "#") j++; h = j - i }
        if (substr(line, j, 3) == "\"\"\"") {
            out = out substr(line, i, j + 3 - i); i = j + 3
            ml = 1; mlterm = "\"\"\"" hashes(h)
            continue
        }
        if (substr(line, j, 1) == "\"") {
            term = "\"" hashes(h); esc = "\\" hashes(h)
            out = out substr(line, i, j + 1 - i); i = j + 1
            while (i <= n) {
                if (substr(line, i, length(esc)) == esc) {
                    out = out substr(line, i, length(esc) + 1); i = i + length(esc) + 1; continue
                }
                if (substr(line, i, length(term)) == term) { out = out term; i = i + length(term); break }
                out = out substr(line, i, 1); i++
            }
            continue
        }
        if (h > 0) { out = out substr(line, i, j - i); i = j; continue }
        out = out c; i++
    }
    print out
}
'

# A stripped mirror of the tree, filled in as the rules ask for files and reused after that, so the
# six rules cost one pass of the lexer rather than six. Lazily rather than up front on purpose: a
# mirror built by a separate `prepare` step is a mirror a seventh rule can be pointed past — it would
# grep a file that was never stripped, find nothing, and report the rule as clean.
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mimic-house-rules.XXXXXX")"
# One EXIT trap covers every way this script ends, which is worth having checked rather than assumed
# now that `--self-test` plants probe files here. A clean run, a rule firing (`exit 1`) and the
# self-test failing (`exit 1`) were each run and each left no directory behind; the usage error above
# exits before the directory is created at all.
#
# The fourth path is a signal, and it needs no trap of its own: bash runs an EXIT trap on its way down
# from a signal it does not trap. That is the opposite of the folklore, so it was measured rather than
# believed — a minimal script with only this trap, killed by SIGTERM and (via a parent that does not
# hand it an ignored SIGINT) by SIGINT, cleaned up in both cases. Adding INT/TERM traps beside this
# one therefore looks like belt-and-braces and is not: it would be machinery whose only justification
# is a claim about bash that does not hold.
trap 'rm -rf "$WORK_DIR"' EXIT
STRIPPED="$WORK_DIR/stripped"

# Ensures $STRIPPED holds a comment-stripped copy of $1, path for path.
strip_file() {
    local file=$1
    if [ -f "$STRIPPED/$file" ]; then return 0; fi
    mkdir -p "$STRIPPED/$(dirname "$file")"
    awk "$STRIP_COMMENTS" "$file" > "$STRIPPED/$file"
}

# Prints `path:line:text` for every match of $1 in the stripped copies of the .swift files under $2….
scan() {
    local pattern=$1
    shift
    local file
    while IFS= read -r file; do
        strip_file "$file"
        grep -nE "$pattern" "$STRIPPED/$file" | sed "s|^|$file:|" || true
    done < <(find "$@" -type f -name '*.swift' | sort)
}

# Checks the scanner rather than the tree, for one rule.
#
# $4 is a newline-separated list of spellings, and the file is built so that each of them is planted
# three ways, each one a way this scanner has failed or could fail silently:
#
#   - quoted inside a `//` comment, which must stay invisible — the case the stripping exists for,
#     and the one that would open the check red on a clean tree;
#   - as plain code, which must be reported;
#   - again behind a URL in a string literal *on the same line*, which must also be reported. That
#     one is the stripper evasion itself, and it has to be planted separately: several probes read
#     naturally with their URL *after* the pattern, where the old `sed` stripper never reached, so
#     writing the URL into the probe by hand tested nothing for those rules.
#
# The preamble carries the fourth case, which is about the lexer rather than any one rule: a `"""`
# literal holding a URL, placed ahead of every probe so that a wedged multi-line state would swallow
# all of them rather than none.
#
# Two hits per spelling, on exactly those lines and no others, is the only pass. That is what makes a
# regex that has been "simplified" back to a literal string fail here: the canonical spelling still
# reports, the evasions go quiet, and `found` stops matching `expected`.
#
# The floor of three spellings is enforced rather than trusted. Deleting the evasive probes would
# otherwise leave a green self-test standing over exactly the hole the probes were added to close —
# the same shape of failure as a green ControlPlane suite over an unreachable host.
selftest_rule() {
    local reason=$1 pattern=$2 allow=$3 probes=$4
    local dir="$WORK_DIR/selftest/rule-$rules_checked"
    local file="$dir/Probe.swift"
    mkdir -p "$dir"
    {
        printf 'import SwiftUI\n'
        printf 'let note = """\n'
        printf 'Prose in a literal, with a URL in it: https://example.com/guide\n'
        printf '"""\n'
    } > "$file"

    # A here-string rather than a pipe, so the loop runs in this shell and its counters survive it.
    local expected="" probe planted=0 line=4
    while IFS= read -r probe; do
        [ -n "$probe" ] || continue
        {
            printf '// Quoting the rule, the way AGENTS.md and three doc comments do: %s\n' "$probe"
            printf '%s\n' "$probe"
            printf 'let docs = "https://example.com"; %s\n' "$probe"
        } >> "$file"
        expected="$expected$file:$((line + 2)) $file:$((line + 3)) "
        line=$((line + 3))
        planted=$((planted + 1))
    done <<< "$probes"
    probes_planted=$((probes_planted + planted))

    local hits
    hits="$(scan "$pattern" "$dir")"
    if [ -n "$allow" ]; then
        hits="$(printf '%s\n' "$hits" | grep -vE "$allow" || true)"
    fi
    local found
    found="$(printf '%s\n' "$hits" | grep -v '^[[:space:]]*$' | cut -d: -f1,2 | tr '\n' ' ' || true)"

    # The pattern, not just the rule's heading: three rules cite "Non-negotiable patterns" and a list
    # that names them all identically says nothing about which one just went quiet.
    if [ "$found" = "$expected" ] && (( planted >= 3 )); then
        printf '  ok   %s — %d spellings — %s\n' "${reason%%:*}" "$planted" "$pattern"
        return 0
    fi
    selftest_failures=$((selftest_failures + 1))
    printf '  FAIL %s — %s\n' "${reason%%:*}" "$pattern"
    if (( planted < 3 )); then
        printf '       %d spelling(s) planted; a rule must plant its canonical form and at least two evasions.\n' \
            "$planted"
    fi
    # The same here-string loop the planting used, rather than `printf | grep -v | while`: `pipefail`
    # is on, an empty probe list makes that `grep` exit 1, and `set -e` would then abort the script
    # in the middle of the one report a human is waiting to read.
    while IFS= read -r probe; do
        [ -n "$probe" ] || continue
        printf '       probe:    %s\n' "$probe"
    done <<< "$probes"
    printf '       expected: %s\n' "$expected"
    printf '       got:      %s\n' "${found:-nothing}"
}

violations=0
rules_checked=0
selftest_failures=0
probes_planted=0

# Reports every match of a rule.
#   $1  the reason, one line, naming the rule it breaks
#   $2  the pattern
#   $3  an allow-list regex matched against the `path:line:text` lines ('' for none)
#   $4  the lines of Swift that must be caught, one spelling per line, for --self-test to plant: the
#       canonical form and at least two evasions of it — see `selftest_rule`
#   $5… the trees to search
report() {
    local reason=$1 pattern=$2 allow=$3 probes=$4
    shift 4
    rules_checked=$((rules_checked + 1))

    if (( self_test )); then
        selftest_rule "$reason" "$pattern" "$allow" "$probes"
        return 0
    fi

    local hits
    hits="$(scan "$pattern" "$@")"
    if [ -n "$allow" ]; then
        hits="$(printf '%s\n' "$hits" | grep -vE "$allow" || true)"
    fi
    [ -n "$hits" ] || return 0

    # A here-string rather than a pipe, so the loop runs in this shell and its increments survive it.
    local hit rest
    while IFS= read -r hit; do
        [ -n "$hit" ] || continue
        rest=${hit#*:}
        printf '  %s:%s: %s\n' "${hit%%:*}" "${rest%%:*}" "$reason"
        printf '      %s\n' "${rest#*:}"
        violations=$((violations + 1))
    done <<< "$hits"
}

if (( self_test )); then
    printf 'Self-testing the house-rule scanner…\n'
else
    printf 'Checking AGENTS.md house rules…\n'
fi

# Swift is not a literal-string language, and every rule below used to be written as though it were.
# Three spellings walked straight through, each one planted as real code in a file under
# `Sources/DesignSystem` and confirmed to leave this script printing "…house rules checked, no
# violations" and exiting 0:
#
#     Text("x").textCase (.uppercase)       — a space between the member and its argument list
#     SwiftUI.Alert(title:)                 — the module the type already lives in, spelled out
#     DispatchQueue . main . asyncAfter(…)  — spaces around the dots of a member chain
#
# So no pattern here writes a member-access `.` or a call's `(` bare. `DOT` is a member-access joint
# and `WS` is the gap in front of an argument list; every joint in every rule goes through one of
# them, and the rules whose target is a module-level name (`Alert`, `AppStorage`) admit a qualifier in
# front of it. `--self-test` plants all of these spellings per rule, so a later "simplification" back
# to a literal string cannot pass.
#
# What this deliberately does not chase is a rule split across two lines. Swift allows that too, the
# scanner reads one line at a time, and every occurrence anybody has written here is on one line — a
# pattern that cannot produce a false positive is worth more than one that catches every phrasing,
# the same trade the `waitForExistence` rule below already documents.
WS='[[:space:]]*'
DOT='[[:space:]]*\.[[:space:]]*'

report \
    'AGENTS.md "Visual standard": sentence case inside the window — there is no .textCase() in this codebase, and the one deliberate exception, DSMethodBadge, uppercases its own string in Swift rather than shouting prose into shape with a modifier.' \
    "${DOT}textCase${WS}\(" \
    '' \
    'Text("Response headers").textCase(.uppercase)
    Text("Response headers").textCase (.uppercase)
    Text("Response headers") . textCase(.uppercase)' \
    "${PRODUCTION_SOURCES[@]}" "${UNIT_TESTS[@]}" "${UI_TESTS[@]}"

# The optional qualifier in front of the name is defensive rather than demonstrated: nothing here
# checked whether swiftc accepts `@SwiftUI.AppStorage`, and nothing needs to. Widening a prohibition
# to a spelling the compiler may reject cannot turn the tree red — no spelling of this attribute
# occurs in any scanned tree at all, only a doc comment in `PanelLayoutStore` naming it to explain why
# it is not used — while leaving it out would be betting the rule on a guess about the grammar.
report \
    'AGENTS.md "Panel chrome": @AppStorage binds to UserDefaults.standard, so a test run overwrites the developer'"'"'s real window arrangement — inject UserDefaults the way PanelLayoutStore does.' \
    "@${WS}([A-Za-z_][A-Za-z0-9_]*${DOT})?AppStorage" \
    '' \
    '@AppStorage("inspectorWidth") var inspectorWidth = 280.0
    @SwiftUI.AppStorage("inspectorWidth") var inspectorWidth = 280.0
    @SwiftUI . AppStorage("inspectorWidth") var inspectorWidth = 280.0' \
    "${PRODUCTION_SOURCES[@]}" "${UNIT_TESTS[@]}" "${UI_TESTS[@]}"

# Unanchored on the left on purpose, which is what makes the module-qualified spelling free: the
# `Dispatch.` in `Dispatch.DispatchQueue.main.asyncAfter` sits outside the match rather than in front
# of it. Still no trailing `\(` — a bare reference to the method is as much a violation as a call, and
# requiring the parenthesis would narrow a rule that has never needed narrowing.
report \
    'AGENTS.md "Non-negotiable patterns": use Task { try? await Task.sleep(for:) } — an asyncAfter block outlives the view that scheduled it and cannot be cancelled.' \
    "DispatchQueue${DOT}main${DOT}asyncAfter" \
    '' \
    'DispatchQueue.main.asyncAfter(deadline: .now() + 2) { saveState = .idle }
    DispatchQueue . main . asyncAfter(deadline: .now() + 2) { saveState = .idle }
    Dispatch.DispatchQueue.main.asyncAfter(deadline: .now() + 2) { saveState = .idle }' \
    "${PRODUCTION_SOURCES[@]}" "${UNIT_TESTS[@]}" "${UI_TESTS[@]}"

# Still anchored so it cannot fire on a type whose name merely ends in `Alert` — `PortConflictAlert`
# and `deleteAlertTitle` are the live cases — and `.alert(` stays lower case, so the modern modifier
# this rule steers people towards is never itself the violation.
#
# The `.` came *out* of that anchor, and that is the fix: it used to read `[^A-Za-z0-9_.]`, so writing
# the type as `SwiftUI.Alert(` — the module it has always lived in — matched nothing at all. What the
# `.` was buying was silence on a nested type spelled exactly `Foo.Alert(`, and there is none: the
# only identifiers containing `Alert` anywhere in the scanned trees are `portConflictAlert`,
# `PortConflictAlertData` and `deleteAlertTitle`. A rule a module qualifier walks straight through is
# worth less than a rule that would flag a nested type nobody has written.
report \
    'AGENTS.md "Non-negotiable patterns": the Alert() constructor is deprecated — use the modern .alert(_:isPresented:) modifier.' \
    "(^|[^A-Za-z0-9_])Alert${WS}\(" \
    '' \
    'let alert = Alert(title: Text("Delete endpoint?"))
    let alert = Alert (title: Text("Delete endpoint?"))
    let alert = SwiftUI.Alert(title: Text("Delete endpoint?"))
    let alert = SwiftUI . Alert (title: Text("Delete endpoint?"))' \
    "${PRODUCTION_SOURCES[@]}" "${UNIT_TESTS[@]}" "${UI_TESTS[@]}"

# The one AGENTS.md bullet that publishes the command it wants run — "`grep -rn
# '\.font(\.system(size: [0-9]' Sources` prints exactly those two; a third means somebody hand-wrote
# a rung" — and until this rule nothing ran it. `DSGlyph`'s own doc comment ends on the same
# sentence, calling that grep "the whole check". A check that exists only as a string in two files
# is not a check.
#
# The pattern is a *call site* applying a bare number, not a `.system(size:)` anywhere: `DSTypography`
# declares the type scale with thirteen of them and is the right place for a literal. Requiring the
# enclosing `.font(` is what tells those apart, and `[^)]*` between them cannot cross a `)`, so it
# admits a qualifier — `Font.system`, `SwiftUI.Font.system` — without reaching into a neighbouring
# call. A size named symbolically (`DSGlyph.inline`, `size.glyphSize`) never matches, because the
# rung after `size:` has to be a digit.
#
# Two exemptions, and they are the two the bullet itself names, pinned to their exact spellings the
# way the sleep rule below pins its one: the welcome window's 26pt first-run clock, which is an
# illustration rather than a glyph, and its 14pt action glyph, which sits a point above the ladder's
# ceiling on a stated visual judgement. Both say which they are at the call site. Anything else,
# including anything below `DSGlyph.minimum`, is caught here — a separate floor rule would have
# nothing left to catch, since a bare `size: 7` is already a bare literal and the exemptions name
# only 26 and 14.
report \
    'AGENTS.md "Visual standard": no glyph below 8pt, and the size comes from DSGlyph — a hand-written size is how that ladder came to exist only in prose. Six rungs are named in DSGlyph, with DSGlyph.minimum as the floor; DSTypography is where a literal point size belongs.' \
    "${DOT}font${WS}\([^)]*${DOT}system${WS}\(${WS}size:${WS}[0-9]" \
    'WelcomeWindow\.swift:[0-9]+:.*\.font\(\.system\(size: (26, weight: \.regular|14)\)\)' \
    'Image(systemName: "gear").font(.system(size: 7))
    Image(systemName: "gear").font(.system (size: 7))
    Image(systemName: "gear") . font ( . system ( size: 7 ) )
    Image(systemName: "gear").font(SwiftUI.Font.system(size: 7))' \
    "${PRODUCTION_SOURCES[@]}" "${UNIT_TESTS[@]}" "${UI_TESTS[@]}"

# UI tests only, and this one genuinely is: `waitForExistence` is an XCUIElement method, and no target
# under `Tests/` so much as imports XCTest (`grep -rln 'import XCTest' Tests` returns nothing — they
# are Swift Testing suites throughout). Widening it would add a tree the pattern cannot occur in.
#
# Both sides of the `||` must be a wait, so this describes the exact form rule 9 names and nothing
# else. It reads one line at a time, so the same mistake split across two lines would still get past;
# every occurrence in this suite has been written on one line, and a pattern that cannot produce a
# false positive is worth more here than one that catches every phrasing.
report \
    'AGENTS.md "UI Changes" rule 9: this waits out the first element'"'"'s entire timeout before it ever looks at the second, so a short-lived one appears and vanishes unseen — use UITestApp.waitForAny([a, b], timeout:).' \
    "waitForExistence${WS}\(.*\)${WS}\|\|.*waitForExistence${WS}\(" \
    '' \
    'XCTAssertTrue(saving.waitForExistence(timeout: 2) || saved.waitForExistence(timeout: 2))
    XCTAssertTrue(saving.waitForExistence (timeout: 2) || saved.waitForExistence (timeout: 2))
    XCTAssertTrue(saving . waitForExistence(timeout: 2) || saved . waitForExistence(timeout: 2))' \
    "${UI_TESTS[@]}"

# Both test trees, and deliberately not the production one. `Task.sleep` is already excluded by the
# leading `[^A-Za-z0-9_.]`, which is what makes this safe to point at `Tests/` — the unit suites await
# `Task.sleep` in about two dozen places and none of them are what this forbids. Production is left
# out for a different reason: `DSJSONEditor.resolvedValidationResult` takes a `sleep:` closure
# parameter and calls it, which is the injected seam the rule wants people to have, and a bare
# `sleep(` pattern cannot tell that call apart from a real one.
#
# The single exemption in the whole file: the poll interval inside `UITestApp.waitUntil`. That one
# sleep is what makes every other wait in the suite a poll rather than a fixed pause, so forbidding it
# would forbid the fix. It is pinned to that exact expression rather than to the file, so a
# `Thread.sleep(forTimeInterval: 2)` added to `AppLaunchSupport.swift` tomorrow is still caught. The
# exemption is deliberately *not* whitespace-tolerant like the rules are: an allow-list widened is an
# exemption widened, and respacing the one line it names should have to come back through here.
#
# The dot exclusion on the second arm stays, and it is the one hole in this file left open knowingly.
# It is what keeps `Task.sleep(` — which these two trees await throughout — out of the report, and an
# ERE has no negative lookahead, so "preceded by a qualifier that is not `Task`" has no spelling here
# that would not cost more than it buys. A module-qualified C sleep, `Glibc.usleep(…)`, therefore
# still evades this rule; it is written down rather than papered over. `Thread.sleep` needs no such
# arm — the first arm is unanchored, so it already matches inside `Foundation.Thread.sleep(`, which is
# what the third probe below pins.
report \
    'AGENTS.md "Non-negotiable patterns": tests never sleep — too short and the test is flaky, too long and every run pays for it. Poll with .waitForExistence(timeout:) or UITestApp.waitUntil, and await Task.sleep only where a debounce is the thing under test.' \
    "(Thread${DOT}sleep${WS}\(|(^|[^A-Za-z0-9_.])u?sleep${WS}\()" \
    'AppLaunchSupport\.swift:[0-9]+:.*Thread\.sleep\(forTimeInterval: pollInterval\)' \
    'Thread.sleep(forTimeInterval: 1)
    Thread . sleep (forTimeInterval: 1)
    Foundation.Thread.sleep(forTimeInterval: 1)
    usleep (500)' \
    "${UNIT_TESTS[@]}" "${UI_TESTS[@]}"

if (( self_test )); then
    if (( selftest_failures > 0 )); then
        printf '\n%d of %d rule(s) failed their probes — the scanner is broken, not the tree.\n' \
            "$selftest_failures" "$rules_checked"
        exit 1
    fi
    printf '%d spellings of %d rules planted and caught — canonical, spaced and module-qualified;\n' \
        "$probes_planted" "$rules_checked"
    printf 'comments, string literals and multi-line literals told apart.\n'
    exit 0
fi

if (( violations > 0 )); then
    printf '\n%d house-rule violation(s) across %d rules checked.\n' "$violations" "$rules_checked"
    printf 'Each line cites the rule; AGENTS.md carries the failure that motivated it.\n'
    exit 1
fi

printf '%d house rules checked, no violations.\n' "$rules_checked"

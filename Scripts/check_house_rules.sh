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
# `--self-test` checks the scanner instead of the tree: every rule plants its own probe in a throwaway
# file and asserts the scanner reports it. CI runs it beside the real check. It exists because the
# defect described above `STRIP_COMMENTS` survived review of the script that had it, and a linter with
# no test for its own scanner is a linter that can report "no violations" for any reason it likes.
#
# Adding a rule: it must be a *literal* prohibition, the tree must already obey it, and it must carry
# a probe. A check that starts red is a check everyone learns to scroll past, and then it is worth
# less than nothing, because a green build no longer means anything either.

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
PRODUCTION_SOURCES=(Sources App/Sources)

# Every suite folder under `Tests/`, and until this line they were in scope for *none* of the
# six rules — including the sleep rule, which exists because of tests. Nothing about `.textCase(`,
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
# `Text("see https://example.com").textCase(.uppercase)` in Sources/DesignSystem printed "6 house
# rules checked, no violations" and exited 0, while the same line with the URL removed exited 1 —
# both run against this tree. The hazard was already known one directory over. The compiler-settings
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
# — and blanking would make that rule unwritable here. It costs nothing today: running all six
# patterns over Sources, App/Sources, Tests and MimicUITests with no stripping at all puts every hit
# in a `//` comment and none inside a literal.
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
# Four things planted in one throwaway file, each of them a way this scanner has failed or could
# fail silently:
#
#   - the probe quoted inside a `//` comment, which must stay invisible — the case the stripping
#     exists for, and the one that would open the check red on a clean tree;
#   - a `"""` literal holding a URL, which must not wedge the lexer's multi-line state and swallow
#     what follows;
#   - the probe as plain code, which must be reported;
#   - the probe again behind a URL in a string literal *on the same line*, which must also be
#     reported. That last one is the evasion itself, and it has to be planted separately: three of
#     the six probes read naturally with their URL *after* the pattern, where the old `sed` stripper
#     never reached, so writing the URL into the probe by hand tested nothing for half the rules.
#
# Two hits, on those two lines and no others, is the only pass.
selftest_rule() {
    local reason=$1 pattern=$2 allow=$3 probe=$4
    local dir="$WORK_DIR/selftest/rule-$rules_checked"
    local file="$dir/Probe.swift"
    mkdir -p "$dir"
    {
        printf 'import SwiftUI\n'
        printf '// Quoting the rule, the way AGENTS.md and three doc comments do: %s\n' "$probe"
        printf 'let note = """\n'
        printf 'Prose in a literal, with a URL in it: https://example.com/guide\n'
        printf '"""\n'
        printf '%s\n' "$probe"
        printf 'let docs = "https://example.com"; %s\n' "$probe"
    } > "$file"
    local behind_url_line plain_line
    behind_url_line="$(wc -l < "$file" | tr -d ' ')"
    plain_line=$((behind_url_line - 1))

    local hits
    hits="$(scan "$pattern" "$dir")"
    if [ -n "$allow" ]; then
        hits="$(printf '%s\n' "$hits" | grep -vE "$allow" || true)"
    fi
    local found expected
    found="$(printf '%s\n' "$hits" | grep -v '^[[:space:]]*$' | cut -d: -f1,2 | tr '\n' ' ' || true)"
    expected="$file:$plain_line $file:$behind_url_line "

    # The pattern, not just the rule's heading: three rules cite "Non-negotiable patterns" and a list
    # that names them all identically says nothing about which one just went quiet.
    if [ "$found" = "$expected" ]; then
        printf '  ok   %s — %s\n' "${reason%%:*}" "$pattern"
        return 0
    fi
    selftest_failures=$((selftest_failures + 1))
    printf '  FAIL %s — %s\n' "${reason%%:*}" "$pattern"
    printf '       probe:    %s\n' "$probe"
    printf '       expected: %s\n' "$expected"
    printf '       got:      %s\n' "${found:-nothing}"
}

violations=0
rules_checked=0
selftest_failures=0

# Reports every match of a rule.
#   $1  the reason, one line, naming the rule it breaks
#   $2  the pattern
#   $3  an allow-list regex matched against the `path:line:text` lines ('' for none)
#   $4  a line of Swift that must be caught, for --self-test to plant — see `selftest_rule`
#   $5… the trees to search
report() {
    local reason=$1 pattern=$2 allow=$3 probe=$4
    shift 4
    rules_checked=$((rules_checked + 1))

    if (( self_test )); then
        selftest_rule "$reason" "$pattern" "$allow" "$probe"
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

report \
    'AGENTS.md "Visual standard": sentence case inside the window — there is no .textCase() in this codebase, and the one deliberate exception, DSMethodBadge, uppercases its own string in Swift rather than shouting prose into shape with a modifier.' \
    '\.textCase\(' \
    '' \
    'Text("Response headers").textCase(.uppercase)' \
    "${PRODUCTION_SOURCES[@]}" "${UNIT_TESTS[@]}" "${UI_TESTS[@]}"

report \
    'AGENTS.md "Panel chrome": @AppStorage binds to UserDefaults.standard, so a test run overwrites the developer'"'"'s real window arrangement — inject UserDefaults the way PanelLayoutStore does.' \
    '@AppStorage' \
    '' \
    '@AppStorage("inspectorWidth") var inspectorWidth = 280.0' \
    "${PRODUCTION_SOURCES[@]}" "${UNIT_TESTS[@]}" "${UI_TESTS[@]}"

report \
    'AGENTS.md "Non-negotiable patterns": use Task { try? await Task.sleep(for:) } — an asyncAfter block outlives the view that scheduled it and cannot be cancelled.' \
    'DispatchQueue\.main\.asyncAfter' \
    '' \
    'DispatchQueue.main.asyncAfter(deadline: .now() + 2) { saveState = .idle }' \
    "${PRODUCTION_SOURCES[@]}" "${UNIT_TESTS[@]}" "${UI_TESTS[@]}"

# Anchored so it cannot fire on a type whose name merely ends in `Alert`, and so `.alert(` — the
# modern modifier this rule exists to steer people towards — is never itself the violation.
report \
    'AGENTS.md "Non-negotiable patterns": the Alert() constructor is deprecated — use the modern .alert(_:isPresented:) modifier.' \
    '(^|[^A-Za-z0-9_.])Alert\(' \
    '' \
    'let alert = Alert(title: Text("Delete endpoint?"))' \
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
    'waitForExistence\(.*\)[[:space:]]*\|\|.*waitForExistence\(' \
    '' \
    'XCTAssertTrue(saving.waitForExistence(timeout: 2) || saved.waitForExistence(timeout: 2))' \
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
# `Thread.sleep(forTimeInterval: 2)` added to `AppLaunchSupport.swift` tomorrow is still caught.
report \
    'AGENTS.md "Non-negotiable patterns": tests never sleep — too short and the test is flaky, too long and every run pays for it. Poll with .waitForExistence(timeout:) or UITestApp.waitUntil, and await Task.sleep only where a debounce is the thing under test.' \
    '(Thread\.sleep\(|(^|[^A-Za-z0-9_.])u?sleep[[:space:]]*\()' \
    'AppLaunchSupport\.swift:[0-9]+:.*Thread\.sleep\(forTimeInterval: pollInterval\)' \
    'Thread.sleep(forTimeInterval: 1)' \
    "${UNIT_TESTS[@]}" "${UI_TESTS[@]}"

if (( self_test )); then
    if (( selftest_failures > 0 )); then
        printf '\n%d of %d rule probe(s) went unreported — the scanner is broken, not the tree.\n' \
            "$selftest_failures" "$rules_checked"
        exit 1
    fi
    printf '%d rule probes planted and caught; comments, string literals and multi-line literals told apart.\n' \
        "$rules_checked"
    exit 0
fi

if (( violations > 0 )); then
    printf '\n%d house-rule violation(s) across %d rules checked.\n' "$violations" "$rules_checked"
    printf 'Each line cites the rule; AGENTS.md carries the failure that motivated it.\n'
    exit 1
fi

printf '%d house rules checked, no violations.\n' "$rules_checked"

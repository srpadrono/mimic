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
# is compiled. Nothing beyond find/sed/grep for the same reason — it has to be able to run before the
# toolchain is set up, because its whole value is answering in a second instead of twenty minutes.
#
# Adding a rule: it must be a *literal* prohibition, and the tree must already obey it. A check that
# starts red is a check everyone learns to scroll past, and then it is worth less than nothing,
# because a green build no longer means anything either.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

# Production Swift. `App/Sources` is a single file, `MimicApp.swift`, but it is the scene definition —
# SwiftUI rules bind it exactly as much as they bind the feature modules, and leaving it out would put
# the one file that owns the menu bar outside the check that governs casing.
PRODUCTION_SOURCES=(Sources App/Sources)
UI_TESTS=(MimicUITests)

violations=0
rules_checked=0

# Prints `path:line:text` for every match of $1 in the .swift files under $2…, with `//` comments
# blanked first.
#
# That stripping is not tidiness, it is the difference between this script working and not. Every
# rule below is *quoted* wherever it is explained: AGENTS.md rule 9 is spelled out verbatim in three
# doc comments across MimicUITests, and `PanelLayoutStore` spends a paragraph on why it does not use
# `@AppStorage`. A naive grep reports each of those explanations as an instance of the thing it warns
# about — the check would open red on a tree that obeys it perfectly, which is the one failure mode
# that makes a lint worthless.
#
# `sed` blanks from `//` to end of line rather than deleting the line, so every line number a later
# `grep -n` reports still points at the real source line. There are no `/* */` block comments in
# either tree today; if one appears, this will need to learn about them.
scan() {
    local pattern=$1
    shift
    local file
    while IFS= read -r file; do
        sed 's|//.*||' "$file" | grep -nE "$pattern" | sed "s|^|$file:|" || true
    done < <(find "$@" -type f -name '*.swift' | sort)
}

# Reports every match of a rule.
#   $1  the reason, one line, naming the rule it breaks
#   $2  the pattern
#   $3  an allow-list regex matched against the `path:line:text` lines ('' for none)
#   $4… the trees to search
report() {
    local reason=$1 pattern=$2 allow=$3
    shift 3
    rules_checked=$((rules_checked + 1))

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

printf 'Checking AGENTS.md house rules…\n'

report \
    'AGENTS.md "Visual standard": sentence case inside the window — there is no .textCase() in this codebase, and the one deliberate exception, DSMethodBadge, uppercases its own string in Swift rather than shouting prose into shape with a modifier.' \
    '\.textCase\(' \
    '' \
    "${PRODUCTION_SOURCES[@]}"

report \
    'AGENTS.md "Panel chrome": @AppStorage binds to UserDefaults.standard, so a test run overwrites the developer'"'"'s real window arrangement — inject UserDefaults the way PanelLayoutStore does.' \
    '@AppStorage' \
    '' \
    "${PRODUCTION_SOURCES[@]}"

report \
    'AGENTS.md "Non-negotiable patterns": use Task { try? await Task.sleep(for:) } — an asyncAfter block outlives the view that scheduled it and cannot be cancelled.' \
    'DispatchQueue\.main\.asyncAfter' \
    '' \
    "${PRODUCTION_SOURCES[@]}"

# Anchored so it cannot fire on a type whose name merely ends in `Alert`, and so `.alert(` — the
# modern modifier this rule exists to steer people towards — is never itself the violation.
report \
    'AGENTS.md "Non-negotiable patterns": the Alert() constructor is deprecated — use the modern .alert(_:isPresented:) modifier.' \
    '(^|[^A-Za-z0-9_.])Alert\(' \
    '' \
    "${PRODUCTION_SOURCES[@]}"

# Both sides of the `||` must be a wait, so this describes the exact form rule 9 names and nothing
# else. It reads one line at a time, so the same mistake split across two lines would still get past;
# every occurrence in this suite has been written on one line, and a pattern that cannot produce a
# false positive is worth more here than one that catches every phrasing.
report \
    'AGENTS.md "UI Changes" rule 9: this waits out the first element'"'"'s entire timeout before it ever looks at the second, so a short-lived one appears and vanishes unseen — use UITestApp.waitForAny([a, b], timeout:).' \
    'waitForExistence\(.*\)[[:space:]]*\|\|.*waitForExistence\(' \
    '' \
    "${UI_TESTS[@]}"

# The single exemption in the whole file: the poll interval inside `UITestApp.waitUntil`. That one
# sleep is what makes every other wait in the suite a poll rather than a fixed pause, so forbidding it
# would forbid the fix. It is pinned to that exact expression rather than to the file, so a
# `Thread.sleep(forTimeInterval: 2)` added to `AppLaunchSupport.swift` tomorrow is still caught.
report \
    'AGENTS.md "Non-negotiable patterns": XCUITests never sleep — too short and the test is flaky, too long and every run pays for it. Poll with .waitForExistence(timeout:) or UITestApp.waitUntil.' \
    '(Thread\.sleep\(|(^|[^A-Za-z0-9_.])u?sleep[[:space:]]*\()' \
    'AppLaunchSupport\.swift:[0-9]+:.*Thread\.sleep\(forTimeInterval: pollInterval\)' \
    "${UI_TESTS[@]}"

if (( violations > 0 )); then
    printf '\n%d house-rule violation(s) across %d rules checked.\n' "$violations" "$rules_checked"
    printf 'Each line cites the rule; AGENTS.md carries the failure that motivated it.\n'
    exit 1
fi

printf '%d house rules checked, no violations.\n' "$rules_checked"

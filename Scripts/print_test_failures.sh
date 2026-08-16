#!/usr/bin/env bash
#
# Prints the failing assertion — message, file and line — out of an `.xcresult`, plus any compiler
# errors out of a build log, into whatever is reading stdout.
#
# This is the step `.github/workflows/ci.yml` runs when a test job goes red, and it exists because
# the alternative is nothing. The result bundle holds every failure's message, file and line, and it
# ships as a several-hundred-megabyte artifact that needs a Mac and an Xcode to open — which in
# practice means nobody does: three consecutive red runs in this repository were diagnosed from the
# *names* of failing tests alone, because the job log's tail never reaches back to the assertion and
# the artifact was effectively opaque.
#
# It is a file rather than forty lines pasted into each job because the UI suite is now sharded and
# there are five test-running macOS jobs. Five pasted copies of an embedded Python walker is the
# duplication AGENTS.md names outright — a rule written twice is a rule that will drift — and this
# one is worth even less duplicated, because a copy that has silently stopped printing failures is
# indistinguishable from a run that had none.
#
# Usage:
#
#     Scripts/print_test_failures.sh [path …]
#
# Each argument is classified by its suffix and missing paths are skipped, so a caller may pass a
# glob that matched nothing:
#
#     *.log        a build/test log, grepped for compiler errors
#     *.xcresult   a candidate result bundle; the newest one that exists is the one summarised
#
# **Compiler errors are printed first, before any bundle.** An xcresult cannot carry one: a test
# target that fails to build produces a bundle with `totalTestCount: 0` and no failures in it, so a
# reader looking only at the bundle sees a summary saying nothing at all while the actual errors sit
# in the build output. Two rounds of one wave here were diagnosed by pulling the raw job log
# instead, which is the archaeology this script exists to replace.
#
# **It always exits 0.** A diagnostic that can redden the run it was reading is worse than none —
# the same argument the coverage steps in the workflow make for themselves. The callers pass
# `continue-on-error: true` as well; this is the half of that promise which survives being run by
# hand on a laptop.

# No `set -e`: every command below is allowed to fail. `pipefail` is off for the same reason, and
# where a pipeline's status would otherwise be misread the result is captured into a variable
# instead — see the compiler-error grep, whose `grep … | head -40 || echo "none"` ancestor could
# never print its fallback, because the `||` was testing `head`'s status and `head` always succeeds.
set -u

logs=()
bundles=()

for arg in "$@"; do
    case "$arg" in
        *.log)      [ -f "$arg" ] && logs+=("$arg") ;;
        *.xcresult) [ -e "$arg" ] && bundles+=("$arg") ;;
        *)          echo "print_test_failures.sh: ignoring '$arg' (expected *.log or *.xcresult)" ;;
    esac
done

for log in ${logs+"${logs[@]}"}; do
    echo "== compile errors in $log, if any"
    errors="$(grep -E '(error|fatal error): ' "$log" | head -40)"
    if [ -n "$errors" ]; then
        printf '%s\n' "$errors"
    else
        echo "   none — the failure is in the results below"
    fi
done

if [ "${#bundles[@]}" -eq 0 ]; then
    echo "no xcresult found"
    exit 0
fi

# Newest first. A job may hand over more than one candidate — the unit job writes its bundle to a
# named path under `.artifacts/` while xcodebuild also leaves one in DerivedData — and the one that
# matters is whichever run actually failed.
#
# `ls -dt` rather than `find`, and the suppression is deliberate rather than a shrug. SC2012 is about
# filenames a line-oriented parse would mangle; every path here is an `.xcresult` this workflow chose
# the name of, two directories deep in a checkout. The portable alternative is not available: sorting
# by mtime with `find` needs `-printf`, which is a GNU extension, and this only ever runs on macOS,
# whose BSD `find` does not have it.
# shellcheck disable=SC2012
bundle="$(ls -dt "${bundles[@]}" 2>/dev/null | head -1)"
echo "== $bundle"

xcrun xcresulttool get test-results summary --path "$bundle" || true

# Every failure with its message, file and line — the part the job log's tail cannot show.
xcrun xcresulttool get test-results tests --path "$bundle" \
    | python3 -c '
import json, sys
def walk(node, path):
    name = node.get("name") or node.get("nodeIdentifier") or ""
    here = path + [name] if name else path
    if node.get("result") == "Failed" and node.get("nodeType") in ("Test Case", "Repetition"):
        print(" / ".join(here), "->", node.get("result"))
    if node.get("nodeType") == "Failure Message":
        print("    ", name)
    for child in node.get("children", []):
        walk(child, here)
data = json.load(sys.stdin)
for root in data.get("testNodes", []):
    walk(root, [])
' || true

exit 0

#!/bin/bash
# SessionStart hook — tells the agent what this machine can actually verify.
#
# Mimic is a macOS app. Every gate that proves anything about the Swift code — `xcodebuild`, the
# XCUITest suite, `tuist generate`, the Release build — needs a Mac with Xcode. A Claude Code on the
# web session runs in a Linux container with no Swift toolchain at all, and `download.swift.org` is
# outside the environment's network policy, so one cannot be installed either.
#
# That gap is worth a hook because of the specific way it fails. AGENTS.md and the two Definitions of
# Done tell an agent to run the suite before calling the work complete. An agent that cannot run it,
# and has not been told so, does one of three things: reports `xcodebuild: command not found` as
# though the repository were broken, silently skips the step, or — the expensive one — writes "tests
# pass" about a suite that never ran. Naming the constraint up front turns all three into the correct
# behaviour, which is to do the work and say plainly which gates were not run.
#
# It installs nothing. There is nothing it could install: the Python gates need only the stdlib and
# `check_house_rules.sh` needs only find/awk/grep, which is the whole point of how they were written.
#
# Read-only, idempotent, and always exits 0 — a session must never fail to start because of this.
set -uo pipefail

root="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"
remote="${CLAUDE_CODE_REMOTE:-}"

have() { command -v "$1" >/dev/null 2>&1; }

missing=()
for tool in swift xcodebuild tuist; do
    have "$tool" || missing+=("$tool")
done

# The pinned generator, from mise.toml. An unpinned Tuist turns "somebody upstream released" into
# "the project no longer builds" — CI hit exactly that, installing 4.202.6 against the 4.152.0 this
# project is developed on, and `tuist install` failed outright.
pinned=$(awk -F'"' '/^tuist *=/ {print $2; exit}' "$root/mise.toml" 2>/dev/null)
tuist_drift=""
if have tuist && [ -n "$pinned" ]; then
    actual=$(tuist version 2>/dev/null | tr -d '[:space:]')
    [ -n "$actual" ] && [ "$actual" != "$pinned" ] && tuist_drift="$actual"
fi

# Locally, stay quiet when the machine is healthy — a hook that prints on every session start on a
# fully equipped Mac is noise. Speak up only when something is actually missing or drifted.
if [ "$remote" != "true" ] && [ ${#missing[@]} -eq 0 ] && [ -z "$tuist_drift" ]; then
    exit 0
fi

echo "## Toolchain available in this session"
echo

if [ ${#missing[@]} -eq 0 ]; then
    echo "Full macOS toolchain present."
else
    echo "**Missing: ${missing[*]}.** This is a Linux container without a Swift toolchain, and"
    echo "\`download.swift.org\` is outside the environment's network policy, so it cannot be installed."
    echo
    echo "**You cannot build Mimic, run any Swift test, or run \`tuist generate\` here.** Do not report"
    echo "a build or a test suite as passing — say which gates you could not run and why. The macOS CI"
    echo "job is what verifies Swift changes on a pull request."
    echo
    echo "What does run here, and is worth running before you push:"
    echo
    echo '```bash'
    echo "python3 Scripts/check_doc_counts.py        # documented counts vs. the tree"
    echo "python3 Scripts/check_module_edges.py      # the module boundaries, from both manifests"
    echo "python3 Scripts/check_compiler_settings.py # deployment floor + Swift settings drift"
    echo "python3 Scripts/check_lockfiles.py         # Package.resolved vs. Tuist/Package.resolved"
    echo "./Scripts/check_house_rules.sh             # the literal house rules (find/awk/grep only)"
    echo '```'
    echo
    echo "They need no toolchain by design, and they cover real regressions: a stale count, a"
    echo "forbidden module edge, a lockfile that has drifted from the one the shipped .pkg was built"
    echo "against. Editing docs, manifests, scripts or the CI workflow is fully verifiable here."
fi

if [ -n "$tuist_drift" ]; then
    echo
    echo "**Tuist version drift: \`$tuist_drift\` installed, \`$pinned\` pinned in mise.toml.**"
    echo "The generator decides what the Xcode project *is*. Run \`mise install\` before trusting a"
    echo "generated workspace — CI has already failed \`tuist install\` outright on exactly this."
fi

exit 0

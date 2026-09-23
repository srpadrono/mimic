#!/bin/bash
# Report toolchain gaps without changing the machine or blocking a session.
set -uo pipefail

repo_root="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"
missing=()
for tool in swift xcodebuild tuist; do
    command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
done

pinned=$(awk -F'"' '/^tuist *=/ {print $2; exit}' "$repo_root/mise.toml" 2>/dev/null)
actual=""
if command -v tuist >/dev/null 2>&1; then
    actual=$(tuist version 2>/dev/null | tr -d '[:space:]')
fi

if [ ${#missing[@]} -eq 0 ] && { [ -z "$pinned" ] || [ -z "$actual" ] || [ "$actual" = "$pinned" ]; }; then
    exit 0
fi

if [ ${#missing[@]} -ne 0 ]; then
    echo "Mimic toolchain unavailable here: ${missing[*]}. Run only the checks this machine supports; report unrun build or test gates accurately."
    echo "Portable checks: python3 Scripts/check_doc_counts.py; python3 Scripts/check_module_edges.py; python3 Scripts/check_compiler_settings.py; python3 Scripts/check_lockfiles.py; ./Scripts/check_house_rules.sh"
fi
if [ -n "$pinned" ] && [ -n "$actual" ] && [ "$actual" != "$pinned" ]; then
    echo "Tuist $actual differs from pinned $pinned. Use mise before generating the workspace."
fi

exit 0

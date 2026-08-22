#!/usr/bin/env bash
# Regenerate docs/images/workspace.png and journeys.png from real application state.
#
# The capture itself is `MimicUITests/DocScreenshotTests`, which drives the app, builds a small but
# realistic project, and screenshots the *window* (not the display — `app.screenshot()` on macOS
# returns everything, Dock included). It attaches each PNG to the result bundle rather than writing
# into the repository, because the UI-test runner is sandboxed and a write to `~/Documents/…` from it
# does not fail cleanly: it hangs, with the attachment already made and nothing on disk.
#
# So this script runs the test and then lifts the attachments out of the .xcresult.
set -euo pipefail

cd "$(dirname "$0")/.."

RESULT_BUNDLE="${TMPDIR:-/tmp}/mimic-doc-screenshots.xcresult"
rm -rf "$RESULT_BUNDLE"

echo "==> Capturing (this drives the real app; do not touch the keyboard)"
# TEST_RUNNER_ prefix is required: xcodebuild only forwards environment variables to the test
# process when they carry it. Without the prefix the test skips and the run silently succeeds.
TEST_RUNNER_MIMIC_CAPTURE_DOCS=1 xcodebuild \
    -workspace Mimic.xcworkspace \
    -scheme Mimic \
    test \
    -destination 'platform=macOS' \
    -only-testing:MimicUITests/DocScreenshotTests \
    -resultBundlePath "$RESULT_BUNDLE" \
    >/dev/null

echo "==> Extracting attachments"
STAGING="${TMPDIR:-/tmp}/mimic-doc-screenshots-out"
rm -rf "$STAGING" && mkdir -p "$STAGING"

xcrun xcresulttool export attachments \
    --path "$RESULT_BUNDLE" \
    --output-path "$STAGING" \
    >/dev/null

# The exporter names files by attachment id and writes `manifest.json` mapping them back. Note it
# does NOT hand back the name the test set: `attachment.name = "workspace.png"` comes out as
# `suggestedHumanReadableName = "workspace_0_<uuid>.png"`, so this matches on the stem rather than on
# equality. Matching exactly finds nothing and the script reports "did not capture" for images it is
# holding in its hand.
python3 - "$STAGING" <<'PY'
import json, pathlib, shutil, sys

staging = pathlib.Path(sys.argv[1])
images = pathlib.Path(__file__).resolve().parent.parent / "docs" / "images"
manifest = json.loads((staging / "manifest.json").read_text())

wanted = ("workspace", "journeys")
found = {}
for test in manifest:
    for att in test.get("attachments", []):
        name = att.get("suggestedHumanReadableName") or att.get("name") or ""
        for stem in wanted:
            if name.startswith(stem):
                found[f"{stem}.png"] = staging / att["exportedFileName"]

missing = {f"{stem}.png" for stem in wanted} - set(found)
if missing:
    raise SystemExit(f"Did not capture: {', '.join(sorted(missing))}")

for name, src in sorted(found.items()):
    dst = images / name
    shutil.copyfile(src, dst)
    print(f"    {dst.relative_to(images.parent.parent)}  ({src.stat().st_size:,} bytes)")
PY

echo "==> Done. Review the images before committing them."

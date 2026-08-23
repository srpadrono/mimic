#!/usr/bin/env bash
# Regenerate the four docs screenshots — workspace and journeys, each in light and dark — from real
# application state.
#
# The capture itself is `MimicUITests/DocScreenshotTests`, which drives the app, builds a small but
# realistic project, and screenshots the *window* (not the display — `app.screenshot()` on macOS
# returns everything, Dock included). It attaches each PNG to the result bundle rather than writing
# into the repository, because the UI-test runner is sandboxed and a write to `~/Documents/…` from it
# does not fail cleanly: it hangs, with the attachment already made and nothing on disk.
#
# So this script runs the test and then lifts the attachments out of the .xcresult.
#
# It runs the test twice, once per appearance, because the appearance is fixed at launch: the app
# reads `-AppleInterfaceStyle` out of NSArgumentDomain when it starts, so one process cannot produce
# both. Each run rebuilds the same project from an empty store, which is what keeps the pair
# identical apart from the appearance.
set -euo pipefail

cd "$(dirname "$0")/.."

STAGING_ROOT="${TMPDIR:-/tmp}/mimic-doc-screenshots-out"
rm -rf "$STAGING_ROOT"

for APPEARANCE in light dark; do
    RESULT_BUNDLE="${TMPDIR:-/tmp}/mimic-doc-screenshots-$APPEARANCE.xcresult"
    rm -rf "$RESULT_BUNDLE"

    echo "==> Capturing $APPEARANCE (this drives the real app; do not touch the keyboard)"
    # TEST_RUNNER_ prefix is required on both: xcodebuild only forwards environment variables to the
    # test process when they carry it. Without the prefix MIMIC_CAPTURE_DOCS is unset, the test
    # skips, and the run silently succeeds having captured nothing.
    TEST_RUNNER_MIMIC_CAPTURE_DOCS=1 \
    TEST_RUNNER_MIMIC_CAPTURE_APPEARANCE="$APPEARANCE" \
    xcodebuild \
        -workspace Mimic.xcworkspace \
        -scheme Mimic \
        test \
        -destination 'platform=macOS' \
        -only-testing:MimicUITests/DocScreenshotTests \
        -resultBundlePath "$RESULT_BUNDLE" \
        >/dev/null

    echo "==> Extracting $APPEARANCE attachments"
    STAGING="$STAGING_ROOT/$APPEARANCE"
    mkdir -p "$STAGING"

    xcrun xcresulttool export attachments \
        --path "$RESULT_BUNDLE" \
        --output-path "$STAGING" \
        >/dev/null

    python3 Scripts/lift_doc_screenshots.py "$STAGING" "$APPEARANCE"
done

echo "==> Done. Review the images before committing them."

#!/bin/bash
# Tuist 4.152 also generates resource bundles whose settings cannot be overridden in PackageSettings.
set -euo pipefail
cd "$(dirname "$0")/.."
tuist install
tuist generate --no-open
python3 Scripts/prepare_xcode_dependencies.py
python3 Scripts/prepare_xcode_dependencies.py --check

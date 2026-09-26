#!/bin/zsh
# Builds a single installer that puts Mimic.app in /Applications and the `mimic` command in
# /usr/local/bin, in one double-click.
#
# It exists because shipping two zips makes the user do the packaging by hand, and one of those
# steps can fail silently when an ad-hoc signed CLI is distributed independently. The installer
# carries both products; release output requires Developer ID signing and notarization.
#
# This mechanism was once described as a measurement of a version that never shipped. Keep the
# packaging rationale here without stale release-number claims; CHANGELOG.md is the release record.
#
# With all three variables set, the script publishes only a signed, notarized, stapled package
# accepted by Gatekeeper. Without notarization, the package stays in .artifacts/package for local
# development. Incomplete signing configuration fails before building; it never downgrades signing.
#
#   MIMIC_SIGN_APP        "Developer ID Application: Name (TEAMID)"  — signs the app and the CLI
#   MIMIC_SIGN_INSTALLER  "Developer ID Installer: Name (TEAMID)"    — signs the .pkg itself
#   MIMIC_NOTARY_PROFILE  a notarytool keychain profile name         — notarises and staples
#
# Store the notary profile once, so no password is ever passed on a command line or held here:
#   xcrun notarytool store-credentials mimic-notary \
#     --apple-id you@example.com --team-id TEAMID --password <app-specific-password>

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

step()  { printf '\n\033[1m== %s ==\033[0m\n' "$1"; }
warn()  { printf '\033[33m%s\033[0m\n' "$1"; }
fail()  { printf '\033[31m%s\033[0m\n' "$1" >&2; exit 1; }

# The package and CLI must agree with the app's marketing version.
VERSION="$(grep -m1 '"MARKETING_VERSION"' Project.swift | sed -E 's/.*: *"([^"]+)".*/\1/')"
[[ -n "$VERSION" ]] || fail "could not read MARKETING_VERSION from Project.swift"

# The CLI cannot read a bundle, so `ControlAPI.releaseVersion` carries the version as a source
# constant and has to be bumped by hand. Nothing enforced that, and v0.9.2 shipped an installer named
# 0.9.2 containing a `mimic` that reported 0.9.1 — the version is the one thing a user checks to know
# whether a fix reached them, so a release that lies about it is worse than no release.
CLI_VERSION="$(grep -m1 'static let releaseVersion' Sources/Domain/Control/ControlResult.swift \
  | sed -E 's/.*"([^"]+)".*/\1/')"
[[ "$CLI_VERSION" == "$VERSION" ]] || fail \
  "version mismatch: MARKETING_VERSION is $VERSION but ControlAPI.releaseVersion is $CLI_VERSION.
Update Sources/Domain/Control/ControlResult.swift to match, then run this again."

# Tuist writes MARKETING_VERSION into the generated project, so a bump that has not been regenerated
# builds the *previous* version under the new name — which is exactly how 0.9.2 first shipped.
if [[ -f Mimic.xcodeproj/project.pbxproj ]]; then
  GENERATED_VERSION="$(grep -m1 -o 'MARKETING_VERSION = [^;]*' Mimic.xcodeproj/project.pbxproj \
    | sed -E 's/MARKETING_VERSION = //')"
  [[ "$GENERATED_VERSION" == "$VERSION" ]] || fail \
    "the generated Xcode project is stale: it has MARKETING_VERSION $GENERATED_VERSION, Project.swift has $VERSION.
Run 'tuist install && tuist generate', then this again."
fi

BUILD_DIR="$ROOT_DIR/.artifacts/package"
STAGE_DIR="$BUILD_DIR/root"
OUT_DIR="$ROOT_DIR/.artifacts/release"
PKG_OUT="$BUILD_DIR/Mimic-$VERSION.pkg"

SIGN_APP="${MIMIC_SIGN_APP:-}"
SIGN_INSTALLER="${MIMIC_SIGN_INSTALLER:-}"
NOTARY_PROFILE="${MIMIC_NOTARY_PROFILE:-}"

# MIMIC_TEAM_ID is the shorthand: give a team and the identities are read out of the keychain.
# Copying "Developer ID Application: Name (TEAMID)" by hand is where this usually goes wrong — the
# name has to match the certificate exactly, and a typo fails several minutes into a build.
TEAM_ID="${MIMIC_TEAM_ID:-}"
if [[ -n "$TEAM_ID" ]]; then
  identity_for() {
    security find-identity -v 2>/dev/null \
      | grep -F "$1: " | grep -F "($TEAM_ID)" \
      | sed -E 's/^.*"(.*)".*$/\1/' | head -1 || true
  }
  [[ -n "$SIGN_APP" ]]       || SIGN_APP="$(identity_for 'Developer ID Application')"
  [[ -n "$SIGN_INSTALLER" ]] || SIGN_INSTALLER="$(identity_for 'Developer ID Installer')"

  if [[ -z "$SIGN_APP" || -z "$SIGN_INSTALLER" ]]; then
    warn "MIMIC_TEAM_ID=$TEAM_ID is set, but the signing pair is incomplete:"
    [[ -z "$SIGN_APP" ]]       && warn "  missing: Developer ID Application  (signs Mimic.app and the mimic binary)"
    [[ -z "$SIGN_INSTALLER" ]] && warn "  missing: Developer ID Installer    (signs the .pkg)"
    warn "Create it in Xcode ▸ Settings ▸ Accounts ▸ Manage Certificates ▸ +, then re-run."
    fail "Requested signing identities were not found; no unsigned replacement will be built."
  fi
fi

if [[ -n "$SIGN_APP" || -n "$SIGN_INSTALLER" || -n "$NOTARY_PROFILE" ]]; then
  [[ -n "$SIGN_APP" && -n "$SIGN_INSTALLER" ]] \
    || fail "Set both MIMIC_SIGN_APP and MIMIC_SIGN_INSTALLER before signing or notarizing."
fi

step "Mimic $VERSION — installer package"
printf 'app signing:       %s\n' "${SIGN_APP:-(none — unsigned)}"
printf 'installer signing: %s\n' "${SIGN_INSTALLER:-(none — unsigned)}"
printf 'notarisation:      %s\n' "${NOTARY_PROFILE:-(none)}"

# .artifacts/ is gitignored and is only ever written by scripts, so clearing our own subtrees is safe.
rm -rf "$BUILD_DIR"
mkdir -p "$STAGE_DIR/Applications" "$STAGE_DIR/usr/local/bin"

step "Build (Release)"
# CODE_SIGN_IDENTITY is applied here rather than after the fact: the hardened runtime has to be in
# place at build time for notarisation to accept the result, and re-signing a built bundle with a
# different identity is where this usually goes wrong.
DERIVED="$BUILD_DIR/DerivedData"
for scheme in Mimic MimicCLI; do
  printf '  %s…\n' "$scheme"
  if [[ -n "$SIGN_APP" ]]; then
    # CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO is not optional here, and it is the one setting that
    # is easy to miss. It defaults to YES, which adds com.apple.security.get-task-allow — the
    # entitlement that lets a debugger attach. `xcodebuild archive` strips it on export; plain
    # `build` does not, so a Release build that is signed and timestamped and looks completely
    # correct is still rejected outright by the notary service:
    #
    #   status: Invalid — "The executable requests the com.apple.security.get-task-allow
    #   entitlement", once per architecture slice, for both the app and the CLI.
    #
    # Nothing in App/Mimic.entitlements asks for it. It is injected, so it has to be turned off
    # here rather than removed from a file.
    xcodebuild -workspace Mimic.xcworkspace -scheme "$scheme" \
      -configuration Release -derivedDataPath "$DERIVED" \
      CODE_SIGN_IDENTITY="$SIGN_APP" CODE_SIGN_STYLE=Manual \
      CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
      OTHER_CODE_SIGN_FLAGS="--timestamp --options runtime" \
      build > "$BUILD_DIR/$scheme.log" 2>&1 \
      || { tail -30 "$BUILD_DIR/$scheme.log"; fail "$scheme failed to build"; }
  else
    xcodebuild -workspace Mimic.xcworkspace -scheme "$scheme" \
      -configuration Release -derivedDataPath "$DERIVED" \
      CODE_SIGN_IDENTITY=- build > "$BUILD_DIR/$scheme.log" 2>&1 \
      || { tail -30 "$BUILD_DIR/$scheme.log"; fail "$scheme failed to build"; }
  fi
done

PRODUCTS="$DERIVED/Build/Products/Release"
[[ -d "$PRODUCTS/Mimic.app" ]] || fail "no Mimic.app at $PRODUCTS"
[[ -f "$PRODUCTS/mimic"     ]] || fail "no mimic binary at $PRODUCTS"
BUILT_APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PRODUCTS/Mimic.app/Contents/Info.plist")"
BUILT_CLI_VERSION="$("$PRODUCTS/mimic" --version | sed -nE 's/^mimic ([0-9]+\.[0-9]+\.[0-9]+) \(control API [^)]+\)$/\1/p')"
[[ "$BUILT_APP_VERSION" == "$VERSION" && "$BUILT_CLI_VERSION" == "$VERSION" ]] \
  || fail "Built app/CLI versions do not match $VERSION; regenerate the workspace and rebuild."
codesign --verify --deep --strict "$PRODUCTS/Mimic.app" || fail "App signature verification failed."
codesign --verify --strict "$PRODUCTS/mimic" || fail "CLI signature verification failed."

step "Stage the payload"
# ditto rather than cp: it preserves the bundle's symlinks and extended attributes, and a copy that
# quietly flattens a framework symlink produces an app that fails to launch only on other machines.
ditto "$PRODUCTS/Mimic.app" "$STAGE_DIR/Applications/Mimic.app"
ditto "$PRODUCTS/mimic"     "$STAGE_DIR/usr/local/bin/mimic"
chmod 755 "$STAGE_DIR/usr/local/bin/mimic"
printf '  Mimic.app  %s\n' "$(du -sh "$STAGE_DIR/Applications/Mimic.app" | cut -f1)"
printf '  mimic      %s (%s)\n' \
  "$(du -h "$STAGE_DIR/usr/local/bin/mimic" | cut -f1)" \
  "$(lipo -archs "$STAGE_DIR/usr/local/bin/mimic" 2>/dev/null || echo '?')"

step "Build the package"
COMPONENT="$BUILD_DIR/component.pkg"
COMPONENTS="$BUILD_DIR/components.plist"
# Installing an update must replace /Applications/Mimic.app, not a relocated test or backup copy.
pkgbuild --analyze --root "$STAGE_DIR" "$COMPONENTS"
python3 - "$COMPONENTS" <<'PY'
import plistlib, sys
from pathlib import Path
path = Path(sys.argv[1])
components = plistlib.loads(path.read_bytes())
app = next(item for item in components if item['RootRelativeBundlePath'] == 'Applications/Mimic.app')
app.update(BundleIsRelocatable=False, BundleOverwriteAction='upgrade')
path.write_bytes(plistlib.dumps(components))
PY
pkgbuild \
  --root "$STAGE_DIR" \
  --component-plist "$COMPONENTS" \
  --identifier "devxa.Mimic.installer" \
  --version "$VERSION" \
  --install-location / \
  "$COMPONENT" > /dev/null

cat > "$BUILD_DIR/distribution.xml" <<DISTRIBUTION
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
    <title>Mimic $VERSION</title>
    <options customize="never" require-scripts="false" hostArchitectures="arm64,x86_64"/>
    <volume-check>
        <allowed-os-versions><os-version min="26.0"/></allowed-os-versions>
    </volume-check>
    <choices-outline><line choice="default"/></choices-outline>
    <choice id="default" title="Mimic">
        <pkg-ref id="devxa.Mimic.installer"/>
    </choice>
    <pkg-ref id="devxa.Mimic.installer" version="$VERSION">component.pkg</pkg-ref>
</installer-gui-script>
DISTRIBUTION

UNSIGNED="$BUILD_DIR/Mimic-$VERSION-unsigned.pkg"
productbuild \
  --distribution "$BUILD_DIR/distribution.xml" \
  --package-path "$BUILD_DIR" \
  "$UNSIGNED" > /dev/null

if [[ -n "$SIGN_INSTALLER" ]]; then
  step "Sign the installer"
  productsign --sign "$SIGN_INSTALLER" --timestamp "$UNSIGNED" "$PKG_OUT"
else
  cp "$UNSIGNED" "$PKG_OUT"
fi

if [[ -n "$NOTARY_PROFILE" ]]; then
  step "Notarise"
  # --wait, because an un-stapled package still shows a warning on the first launch of a machine
  # that is offline, and stapling is the only way to close that gap.
  xcrun notarytool submit "$PKG_OUT" --keychain-profile "$NOTARY_PROFILE" --wait \
    --output-format json > "$BUILD_DIR/notarization.json" \
    || fail "notarisation failed — run: xcrun notarytool log <submission-id> --keychain-profile $NOTARY_PROFILE"
  python3 - "$BUILD_DIR/notarization.json" <<'PY'
import json, sys
with open(sys.argv[1]) as source:
    result = json.load(source)
if result.get('status') != 'Accepted':
    raise SystemExit('Notarization was not accepted; inspect ' + sys.argv[1])
PY
  xcrun stapler staple "$PKG_OUT"
  xcrun stapler validate "$PKG_OUT"
  spctl -a -vvv -t install "$PKG_OUT" > "$BUILD_DIR/gatekeeper.log" 2>&1 \
    || fail "Gatekeeper rejected the package; inspect $BUILD_DIR/gatekeeper.log. No release output was published."
  mkdir -p "$OUT_DIR"
  ditto "$PKG_OUT" "$OUT_DIR/Mimic-$VERSION.pkg"
  PKG_OUT="$OUT_DIR/Mimic-$VERSION.pkg"
else
  warn "Development package only: not notarized, not published to .artifacts/release."
fi

step "Result"
SIZE_BYTES="$(wc -c < "$PKG_OUT" | tr -d ' ')"
printf '%s\n' "$PKG_OUT"
printf 'size: %s bytes (%.1f MB)\n' "$SIZE_BYTES" "$(( SIZE_BYTES / 1048576.0 ))"

[[ -z "$NOTARY_PROFILE" ]] || printf '\nGatekeeper accepted the stapled release package.\n'

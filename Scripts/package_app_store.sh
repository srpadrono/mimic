#!/bin/zsh
# Archives the Mac App Store build of Mimic and, when asked, exports it signed or uploads it to
# App Store Connect.
#
# The store build is the same app as the GitHub installer with three differences: it is built with
# MIMIC_APP_STORE=YES, so it has no update check of its own (the store updates it); it carries no
# `mimic` command, because a store app cannot install one in /usr/local/bin; and it is signed for the
# store, with a provisioning profile, instead of with Developer ID. package_release.sh stays the
# script for the GitHub installer and the Homebrew cask.
#
# Without signing settings it only archives and checks the archive, which is what CI runs. With
# MIMIC_TEAM_ID it also exports a signed installer for the store, and MIMIC_UPLOAD=1 sends that to
# App Store Connect instead. An upload lands in TestFlight and in the app's build list; nothing
# reaches the store until someone submits that build for review in App Store Connect.
#
#   MIMIC_TEAM_ID            the team, e.g. KW6369JJL9; finds "Apple Distribution" and
#                            "3rd Party Mac Developer Installer" identities in the keychain
#   MIMIC_APP_STORE_PROFILE  name or UUID of an installed Mac App Store provisioning profile for
#                            devxa.Mimic. Without it, Xcode manages signing itself
#                            (-allowProvisioningUpdates), which needs an Xcode account or an API key
#   MIMIC_BUILD_NUMBER       CFBundleVersion; each upload needs a higher one than the last. Defaults
#                            to the UTC time, YYYYMMDDHHMM
#   MIMIC_UPLOAD             1 uploads to App Store Connect instead of writing the .pkg
#   MIMIC_ASC_KEY_PATH, MIMIC_ASC_KEY_ID, MIMIC_ASC_ISSUER_ID
#                            an App Store Connect API key for the upload, and for automatic signing
#                            on a Mac without an Xcode account

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

step()  { printf '\n\033[1m== %s ==\033[0m\n' "$1"; }
warn()  { printf '\033[33m%s\033[0m\n' "$1"; }
fail()  { printf '\033[31m%s\033[0m\n' "$1" >&2; exit 1; }

VERSION="$(grep -m1 '"MARKETING_VERSION"' Project.swift | sed -E 's/.*: *"([^"]+)".*/\1/')"
[[ -n "$VERSION" ]] || fail "could not read MARKETING_VERSION from Project.swift"
CLI_VERSION="$(grep -m1 'static let releaseVersion' Sources/Domain/Control/ControlResult.swift \
  | sed -E 's/.*"([^"]+)".*/\1/')"
[[ "$CLI_VERSION" == "$VERSION" ]] || fail \
  "version mismatch: MARKETING_VERSION is $VERSION but ControlAPI.releaseVersion is $CLI_VERSION."
if [[ -f Mimic.xcodeproj/project.pbxproj ]]; then
  GENERATED_VERSION="$(grep -m1 -o 'MARKETING_VERSION = [^;]*' Mimic.xcodeproj/project.pbxproj \
    | sed -E 's/MARKETING_VERSION = //')"
  [[ "$GENERATED_VERSION" == "$VERSION" ]] || fail \
    "the generated Xcode project is stale: it has MARKETING_VERSION $GENERATED_VERSION, Project.swift has $VERSION.
Run 'tuist install && tuist generate', then this again."
fi
DEPLOYMENT_TARGET="$(grep -m1 '"MACOSX_DEPLOYMENT_TARGET"' Project.swift | sed -E 's/.*: *"([^"]+)".*/\1/')"
[[ -n "$DEPLOYMENT_TARGET" ]] || fail "could not read MACOSX_DEPLOYMENT_TARGET from Project.swift"

BUILD_NUMBER="${MIMIC_BUILD_NUMBER:-$(date -u +%Y%m%d%H%M)}"
[[ "$BUILD_NUMBER" =~ '^[0-9]+(\.[0-9]+){0,2}$' ]] \
  || fail "MIMIC_BUILD_NUMBER must be one to three dot-separated numbers, not '$BUILD_NUMBER'."

TEAM_ID="${MIMIC_TEAM_ID:-}"
PROFILE="${MIMIC_APP_STORE_PROFILE:-}"
UPLOAD="${MIMIC_UPLOAD:-}"
KEY_PATH="${MIMIC_ASC_KEY_PATH:-}"
KEY_ID="${MIMIC_ASC_KEY_ID:-}"
ISSUER_ID="${MIMIC_ASC_ISSUER_ID:-}"

[[ -z "$UPLOAD" || -n "$TEAM_ID" ]] || fail "MIMIC_UPLOAD needs MIMIC_TEAM_ID: only a signed build can be uploaded."
[[ -z "$PROFILE" || -n "$TEAM_ID" ]] || fail "MIMIC_APP_STORE_PROFILE needs MIMIC_TEAM_ID."
if [[ -n "$KEY_PATH$KEY_ID$ISSUER_ID" ]]; then
  [[ -n "$KEY_PATH" && -n "$KEY_ID" && -n "$ISSUER_ID" ]] \
    || fail "Set all three of MIMIC_ASC_KEY_PATH, MIMIC_ASC_KEY_ID and MIMIC_ASC_ISSUER_ID, or none."
  [[ -f "$KEY_PATH" ]] || fail "no API key file at $KEY_PATH"
fi

SIGN_APP=""
SIGN_INSTALLER=""
if [[ -n "$TEAM_ID" ]]; then
  identity_for() {
    security find-identity -v 2>/dev/null \
      | grep -F "$1: " | grep -F "($TEAM_ID)" \
      | sed -E 's/^.*"(.*)".*$/\1/' | head -1 || true
  }
  SIGN_APP="$(identity_for 'Apple Distribution')"
  SIGN_INSTALLER="$(identity_for '3rd Party Mac Developer Installer')"
  # With a named profile the certificates must already be in the keychain. Automatic signing can
  # create them, so only a manual export insists.
  if [[ -n "$PROFILE" && ( -z "$SIGN_APP" || -z "$SIGN_INSTALLER" ) ]]; then
    warn "MIMIC_APP_STORE_PROFILE is set, but the store signing pair for $TEAM_ID is incomplete:"
    [[ -z "$SIGN_APP" ]]       && warn "  missing: Apple Distribution                 (signs Mimic.app)"
    [[ -z "$SIGN_INSTALLER" ]] && warn "  missing: 3rd Party Mac Developer Installer  (signs the store .pkg; Apple calls it Mac Installer Distribution)"
    fail "Requested signing identities were not found."
  fi
fi

BUILD_DIR="$ROOT_DIR/.artifacts/app-store"
ARCHIVE="$BUILD_DIR/Mimic.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"

if [[ -z "$TEAM_ID" ]]; then
  SIGNING="none" RESULT="archive and check only"
elif [[ -n "$PROFILE" ]]; then
  SIGNING="manual, profile $PROFILE" RESULT="signed .pkg"
else
  SIGNING="automatic (Xcode manages the certificate and profile)" RESULT="signed .pkg"
fi
[[ -z "$UPLOAD" ]] || RESULT="upload to App Store Connect"

step "Mimic $VERSION ($BUILD_NUMBER) — Mac App Store"
printf 'team:     %s\n' "${TEAM_ID:-(none)}"
printf 'signing:  %s\n' "$SIGNING"
printf 'result:   %s\n' "$RESULT"

# .artifacts/ is gitignored and only ever written by scripts, so clearing our own subtree is safe.
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

step "Archive (Release, MIMIC_APP_STORE=YES)"
# Archived ad hoc. The export below signs everything again with the distribution certificate and
# embeds the profile; naming the profile here instead would apply it to every target, and the
# frameworks and package bundles refuse one.
xcodebuild -workspace Mimic.xcworkspace -scheme Mimic \
  -configuration Release -destination 'generic/platform=macOS' \
  -archivePath "$ARCHIVE" -derivedDataPath "$BUILD_DIR/DerivedData" \
  MIMIC_APP_STORE=YES CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  MACOSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" CODE_SIGN_IDENTITY=- \
  archive > "$BUILD_DIR/archive.log" 2>&1 \
  || { tail -30 "$BUILD_DIR/archive.log"; fail "the archive failed to build; the whole log is $BUILD_DIR/archive.log"; }

step "Check the archive"
plist() { /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null || true; }
# An archive with anything besides the app in it is a "generic" archive, which has no
# ApplicationProperties and which App Store Connect will not take.
APP_PATH="$(plist "$ARCHIVE/Info.plist" ApplicationProperties:ApplicationPath)"
[[ "$APP_PATH" == "Applications/Mimic.app" ]] \
  || fail "not an app archive (ApplicationPath '$APP_PATH'); something besides Mimic.app was installed into it:
$(cd "$ARCHIVE/Products" 2>/dev/null && find . -maxdepth 4 | sort)"
EXTRA="$(cd "$ARCHIVE/Products" && find . -mindepth 1 -maxdepth 2 ! -path ./Applications ! -path ./Applications/Mimic.app)"
[[ -z "$EXTRA" ]] || fail "the archive carries more than Mimic.app:
$EXTRA"
APP="$ARCHIVE/Products/Applications/Mimic.app"
INFO="$APP/Contents/Info.plist"
[[ "$(plist "$INFO" MimicAppStoreBuild)" == "YES" ]] || fail "Mimic.app was not built as the App Store variant."
[[ "$(plist "$INFO" CFBundleShortVersionString)" == "$VERSION" ]] || fail "Mimic.app does not report version $VERSION."
[[ "$(plist "$INFO" CFBundleVersion)" == "$BUILD_NUMBER" ]] || fail "Mimic.app does not report build $BUILD_NUMBER."
[[ -f "$APP/Contents/Resources/PrivacyInfo.xcprivacy" ]] || fail "Mimic.app has no privacy manifest."
ENTITLEMENTS="$BUILD_DIR/entitlements.plist"
codesign -d --entitlements - --xml "$APP" > "$ENTITLEMENTS" 2>/dev/null || true
[[ "$(plist "$ENTITLEMENTS" com.apple.security.app-sandbox)" == "true" ]] \
  || fail "Mimic.app is not sandboxed, and the App Store takes only sandboxed apps."
printf '  app archive, store variant, version %s (%s), sandboxed\n' "$VERSION" "$BUILD_NUMBER"

if [[ -z "$TEAM_ID" ]]; then
  warn "No MIMIC_TEAM_ID: archived and checked only. Nothing was signed or uploaded."
  printf '%s\n' "$ARCHIVE"
  exit 0
fi

if [[ -n "$UPLOAD" ]]; then step "Sign and upload"; else step "Sign and export"; fi
OPTIONS="$BUILD_DIR/ExportOptions.plist"
python3 - "$OPTIONS" "$TEAM_ID" "$PROFILE" "$SIGN_APP" "$SIGN_INSTALLER" "$UPLOAD" <<'PY'
import plistlib, sys
path, team, profile, app_identity, installer_identity, upload = sys.argv[1:]
options = {
    'method': 'app-store-connect',
    'teamID': team,
    'destination': 'upload' if upload else 'export',
    # The build number comes from MIMIC_BUILD_NUMBER, so App Store Connect must not rewrite it.
    'manageAppVersionAndBuildNumber': False,
    'uploadSymbols': True,
}
if profile:
    options.update(
        signingStyle='manual',
        signingCertificate=app_identity,
        installerSigningCertificate=installer_identity,
        provisioningProfiles={'devxa.Mimic': profile},
    )
else:
    options['signingStyle'] = 'automatic'
with open(path, 'wb') as output:
    plistlib.dump(options, output)
PY

export_args=(-exportArchive -archivePath "$ARCHIVE" -exportPath "$EXPORT_DIR" -exportOptionsPlist "$OPTIONS")
[[ -n "$PROFILE" ]] || export_args+=(-allowProvisioningUpdates)
if [[ -n "$KEY_PATH" ]]; then
  export_args+=(-authenticationKeyPath "$KEY_PATH" -authenticationKeyID "$KEY_ID" -authenticationKeyIssuerID "$ISSUER_ID")
fi
xcodebuild "${export_args[@]}" > "$BUILD_DIR/export.log" 2>&1 \
  || { tail -30 "$BUILD_DIR/export.log"; fail "the export failed; the whole log is $BUILD_DIR/export.log"; }

if [[ -n "$UPLOAD" ]]; then
  printf '\nUploaded Mimic %s (%s). App Store Connect processes it for a few minutes before it shows\n' "$VERSION" "$BUILD_NUMBER"
  printf 'under the app'"'"'s builds; submitting it for review is a separate, manual step.\n'
else
  PKG="$(find "$EXPORT_DIR" -maxdepth 1 -name '*.pkg' | head -1)"
  [[ -n "$PKG" ]] || fail "the export wrote no .pkg; see $BUILD_DIR/export.log"
  printf '\n%s\n' "$PKG"
  printf 'Upload it with Transporter, or run this again with MIMIC_UPLOAD=1.\n'
fi

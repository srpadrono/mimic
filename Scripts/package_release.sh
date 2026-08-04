#!/bin/zsh
# Builds a single installer that puts Mimic.app in /Applications and the `mimic` command in
# /usr/local/bin, in one double-click.
#
# It exists because shipping two zips makes the user do the packaging by hand, and one of those
# steps fails silently. Measured on the v1.7.0 assets: the CLI ships ad-hoc signed with no team
# identifier, so a copy carrying the download quarantine flag is killed with SIGKILL — exit 137,
# nothing on stdout or stderr. Someone follows the instructions, runs `mimic --version`, and gets
# silence. An installer payload is laid down without that flag, and the postinstall below strips it
# anyway, so the problem cannot reach a user.
#
# Signing is opt-in through the environment. With the three variables set the output is signed,
# notarised and stapled, and opens with no warning at all. Without them it still builds, so the
# packaging can be developed and tested before anyone buys a certificate — but it prints what that
# costs the user, because an unsigned installer is still blocked by Gatekeeper.
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

# MARKETING_VERSION is the one place a version is written; the tag, the bundle and `mimic state`
# all read from it, so the installer must too rather than carrying its own copy.
VERSION="$(grep -m1 '"MARKETING_VERSION"' Project.swift | sed -E 's/.*: *"([^"]+)".*/\1/')"
[[ -n "$VERSION" ]] || fail "could not read MARKETING_VERSION from Project.swift"

BUILD_DIR="$ROOT_DIR/.artifacts/package"
STAGE_DIR="$BUILD_DIR/root"
SCRIPTS_DIR="$BUILD_DIR/scripts"
OUT_DIR="$ROOT_DIR/.artifacts/release"
PKG_OUT="$OUT_DIR/Mimic-$VERSION.pkg"

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
      | grep "$1: " | grep "($TEAM_ID)" \
      | sed -E 's/^.*"(.*)".*$/\1/' | head -1
  }
  [[ -n "$SIGN_APP" ]]       || SIGN_APP="$(identity_for 'Developer ID Application')"
  [[ -n "$SIGN_INSTALLER" ]] || SIGN_INSTALLER="$(identity_for 'Developer ID Installer')"

  if [[ -z "$SIGN_APP" || -z "$SIGN_INSTALLER" ]]; then
    warn "MIMIC_TEAM_ID=$TEAM_ID is set, but this Mac has only part of the pair:"
    [[ -z "$SIGN_APP" ]]       && warn "  missing: Developer ID Application  (signs Mimic.app and the mimic binary)"
    [[ -z "$SIGN_INSTALLER" ]] && warn "  missing: Developer ID Installer    (signs the .pkg)"
    warn "Create it in Xcode ▸ Settings ▸ Accounts ▸ Manage Certificates ▸ +, then re-run."
    # Drop both rather than half-sign. A signed installer wrapping an unsigned app is still
    # rejected by Gatekeeper, so it buys nothing and it looks like it should have worked.
    SIGN_APP=""
    SIGN_INSTALLER=""
    warn "Building fully unsigned instead, so the result is not ambiguous."
  fi
fi

step "Mimic $VERSION — installer package"
printf 'app signing:       %s\n' "${SIGN_APP:-(none — unsigned)}"
printf 'installer signing: %s\n' "${SIGN_INSTALLER:-(none — unsigned)}"
printf 'notarisation:      %s\n' "${NOTARY_PROFILE:-(none)}"

# .artifacts/ is gitignored and is only ever written by scripts, so clearing our own subtrees is safe.
rm -rf "$BUILD_DIR"
mkdir -p "$STAGE_DIR/Applications" "$STAGE_DIR/usr/local/bin" "$SCRIPTS_DIR" "$OUT_DIR"

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

step "Postinstall script"
# Installer payloads are not quarantined, so this is belt and braces — but it is cheap, and it is
# the difference between "should be fine" and "cannot bite the user".
cat > "$SCRIPTS_DIR/postinstall" <<'POSTINSTALL'
#!/bin/bash
# Strip the download quarantine flag from everything we just installed. Without it an ad-hoc-signed
# `mimic` is killed with SIGKILL and prints nothing, which reads to the user as the tool not working.
set -uo pipefail
xattr -dr com.apple.quarantine /Applications/Mimic.app  2>/dev/null || true
xattr -d  com.apple.quarantine /usr/local/bin/mimic     2>/dev/null || true
exit 0
POSTINSTALL
chmod +x "$SCRIPTS_DIR/postinstall"

step "Build the package"
COMPONENT="$BUILD_DIR/component.pkg"
pkgbuild \
  --root "$STAGE_DIR" \
  --scripts "$SCRIPTS_DIR" \
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
    || fail "notarisation failed — run: xcrun notarytool log <submission-id> --keychain-profile $NOTARY_PROFILE"
  xcrun stapler staple "$PKG_OUT"
fi

step "Result"
SIZE_BYTES="$(wc -c < "$PKG_OUT" | tr -d ' ')"
printf '%s\n' "$PKG_OUT"
printf 'size: %s bytes (%.1f MB)\n' "$SIZE_BYTES" "$(( SIZE_BYTES / 1048576.0 ))"

# The verdict that matters, and the only honest way to report it: ask Gatekeeper.
printf '\ngatekeeper: '
if spctl -a -vvv -t install "$PKG_OUT" 2>&1 | grep -q accepted; then
  printf '\033[32maccepted — installs with no warning\033[0m\n'
else
  printf '\033[33mrejected\033[0m\n'
  # Name the step that is actually missing. Reporting "not signed" at a package that carries a
  # valid Developer ID signature sends the reader to fix something that is already done.
  if [[ -z "$SIGN_APP" ]]; then
    warn "Nothing is signed. Set MIMIC_TEAM_ID (or MIMIC_SIGN_APP and MIMIC_SIGN_INSTALLER)."
  elif [[ -z "$NOTARY_PROFILE" ]]; then
    warn "Signed, but not notarised — and Apple has required notarisation for downloaded software"
    warn "since Catalina, so signing alone does not clear this. Store credentials once:"
    warn "  xcrun notarytool store-credentials mimic-notary --apple-id <id> --team-id $TEAM_ID"
    warn "then re-run with MIMIC_NOTARY_PROFILE=mimic-notary."
  else
    warn "Signed and notarised, yet still rejected. Check the log for the submission:"
    warn "  xcrun notarytool history --keychain-profile $NOTARY_PROFILE"
  fi
  warn "Until it is accepted, the user must open System Settings ▸ Privacy & Security and click"
  warn "Open Anyway — the Control-click ▸ Open shortcut was removed in macOS Sequoia."
fi

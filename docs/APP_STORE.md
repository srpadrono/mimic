# Mac App Store

Mimic ships two ways. The signed `.pkg` on GitHub, which the Homebrew cask installs, is described in [Contributing ▸ Releases](../CONTRIBUTING.md#releases). This page covers the Mac App Store build: how it differs, how to build and upload it, and what App Store Connect needs.

## What is different

| | GitHub `.pkg` and Homebrew | Mac App Store |
| --- | --- | --- |
| Updates | Mimic checks GitHub daily and installs the `.pkg` (unless `updates.disabled` is set) | The App Store updates it. There is no Check for Updates item, and no check runs |
| `mimic` command | Installed in `/usr/local/bin` | Not included; a store app cannot install files outside itself |
| Signing | Developer ID, notarized | Apple Distribution, with a Mac App Store provisioning profile; Apple signs the copy it ships |
| Built by | `Scripts/package_release.sh` | `Scripts/package_app_store.sh` |

Both are the same app with the same bundle identifier, `devxa.Mimic`, and the same sandbox container, so projects carry over when someone moves from one to the other. `mimic`, if installed from the `.pkg` or Homebrew, finds and drives the store copy in `/Applications` too. `mimic app update-check` still reports GitHub releases, which can be ahead of the store while a version is in review.

The store build is the Release configuration with `MIMIC_APP_STORE=YES`. Project.swift turns that into the `MIMIC_APP_STORE` compilation condition for AppFeatures, which makes `DistributionChannel.current` return `.appStore`, and writes `MimicAppStoreBuild` into the Info.plist so the script can check which variant it archived. The `MimicCLI` target has `SKIP_INSTALL`, so the archive holds only `Mimic.app`.

## Sandbox

The app was already sandboxed for the `.pkg`, and the store needs nothing more than `App/Mimic.entitlements` grants:

- `network.server` for the mock server and the control API, which bind `127.0.0.1` only;
- `network.client` for forwarding unmocked requests to real backends;
- `files.user-selected.read-write` for opening and saving project exports, HAR files and specs that the user picks.

The project store, the discovery file and backups all live in the app's container.

## Build and upload

Run on a Mac with the workspace generated (`tuist install && tuist generate --no-open`):

```sh
# Archive and check only; nothing is signed. CI's Release build runs this.
./Scripts/package_app_store.sh

# Sign with Xcode-managed signing and upload to App Store Connect.
MIMIC_TEAM_ID=KW6369JJL9 MIMIC_UPLOAD=1 ./Scripts/package_app_store.sh
```

With `MIMIC_TEAM_ID` alone it writes a signed store `.pkg` to `.artifacts/app-store/export` for Transporter instead of uploading. Without `MIMIC_APP_STORE_PROFILE`, Xcode creates or reuses the Apple Distribution certificate, the Mac Installer Distribution certificate and the provisioning profile itself, which needs the team's Apple ID signed in under Xcode ▸ Settings ▸ Accounts, or an App Store Connect API key in `MIMIC_ASC_KEY_PATH`, `MIMIC_ASC_KEY_ID` and `MIMIC_ASC_ISSUER_ID` with the Admin role. To sign manually, install the two certificates and a Mac App Store profile for `devxa.Mimic` and name the profile in `MIMIC_APP_STORE_PROFILE`. The script header lists every setting.

Each upload needs a build number higher than the last one for that version. The script uses the UTC time (`YYYYMMDDHHMM`) unless `MIMIC_BUILD_NUMBER` says otherwise. The version is `MARKETING_VERSION`, the same as the GitHub release.

An upload goes to TestFlight and the app's build list in App Store Connect. Nothing is released until the build is chosen for a version and submitted for review there.

Before a store submission, run the [release regression gate](RELEASE_REGRESSION.md) scenarios that do not need `mimic` against the uploaded build from TestFlight.

## App Store Connect

What the app record needs, and the answers that follow from the code:

- **Bundle ID:** `devxa.Mimic`. **SKU:** any unique text, for example `mimic-macos`.
- **Category:** Developer Tools, matching `LSApplicationCategoryType`.
- **Privacy:** Data Not Collected. Mimic has no accounts, analytics or tracking; requests it serves and forwards stay on the Mac and go only to the backends the user configures. `App/Resources/PrivacyInfo.xcprivacy` declares the same, plus its use of user defaults and system uptime.
- **Encryption:** the Info.plist sets `ITSAppUsesNonExemptEncryption` to `false`, because Mimic only uses HTTPS and SHA-256, so no export compliance question comes up per build.
- **Age rating:** no objectionable content; the questionnaire's answers are all "None" or "No".
- **Screenshots:** at least one, 16:10, at 1280 × 800, 1440 × 900, 2560 × 1600 or 2880 × 1800.
- **Support URL** and **Privacy Policy URL**: required; the landing page can host both.
- **Review notes:** explain that Mimic runs a mock HTTP server on `127.0.0.1`, that the welcome window opens a sample project that needs no setup, and that after pressing Run, `curl -i http://127.0.0.1:8080/account-summary` in Terminal gets the mocked response.

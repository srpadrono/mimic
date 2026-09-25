import DesignSystem
import Domain
import SwiftUI

/// The window's whole update conversation, in one sheet.
///
/// Follows the shared sheet convention: a sentence-case heading, `DSSpacing.lg` between the heading,
/// the body and the button row, and a trailing button row with the confirming action last. Every
/// state renders from ``UpdateService/Phase`` and nothing else, so there is no arrangement of flags
/// that can put a progress bar under a heading saying the app is up to date.
struct UpdateSheet: View {

    let service: UpdateService

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpacing.lg) {
            heading

            body(for: service.phase)

            Divider()

            HStack(spacing: DSSpacing.md) {
                // `.lineLimit(1)` and `.layoutPriority(1)` on the buttons together, because the row
                // has four controls in it and SwiftUI resolves an over-full `HStack` by compressing
                // whatever will compress. At 460pt it chose the buttons: "Skip this version"
                // rendered as "Skip this versi…" — a truncated *control label*, which is the one
                // string in a row that must never be guessed at — while the checkbox wrapped onto
                // two lines. Widening alone would fix today's strings and leave the next longer one
                // to find it again.
                Toggle("Check automatically", isOn: automaticChecks)
                    .toggleStyle(.checkbox)
                    .font(DSTypography.label)
                    .foregroundStyle(DSColors.labelSecondary)
                    .lineLimit(1)
                    .accessibilityIdentifier("update.automaticToggle")
                    .accessibilityLabel("Check for updates automatically")

                Spacer(minLength: DSSpacing.md)

                buttons(for: service.phase)
                    .lineLimit(1)
                    .layoutPriority(1)
            }
        }
        .padding(DSSpacing.lg)
        .frame(minWidth: DSSheetWidth.medium, idealWidth: DSSheetWidth.medium)
        .interactiveDismissDisabled(service.phase.isBusy)
    }

    private var automaticChecks: Binding<Bool> {
        Binding(get: { service.checksAutomatically }, set: { service.checksAutomatically = $0 })
    }

    // MARK: - Heading

    @ViewBuilder
    private var heading: some View {
        Text(title(for: service.phase))
            .font(DSTypography.title)
            .foregroundStyle(DSColors.labelPrimary)
            .accessibilityIdentifier("update.title")
    }

    private func title(for phase: UpdateService.Phase) -> String {
        switch phase {
        case .idle, .checking:
            "Checking for updates"
        case .upToDate:
            "You're up to date"
        case .available(let release):
            "Mimic \(release.version) is available"
        case .downloading(let release, _):
            "Downloading Mimic \(release.version)"
        case .readyToInstall(let release, _):
            "Mimic \(release.version) is ready to install"
        case .installing:
            "Preparing to quit and install"
        case .failed:
            "Couldn't complete the update"
        }
    }

    // MARK: - Body

    @ViewBuilder
    private func body(for phase: UpdateService.Phase) -> some View {
        switch phase {
        case .idle, .checking:
            HStack(spacing: DSSpacing.smPlus) {
                ProgressView().controlSize(.small)
                Text("Asking GitHub for the newest release\u{2026}")
                    .font(DSTypography.body)
                    .foregroundStyle(DSColors.labelSecondary)
            }
            .accessibilityIdentifier("update.checking")

        case .upToDate(let installed):
            Text("Mimic \(installed.description) is the newest version.")
                .font(DSTypography.body)
                .foregroundStyle(DSColors.labelSecondary)
                .accessibilityIdentifier("update.upToDate")

        case .available(let release):
            VStack(alignment: .leading, spacing: DSSpacing.smPlus) {
                Text("You have \(service.installedVersionDescription). "
                    + "The installer is \(release.asset.sizeInBytes.formatted(.byteCount(style: .file))).")
                    .font(DSTypography.body)
                    .foregroundStyle(DSColors.labelSecondary)
                    .accessibilityIdentifier("update.summary")

                releaseNotes(release)

                Text("Installing quits Mimic and updates the mimic command-line tool. "
                    + "Your projects are preserved.")
                    .font(DSTypography.body)
                    .foregroundStyle(DSColors.labelSecondary)
                    .accessibilityIdentifier("update.installNote")
            }

        case .downloading(let release, let fraction):
            VStack(alignment: .leading, spacing: DSSpacing.sm) {
                ProgressView(value: fraction)
                    .accessibilityIdentifier("update.progress")
                    .accessibilityLabel("Download progress")
                Text("\(Int(fraction * 100))% of "
                    + "\(release.asset.sizeInBytes.formatted(.byteCount(style: .file)))")
                    .font(DSTypography.code)
                    .foregroundStyle(DSColors.labelSecondary)
                    .monospacedDigit()
                    .accessibilityIdentifier("update.progressLabel")
            }

        case .readyToInstall:
            VStack(alignment: .leading, spacing: DSSpacing.smPlus) {
                // Naming the checks is not decoration: it is the difference between "this app
                // downloaded something and wants to run it" and a claim the user can evaluate.
                Label("Checksum and developer signature verified",
                      systemImage: "checkmark.seal")
                    .font(DSTypography.body)
                    .foregroundStyle(DSColors.successText)
                    .accessibilityIdentifier("update.verified")

                Text("Mimic will save your work, take a copy of your projects, then quit and open "
                    + "the installer. macOS will ask for your password.")
                    .font(DSTypography.body)
                    .foregroundStyle(DSColors.labelSecondary)
                    .accessibilityIdentifier("update.readyNote")
            }

        case .installing:
            HStack(spacing: DSSpacing.smPlus) {
                ProgressView().controlSize(.small)
                Text("Saving your work and opening the installer…")
                    .font(DSTypography.body)
                    .foregroundStyle(DSColors.labelSecondary)
            }
            .accessibilityIdentifier("update.installing")

        case .failed(let message):
            VStack(alignment: .leading, spacing: DSSpacing.smPlus) {
                Text(message)
                    .font(DSTypography.body)
                    .foregroundStyle(DSColors.labelPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("update.failure")

                Link("Open the releases page", destination: UpdateFeed.releasesPageURL)
                    .font(DSTypography.label)
                    .accessibilityIdentifier("update.releasesLink")
                    .accessibilityLabel("Open the releases page")
            }
        }
    }

    /// The notes, scrollable and selectable, capped so a long release cannot push the buttons off
    /// screen.
    ///
    /// Plain text rather than rendered Markdown: `AttributedString(markdown:)` drops list bullets and
    /// silently returns nothing at all for input it cannot parse, which would turn a formatting
    /// quirk in a release note into a blank panel where the reasons to update should be.
    @ViewBuilder
    private func releaseNotes(_ release: UpdateRelease) -> some View {
        ScrollView {
            Text(release.notes.isEmpty ? "This release has no notes." : release.notes)
                .font(DSTypography.body)
                .foregroundStyle(DSColors.labelPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(DSSpacing.smPlus)
        }
        .frame(height: 180)
        .background(DSColors.codeWell)
        .clipShape(RoundedRectangle(cornerRadius: DSCornerRadius.md))
        .accessibilityIdentifier("update.notes")
        // `.description`, not the value: `accessibilityLabel` takes a `LocalizedStringKey`, and
        // interpolating a type it does not know falls back to a debug description.
        .accessibilityLabel("Release notes for Mimic \(release.version.description)")
    }

    // MARK: - Buttons

    @ViewBuilder
    private func buttons(for phase: UpdateService.Phase) -> some View {
        switch phase {
        case .idle, .checking:
            DSButton("Cancel", variant: .ghost, size: .medium, identifier: "update.cancelCheck") {
                service.dismiss()
            }
            .accessibilityIdentifier("update.cancelCheckButton")
            .accessibilityLabel("Cancel")
            .keyboardShortcut(.cancelAction)

        case .upToDate:
            DSButton("Done", variant: .primary, size: .medium, identifier: "update.done") {
                service.dismiss()
            }
            .accessibilityIdentifier("update.doneButton")
            .accessibilityLabel("Done")
            .keyboardShortcut(.defaultAction)

        case .available:
            DSButton("Skip this version", variant: .ghost, size: .medium, identifier: "update.skip") {
                service.skipCurrentVersion()
            }
            .accessibilityIdentifier("update.skipButton")
            .accessibilityLabel("Skip this version")

            DSButton("Later", variant: .secondary, size: .medium, identifier: "update.later") {
                service.dismiss()
            }
            .accessibilityIdentifier("update.laterButton")
            .accessibilityLabel("Later")
            .keyboardShortcut(.cancelAction)

            DSButton("Download", variant: .primary, size: .medium, identifier: "update.download") {
                service.downloadAndPrepare()
            }
            .accessibilityIdentifier("update.downloadButton")
            .accessibilityLabel("Download the update")
            .keyboardShortcut(.defaultAction)

        case .downloading:
            DSButton("Cancel", variant: .ghost, size: .medium, identifier: "update.cancelDownload") {
                service.dismiss()
            }
            .accessibilityIdentifier("update.cancelDownloadButton")
            .accessibilityLabel("Cancel the download")
            .keyboardShortcut(.cancelAction)

        case .readyToInstall:
            DSButton("Later", variant: .secondary, size: .medium, identifier: "update.installLater") {
                service.dismiss()
            }
            .accessibilityIdentifier("update.installLaterButton")
            .accessibilityLabel("Later")
            .keyboardShortcut(.cancelAction)

            DSButton("Quit and install", variant: .primary, size: .medium, identifier: "update.install") {
                service.installNow()
            }
            .accessibilityIdentifier("update.installButton")
            .accessibilityLabel("Quit Mimic and install the update")
            .keyboardShortcut(.defaultAction)

        case .installing:
            Text("Please wait…")
                .font(DSTypography.label)
                .foregroundStyle(DSColors.labelSecondary)
                .accessibilityIdentifier("update.installingStatus")

        case .failed:
            DSButton("Close", variant: .secondary, size: .medium, identifier: "update.closeFailure") {
                service.dismiss()
            }
            .accessibilityIdentifier("update.closeFailureButton")
            .accessibilityLabel("Close")
            .keyboardShortcut(.cancelAction)

            DSButton("Try again", variant: .primary, size: .medium, identifier: "update.retry") {
                service.checkForUpdates()
            }
            .accessibilityIdentifier("update.retryButton")
            .accessibilityLabel("Try again")
            .keyboardShortcut(.defaultAction)
        }
    }
}

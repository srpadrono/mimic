import DesignSystem
import Domain
import SwiftUI

/// The window's whole update conversation, in one sheet.
///
/// App icon beside a headline title and summary, the phase body, then a footer with the automatic
/// check toggle and the phase buttons. Every state renders from ``UpdateService/Phase`` alone.
struct UpdateSheet: View {

    let service: UpdateService

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpacing.lg) {
            heading

            body(for: service.phase)

            HStack(spacing: DSSpacing.sm) {
                // The buttons keep one line and take priority, so a narrow row never truncates a
                // control label.
                Toggle("Check automatically", isOn: automaticChecks)
                    .toggleStyle(.checkbox)
                    .font(DSTypography.callout)
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
        .padding(DSSpacing.xl)
        .frame(width: DSSheetWidth.medium)
        .background(DSColors.sheet)
        .interactiveDismissDisabled(service.phase.isBusy)
    }

    private var automaticChecks: Binding<Bool> {
        Binding(get: { service.checksAutomatically }, set: { service.checksAutomatically = $0 })
    }

    // MARK: - Heading

    private var heading: some View {
        HStack(alignment: .top, spacing: DSSpacing.md) {
            Image("MimicLogo")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 56, height: 56)
                // App-icon squircle, not a control corner.
                .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: DSSpacing.xs) {
                Text(title(for: service.phase))
                    .font(DSTypography.headline)
                    .foregroundStyle(DSColors.labelPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("update.title")

                subtitle(for: service.phase)
            }
            .padding(.top, DSSpacing.sm)
        }
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

    @ViewBuilder
    private func subtitle(for phase: UpdateService.Phase) -> some View {
        switch phase {
        case .upToDate(let installed):
            subtitleText("Mimic \(installed.description) is the newest version.")
                .accessibilityIdentifier("update.upToDate")
        case .available(let release):
            subtitleText("You have \(service.installedVersionDescription). "
                + "The download is \(release.asset.sizeInBytes.formatted(.byteCount(style: .file))).")
                .accessibilityIdentifier("update.summary")
        case .idle, .checking, .downloading, .readyToInstall, .installing, .failed:
            EmptyView()
        }
    }

    private func subtitleText(_ text: String) -> some View {
        Text(text)
            .font(DSTypography.callout)
            .foregroundStyle(DSColors.labelSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Body

    @ViewBuilder
    private func body(for phase: UpdateService.Phase) -> some View {
        switch phase {
        case .idle, .checking:
            HStack(spacing: DSSpacing.sm) {
                ProgressView().controlSize(.small)
                Text("Asking GitHub for the newest release\u{2026}")
                    .font(DSTypography.body)
                    .foregroundStyle(DSColors.labelSecondary)
            }
            .accessibilityIdentifier("update.checking")

        case .upToDate:
            EmptyView()

        case .available(let release):
            VStack(alignment: .leading, spacing: DSSpacing.lg) {
                releaseNotes(release)

                Text("Installing quits Mimic and also updates the mimic command-line tool. "
                    + "Your projects are kept.")
                    .font(DSTypography.caption)
                    .foregroundStyle(DSColors.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("update.installNote")
            }

        case .downloading(let release, let fraction):
            VStack(alignment: .leading, spacing: DSSpacing.sm) {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .accessibilityIdentifier("update.progress")
                    .accessibilityLabel("Download progress")
                Text("\(Int(fraction * 100))% of "
                    + "\(release.asset.sizeInBytes.formatted(.byteCount(style: .file)))")
                    .font(DSTypography.Figure.regular)
                    .foregroundStyle(DSColors.labelSecondary)
                    .accessibilityIdentifier("update.progressLabel")
            }

        case .readyToInstall:
            VStack(alignment: .leading, spacing: DSSpacing.sm) {
                // Naming the checks lets the user judge the claim.
                Label("Checksum and developer signature verified",
                      systemImage: "checkmark.seal")
                    .font(DSTypography.body)
                    .foregroundStyle(DSColors.success)
                    .accessibilityIdentifier("update.verified")

                Text("Mimic will save your work, take a copy of your projects, then quit and open "
                    + "the installer. macOS will ask for your password.")
                    .font(DSTypography.body)
                    .foregroundStyle(DSColors.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("update.readyNote")
            }

        case .installing:
            HStack(spacing: DSSpacing.sm) {
                ProgressView().controlSize(.small)
                Text("Saving your work and opening the installer\u{2026}")
                    .font(DSTypography.body)
                    .foregroundStyle(DSColors.labelSecondary)
            }
            .accessibilityIdentifier("update.installing")

        case .failed(let message):
            VStack(alignment: .leading, spacing: DSSpacing.sm) {
                Text(message)
                    .font(DSTypography.body)
                    .foregroundStyle(DSColors.labelPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("update.failure")

                Link("Open the releases page", destination: UpdateFeed.releasesPageURL)
                    .font(DSTypography.callout)
                    .accessibilityIdentifier("update.releasesLink")
                    .accessibilityLabel("Open the releases page")
            }
        }
    }

    /// The notes in a scrollable, selectable well, capped so a long release cannot push the buttons
    /// off screen. Headings and list items are drawn from the Markdown by line; anything else is
    /// shown as written, so a formatting quirk never blanks the panel.
    private func releaseNotes(_ release: UpdateRelease) -> some View {
        let lines = Self.noteLines(release.notes)
        return ScrollView {
            VStack(alignment: .leading, spacing: DSSpacing.xs) {
                if lines.isEmpty {
                    Text("This release has no notes.")
                        .font(DSTypography.callout)
                        .foregroundStyle(DSColors.labelSecondary)
                } else {
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                        noteLine(line, isFirst: index == 0)
                    }
                }
            }
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, DSSpacing.md)
            .padding(.horizontal, DSSpacing.lg)
        }
        .frame(height: 240)
        .background {
            RoundedRectangle(cornerRadius: DSCornerRadius.card)
                .fill(DSColors.code)
        }
        .overlay {
            RoundedRectangle(cornerRadius: DSCornerRadius.card)
                .strokeBorder(DSColors.separator, lineWidth: DSStroke.hairline)
        }
        .clipShape(RoundedRectangle(cornerRadius: DSCornerRadius.card))
        .accessibilityIdentifier("update.notes")
        // `.description`: interpolating an unknown type into a `LocalizedStringKey` falls back to a
        // debug description.
        .accessibilityLabel("Release notes for Mimic \(release.version.description)")
    }

    @ViewBuilder
    private func noteLine(_ line: NoteLine, isFirst: Bool) -> some View {
        switch line {
        case .heading(let text):
            Text(text)
                .font(DSTypography.calloutMedium.weight(.semibold))
                .foregroundStyle(DSColors.labelPrimary)
                .padding(.top, isFirst ? 0 : DSSpacing.sm)
                .padding(.bottom, DSSpacing.xxs)
        case .bullet(let text):
            HStack(alignment: .firstTextBaseline, spacing: DSSpacing.sm) {
                Text("\u{2022}")
                    .foregroundStyle(DSColors.labelSecondary)
                    .accessibilityHidden(true)
                Text(text)
                    .foregroundStyle(DSColors.labelPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(DSTypography.callout)
            .lineSpacing(DSTypography.Leading.callout)
            .padding(.leading, DSSpacing.xs)
        case .text(let text):
            Text(text)
                .font(DSTypography.callout)
                .lineSpacing(DSTypography.Leading.callout)
                .foregroundStyle(DSColors.labelPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    enum NoteLine: Equatable {
        case heading(String)
        case bullet(String)
        case text(String)
    }

    /// Splits release notes into headings, list items and plain lines. Blank lines are dropped.
    static func noteLines(_ notes: String) -> [NoteLine] {
        notes.split(whereSeparator: \.isNewline).compactMap { raw -> NoteLine? in
            let line = raw.trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "**", with: "")
            guard !line.isEmpty else { return nil }
            if line.hasPrefix("#") {
                let text = line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
                return text.isEmpty ? nil : .heading(text)
            }
            for marker in ["- ", "* ", "+ ", "\u{2022} "] where line.hasPrefix(marker) {
                return .bullet(String(line.dropFirst(marker.count)))
            }
            return .text(line)
        }
    }

    // MARK: - Buttons

    @ViewBuilder
    private func buttons(for phase: UpdateService.Phase) -> some View {
        switch phase {
        case .idle, .checking:
            DSButton("Cancel", variant: .secondary, size: .large, identifier: "update.cancelCheckButton") {
                service.dismiss()
            }
            .accessibilityLabel("Cancel")
            .keyboardShortcut(.cancelAction)

        case .upToDate:
            DSButton("Done", variant: .primary, size: .large, identifier: "update.doneButton") {
                service.dismiss()
            }
            .accessibilityLabel("Done")
            .keyboardShortcut(.defaultAction)

        case .available:
            DSButton("Skip this version", variant: .ghost, size: .large, identifier: "update.skipButton") {
                service.skipCurrentVersion()
            }
            .accessibilityLabel("Skip this version")

            DSButton("Later", variant: .secondary, size: .large, identifier: "update.laterButton") {
                service.dismiss()
            }
            .accessibilityLabel("Later")
            .keyboardShortcut(.cancelAction)

            DSButton("Download", variant: .primary, size: .large, identifier: "update.downloadButton") {
                service.downloadAndPrepare()
            }
            .accessibilityLabel("Download the update")
            .keyboardShortcut(.defaultAction)

        case .downloading:
            DSButton("Cancel", variant: .secondary, size: .large, identifier: "update.cancelDownloadButton") {
                service.dismiss()
            }
            .accessibilityLabel("Cancel the download")
            .keyboardShortcut(.cancelAction)

        case .readyToInstall:
            DSButton("Later", variant: .secondary, size: .large, identifier: "update.installLaterButton") {
                service.dismiss()
            }
            .accessibilityLabel("Later")
            .keyboardShortcut(.cancelAction)

            DSButton("Quit and install", variant: .primary, size: .large, identifier: "update.installButton") {
                service.installNow()
            }
            .accessibilityLabel("Quit Mimic and install the update")
            .keyboardShortcut(.defaultAction)

        case .installing:
            Text("Please wait\u{2026}")
                .font(DSTypography.callout)
                .foregroundStyle(DSColors.labelSecondary)
                .accessibilityIdentifier("update.installingStatus")

        case .failed:
            DSButton("Close", variant: .secondary, size: .large, identifier: "update.closeFailureButton") {
                service.dismiss()
            }
            .accessibilityLabel("Close")
            .keyboardShortcut(.cancelAction)

            DSButton("Try again", variant: .primary, size: .large, identifier: "update.retryButton") {
                service.checkForUpdates()
            }
            .accessibilityLabel("Try again")
            .keyboardShortcut(.defaultAction)
        }
    }
}

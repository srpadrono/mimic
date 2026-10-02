import AppKit
import DesignSystem
import Domain
import SwiftUI

/// The window's whole update conversation, in one sheet.
///
/// App icon beside a headline title and summary, the phase body, then a footer with the automatic
/// check toggle and the phase buttons. Every state renders from ``UpdatePhase`` alone.
public struct UpdateSheet: View {

    let service: any UpdateSheetModel

    public init(service: any UpdateSheetModel) {
        self.service = service
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DSSpacing.lg) {
            heading

            body(for: service.phase)

            HStack(spacing: DSSpacing.sm) {
                // The buttons keep one line and take priority, so a narrow row never truncates a
                // control label.
                automaticCheckToggle

                Spacer(minLength: DSSpacing.md)

                buttons(for: service.phase)
                    .lineLimit(1)
                    .layoutPriority(1)
            }
            .frame(minHeight: Self.footerHeight)
        }
        .padding(DSSpacing.xl)
        .frame(width: DSSheetWidth.medium, height: Self.height(for: service.phase))
        .background(DSColors.sheet)
        .dsSheetSurface()
        .interactiveDismissDisabled(service.phase.isBusy)
    }

    /// The design's height while an update is offered: the notes well grows to fill it. Every other
    /// phase hugs its content.
    public static let designHeight: CGFloat = 480

    static func height(for phase: UpdatePhase) -> CGFloat? {
        if case .available = phase { return designHeight }
        return nil
    }

    private var automaticChecks: Binding<Bool> {
        Binding(get: { service.checksAutomatically }, set: { service.checksAutomatically = $0 })
    }

    /// The design-system box with its title beside it. The title toggles too, as a native
    /// checkbox's does; assistive technology reads the box alone, under the full label.
    private var automaticCheckToggle: some View {
        HStack(spacing: Self.checkboxLabelSpacing) {
            Toggle("Check for updates automatically", isOn: automaticChecks)
                .toggleStyle(.dsCheckbox)
                .accessibilityIdentifier("update.automaticToggle")

            Text("Check automatically")
                .font(DSTypography.callout)
                .foregroundStyle(DSColors.labelSecondary)
                .lineLimit(1)
                .onTapGesture { service.checksAutomatically.toggle() }
                .accessibilityHidden(true)
        }
    }

    /// The board's 6 pt between the box and its title.
    private static let checkboxLabelSpacing: CGFloat = DSSpacing.xs + 2

    // MARK: - Heading

    private var heading: some View {
        HStack(alignment: .top, spacing: Self.iconSpacing) {
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
            .padding(.top, Self.titleInset)
        }
    }

    /// The board's 14 pt between the icon and the title.
    private static let iconSpacing: CGFloat = DSSpacing.md + 2
    /// Sets the title's first line where the board's 20 pt line box puts it.
    private static let titleInset: CGFloat = DSSpacing.sm - 1

    /// "1.10" for a release with no patch, as people say it; "1.10.1" and prereleases in full.
    static func displayVersion(_ version: ReleaseVersion) -> String {
        guard version.patch == 0, version.prerelease.isEmpty else { return version.description }
        return "\(version.major).\(version.minor)"
    }

    private func title(for phase: UpdatePhase) -> String {
        switch phase {
        case .idle, .checking:
            "Checking for updates"
        case .upToDate:
            "You're up to date"
        case .available(let release):
            "Mimic \(Self.displayVersion(release.version)) is available"
        case .downloading(let release, _):
            "Downloading Mimic \(Self.displayVersion(release.version))"
        case .readyToInstall(let release, _):
            "Mimic \(Self.displayVersion(release.version)) is ready to install"
        case .installing:
            "Preparing to quit and install"
        case .failed:
            "Couldn't complete the update"
        }
    }

    @ViewBuilder
    private func subtitle(for phase: UpdatePhase) -> some View {
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
    private func body(for phase: UpdatePhase) -> some View {
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
                    .lineSpacing(Self.captionLeading)
                    .padding(.vertical, Self.captionLeading / 2)
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

    /// The notes in a scrollable, selectable well that fills the sheet's design height, so a long
    /// release scrolls rather than pushing the buttons off screen. Headings and list items are drawn
    /// from the Markdown by line; anything else is shown as written, so a formatting quirk never
    /// blanks the panel.
    private func releaseNotes(_ release: UpdateRelease) -> some View {
        let lines = Self.noteLines(release.notes)
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if lines.isEmpty {
                    Text("This release has no notes.")
                        .font(DSTypography.callout)
                        .foregroundStyle(DSColors.labelSecondary)
                } else {
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                        noteLine(line)
                            .padding(.top, Self.spacing(before: line, after: index > 0 ? lines[index - 1] : nil))
                    }
                }
            }
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, Self.notesVerticalInset)
            .padding(.horizontal, DSSpacing.lg)
        }
        .frame(minHeight: Self.notesMinimumHeight, maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: DSCornerRadius.card)
                .fill(DSColors.sheetWell)
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

    // The update board's notes: 12 pt type on 17 pt lines, 3 pt between items, a 16 pt heading line
    // with 6 pt under it, and 12 pt after each list.
    private static let notesVerticalInset: CGFloat = DSSpacing.md + 2
    private static let notesMinimumHeight: CGFloat = 240
    private static let noteLineHeight: CGFloat = 17
    private static let headingLineHeight: CGFloat = 16
    private static let bulletIndent: CGFloat = 18
    private static let bulletDiameter: CGFloat = 4.5
    /// How far the bullet's centre sits above the text baseline: the middle of a lowercase letter.
    private static let bulletRise: CGFloat = 4

    /// The space above `line`, which depends on what came before it.
    static func spacing(before line: NoteLine, after previous: NoteLine?) -> CGFloat {
        guard let previous else { return 0 }
        if case .heading = previous { return 6 }
        if case .heading = line { return DSSpacing.md }
        return 3
    }

    /// The leading that brings a single line of `size`-point system type up to `lineHeight`.
    private static func extraLeading(lineHeight: CGFloat, size: CGFloat, weight: NSFont.Weight) -> CGFloat {
        let natural = NSLayoutManager().defaultLineHeight(for: .systemFont(ofSize: size, weight: weight))
        return max(0, lineHeight - natural)
    }

    /// The install note's 15 pt lines.
    private static let captionLeading = extraLeading(lineHeight: 15, size: 11, weight: .regular)
    /// The board's footer row: its buttons with a point of air above and below.
    private static let footerHeight: CGFloat = DSControlHeight.large + 2
    private static let bodyLeading = extraLeading(lineHeight: noteLineHeight, size: 12, weight: .regular)
    private static let headingLeading = extraLeading(lineHeight: headingLineHeight, size: 12, weight: .semibold)

    @ViewBuilder
    private func noteLine(_ line: NoteLine) -> some View {
        switch line {
        case .heading(let text):
            Text(text)
                .font(DSTypography.calloutMedium.weight(.semibold))
                .foregroundStyle(DSColors.labelPrimary)
                .padding(.vertical, Self.headingLeading / 2)
        case .bullet(let text):
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Circle()
                    .fill(DSColors.labelPrimary)
                    .frame(width: Self.bulletDiameter, height: Self.bulletDiameter)
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + Self.bulletRise }
                    .padding(.leading, DSSpacing.xs)
                    .frame(width: Self.bulletIndent, alignment: .leading)
                    .accessibilityHidden(true)
                noteText(text)
            }
        case .text(let text):
            noteText(text)
        }
    }

    private func noteText(_ text: String) -> some View {
        Text(text)
            .font(DSTypography.callout)
            .lineSpacing(Self.bodyLeading)
            .padding(.vertical, Self.bodyLeading / 2)
            .foregroundStyle(DSColors.labelPrimary)
            .fixedSize(horizontal: false, vertical: true)
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
    private func buttons(for phase: UpdatePhase) -> some View {
        switch phase {
        case .idle, .checking:
            DSButton("Cancel", variant: .secondary, size: .large, identifier: "update.cancelCheck") {
                service.dismiss()
            }
            .accessibilityIdentifier("update.cancelCheckButton")
            .accessibilityLabel("Cancel")
            .keyboardShortcut(.cancelAction)

        case .upToDate:
            DSButton("Done", variant: .primary, size: .large, identifier: "update.done") {
                service.dismiss()
            }
            .accessibilityIdentifier("update.doneButton")
            .accessibilityLabel("Done")
            .keyboardShortcut(.defaultAction)

        case .available:
            DSButton("Skip this version", variant: .ghost, size: .large, identifier: "update.skip") {
                service.skipCurrentVersion()
            }
            // A ghost button pads for a tool beside content; here it sits in a row of sheet buttons
            // and keeps their 16 pt sides, as the board draws it.
            .padding(.horizontal, DSSpacing.sm)
            .accessibilityIdentifier("update.skipButton")
            .accessibilityLabel("Skip this version")

            DSButton("Later", variant: .secondary, size: .large, identifier: "update.later") {
                service.dismiss()
            }
            .accessibilityIdentifier("update.laterButton")
            .accessibilityLabel("Later")
            .keyboardShortcut(.cancelAction)

            DSButton("Download", variant: .primary, size: .large, identifier: "update.download") {
                service.downloadAndPrepare()
            }
            .accessibilityIdentifier("update.downloadButton")
            .accessibilityLabel("Download the update")
            .keyboardShortcut(.defaultAction)

        case .downloading:
            DSButton("Cancel", variant: .secondary, size: .large, identifier: "update.cancelDownload") {
                service.dismiss()
            }
            .accessibilityIdentifier("update.cancelDownloadButton")
            .accessibilityLabel("Cancel the download")
            .keyboardShortcut(.cancelAction)

        case .readyToInstall:
            DSButton("Later", variant: .secondary, size: .large, identifier: "update.installLater") {
                service.dismiss()
            }
            .accessibilityIdentifier("update.installLaterButton")
            .accessibilityLabel("Later")
            .keyboardShortcut(.cancelAction)

            DSButton("Quit and install", variant: .primary, size: .large, identifier: "update.install") {
                service.installNow()
            }
            .accessibilityIdentifier("update.installButton")
            .accessibilityLabel("Quit Mimic and install the update")
            .keyboardShortcut(.defaultAction)

        case .installing:
            Text("Please wait\u{2026}")
                .font(DSTypography.callout)
                .foregroundStyle(DSColors.labelSecondary)
                .accessibilityIdentifier("update.installingStatus")

        case .failed:
            DSButton("Close", variant: .secondary, size: .large, identifier: "update.closeFailure") {
                service.dismiss()
            }
            .accessibilityIdentifier("update.closeFailureButton")
            .accessibilityLabel("Close")
            .keyboardShortcut(.cancelAction)

            DSButton("Try again", variant: .primary, size: .large, identifier: "update.retry") {
                service.checkForUpdates()
            }
            .accessibilityIdentifier("update.retryButton")
            .accessibilityLabel("Try again")
            .keyboardShortcut(.defaultAction)
        }
    }
}

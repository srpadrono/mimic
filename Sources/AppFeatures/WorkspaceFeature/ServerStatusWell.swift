import AppKit
import SwiftUI
import Domain
import DesignSystem

/// The toolbar's centre well: what is running, where to reach it, and what is arriving.
///
/// Xcode puts the state you check constantly — the active scheme, the error and warning counts — in a
/// recessed well in the middle of its toolbar, and puts the warning badge one click away from the
/// issues themselves. Mimic's equivalents were scattered: the power button sat top-left, and the base
/// URL — the most-copied string in the app — lived in a 28pt strip along the bottom edge, which is the
/// part of a window nobody looks at. This puts both where the eye returns.
///
/// The state and backend summaries are built by `nonisolated static` functions below. That keeps the wording testable without
/// standing up a window, which is how the rest of this module tests view logic.
struct ServerStatusWell: View {
    let serverState: ServerState
    let projectName: String?
    let requestCount: Int
    let unmatchedCount: Int
    let compact: Bool
    let configuration: ServerConfiguration?
    let boundConfiguration: ServerConfiguration?
    /// Filters the request log to unmatched requests. Nil disables the affordance.
    var onShowUnmatched: (() -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showingCopied = false
    @State private var copyResetTask: Task<Void, Never>?
    @State private var isPulsing = false
    /// Which of the well's two buttons the pointer is on.
    ///
    /// Neither had an answer: this file contained no hover handling at all, so the address — which
    /// the type's own note calls the most-copied string in the app — and the badge that jumps you to
    /// the traffic nothing answered both looked exactly the same whether or not you were about to
    /// click them. That is the class of defect the house rules say recurs most, and a copy button is
    /// the case they name.
    @State private var isURLHovered = false
    @State private var isUnmatchedHovered = false
    @State private var showingBackends = false
    @State private var isPortsHovered = false

    init(
        serverState: ServerState,
        projectName: String?,
        requestCount: Int,
        unmatchedCount: Int,
        compact: Bool = false,
        configuration: ServerConfiguration? = nil,
        boundConfiguration: ServerConfiguration? = nil,
        onShowUnmatched: (() -> Void)? = nil
    ) {
        self.serverState = serverState
        self.projectName = projectName
        self.requestCount = requestCount
        self.unmatchedCount = unmatchedCount
        self.compact = compact
        self.configuration = configuration
        self.boundConfiguration = boundConfiguration
        self.onShowUnmatched = onShowUnmatched
    }

    var body: some View {
        HStack(spacing: DSSpacing.sm) {
            stateChip
            primaryElement
            if let configuration, configuration.listeners.count > 1 || restartRequired {
                backendPopoverButton(configuration)
            }

            // Xcode's arrangement, and the reason the well can afford to be this wide: the activity
            // text sits at the leading edge and the issue counts are pinned to the trailing one, so
            // the space between them is structure rather than slack. Packed left in a 460pt well the
            // same content would leave two hundred points of empty green, which reads as a layout
            // fault rather than as a status bar.
            //
            // The state mark stays leading in every state. A group centred as a whole would slide it
            // sideways with the length of the address, and a status light you have to look for is
            // the one thing this well cannot afford.
            // A spacer with no trailing counters still claims twelve points. At the toolbar's
            // narrowest width that was enough to turn "Stopped" into "S…ed" for no reason.
            if !compact && hasTraffic {
                Spacer(minLength: DSSpacing.md)
            }

            if !compact && hasTraffic {
                trafficDivider
                requestCountElement
            }

            if !compact && unmatchedCount > 0 {
                unmatchedElement
            }
        }
        // Share the exact outer geometry of the neighboring action pills.
        .padding(.horizontal, DSToolbarGeometry.horizontalInset)
        .frame(height: DSToolbarGeometry.height)
        // WorkspaceView proposes a width for the wide or compact window layout. With traffic,
        // the spacer anchors status and counters to opposite edges; without it the capsule hugs
        // its contents. The toolbar's shared background is hidden to avoid nested capsules.
        .background {
            // The status capsule echoes native toolbar controls without a second glass layer.
            Capsule()
                .fill(wellFill)
                .strokeBorder(wellBorder, lineWidth: DSStroke.hairline)
        }
        .fixedSize(horizontal: false, vertical: true)
        .help(wellHelpText)
        // The identifier alone would rename every descendant; `.contain` keeps the well addressable
        // while its URL and counts keep their own names.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("serverStatusWell")
        .onChange(of: isTransitioning, initial: true) { syncPulse() }
        .onChange(of: reduceMotion) { syncPulse() }
        .onDisappear { copyResetTask?.cancel() }
    }

    // MARK: - Pieces

    private var restartRequired: Bool {
        isRunning && configuration.map { configured in
            boundConfiguration.map { !$0.hasSameListeners(as: configured) } ?? false
        } == true
    }

    private func backendPopoverButton(_ configuration: ServerConfiguration) -> some View {
        Button { showingBackends.toggle() } label: {
            Text("\(configuration.listeners.count) \(configuration.listeners.count == 1 ? "port" : "ports")\(restartRequired ? " !" : "")")
                .font(DSTypography.caption)
                .foregroundStyle(isPortsHovered ? DSColors.accent : DSColors.labelSecondary)
                .fixedSize()
                .frame(height: DSToolbarGeometry.height)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isPortsHovered = $0 }
        .help(Self.backendSummary(configuration: configuration, boundConfiguration: boundConfiguration, isRunning: isRunning))
        .accessibilityIdentifier("serverStatusWell.backends")
        .accessibilityLabel("Backend ports")
        .accessibilityValue(Self.backendSummary(configuration: configuration, boundConfiguration: boundConfiguration, isRunning: isRunning))
        .popover(isPresented: $showingBackends) {
            VStack(alignment: .leading, spacing: DSSpacing.md) {
                if isRunning, let boundConfiguration {
                    Text("Listening — click to copy URL").font(DSTypography.bodyMedium)
                    ForEach(Self.listeningBackends(configuration: configuration, boundConfiguration: boundConfiguration)) { backend in
                        DSButton("\(backend.name): \(backend.port)", variant: .ghost, size: .small,
                                 identifier: "serverStatusWell.copyPort.\(backend.port)") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(backend.localURL, forType: .string)
                            showingBackends = false
                        }
                        .accessibilityIdentifier("serverStatusWell.copyPort.\(backend.port)")
                        .accessibilityLabel("Copy \(backend.name) URL, port \(backend.port)")
                    }
                    Divider()
                }
                Text(restartRequired ? "Configured — restart required" : "Configured ports")
                    .font(DSTypography.bodyMedium)
                ForEach(configuration.listeners) { backend in
                    Text(verbatim: "\(backend.name): \(backend.port)")
                        .font(DSTypography.code)
                        .accessibilityIdentifier("serverStatusWell.configuredPort.\(backend.port)")
                }
            }
            .padding(DSSpacing.lg)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("serverStatusWell.portList")
        }
    }

    // Names can change live; ports describe the configuration that actually bound.
    nonisolated private static func listeningBackends(
        configuration: ServerConfiguration, boundConfiguration: ServerConfiguration
    ) -> [BackendConfiguration] {
        boundConfiguration.listeners.map { backend in
            var displayed = backend
            displayed.name = configuration.backend(id: backend.id)?.name ?? backend.name
            return displayed
        }
    }

    nonisolated static func backendSummary(
        configuration: ServerConfiguration, boundConfiguration: ServerConfiguration?, isRunning: Bool
    ) -> String {
        let configured = configuration.listeners.map { "\($0.name): \($0.port)" }.joined(separator: ", ")
        if isRunning, let boundConfiguration {
            let listening = listeningBackends(configuration: configuration, boundConfiguration: boundConfiguration).map { "\($0.name): \($0.port)" }.joined(separator: ", ")
            if !boundConfiguration.hasSameListeners(as: configuration) {
                return "Listening on \(listening). Configured ports: \(configured). Restart required."
            }
            return "\(configuration.listeners.count) ports listening: \(listening)."
        }
        return "\(configuration.listeners.count) ports configured: \(configured). Server is not running."
    }

    /// What the server is doing, as a mark on a surface of its own colour.
    ///
    /// A rounded square rather than a circle, and on a chip rather than floating: a 7pt dot at the
    /// left edge of a 220pt well is the smallest thing in the toolbar, and it is carrying the one
    /// state a mock server has. `DSCornerRadius.xs` is the tier its own note names for exactly this
    /// — "a status dot, a copy chip" — and at 8pt a 3pt radius reads as a rounded square, which is a
    /// shape you can find, where a dot of the same area is a speck.
    ///
    /// The chip is `dotColor` at ``DSColors/successMuted``'s depth rather than the token itself,
    /// because it has to follow the mark through all five states and only one of them is green.
    private var stateChip: some View {
        RoundedRectangle(cornerRadius: DSCornerRadius.xs, style: .continuous)
            .fill(dotColor)
            // `indicator` and not `minimum`, which is the same number answering a different
            // question — that one is a floor to check against, and its own note says not to draw at
            // it. This rung's list names a state dot by name.
            .frame(width: DSGlyph.indicator, height: DSGlyph.indicator)
            .scaleEffect(isPulsing ? 1.25 : 1.0)
            .opacity(isPulsing ? 0.45 : 1.0)
            .animation(pulseAnimation, value: isPulsing)
            .frame(width: DSToolbarGeometry.contentHeight, height: DSToolbarGeometry.contentHeight)
            .background {
                RoundedRectangle(cornerRadius: DSCornerRadius.sm, style: .continuous)
                    .fill(dotColor.opacity(0.25))
            }
            // The state it encodes is spoken by the element beside it; on its own it would be an
            // unlabelled stop in the VoiceOver rotor.
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var primaryElement: some View {
        if isRunning {
            Button(action: copyURL) {
                primaryLabel
                    .frame(height: DSToolbarGeometry.height)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .onHover { isURLHovered = $0 }
            .animation(.easeOut(duration: DSAnimation.micro), value: isURLHovered)
            .help("Copy the base URL")
            .accessibilityIdentifier("serverStatusWell.url")
            .accessibilityLabel(spokenPrimaryLabel)
        } else {
            primaryLabel
                .accessibilityIdentifier("serverStatusWell.url")
                .accessibilityLabel(spokenPrimaryLabel)
        }
    }

    /// The address and copy affordance form one control, with a stable confirmation footprint.
    private var primaryLabel: some View {
        HStack(spacing: DSSpacing.sm) {
            primaryTextView
                // Only the address is monospaced; state descriptions use the toolbar's body face.
                .font(isRunning ? DSTypography.codeBold.monospacedDigit() : DSTypography.bodyMedium)
                .foregroundStyle(primaryColor)
                .lineLimit(1)
                .truncationMode(.middle)
                .contentTransition(.opacity)

            if showsCopyAffordance {
                copyAffordance
            }
        }
        .contentShape(.rect)
    }

    /// A fixed-width copy/checkmark affordance, without a second, undersized pill inside the well.
    private var copyAffordance: some View {
        Image(systemName: showsCopyConfirmation ? "checkmark" : "doc.on.doc")
            .font(.system(size: DSGlyph.control, weight: .medium))
            .foregroundStyle(showsCopyConfirmation ? DSColors.successText : primaryColor)
            .frame(width: DSToolbarGeometry.contentHeight, height: DSToolbarGeometry.contentHeight)
            .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
            // Not `.fixedSize()`, which the house rules name as a latent clipping bug in a row: it
            // makes the row demand more width than it has and an `HStack` pays for that out of its
            // *leading* edge. Priority says the same thing without the trap — the chip keeps its
            // intrinsic width and the address, which already truncates in the middle, is what gives.
            .layoutPriority(1)
            // The whole run is one button and one accessibility element; the chip is the picture of
            // what that button does, spoken already by `spokenPrimaryLabel`.
            .accessibilityHidden(true)
    }

    /// Always the address, never the confirmation.
    ///
    /// It used to swap to "Copied" for a second and a half, which took the port off the screen at
    /// the one moment a user is demonstrably looking at it — you copy an address to paste it beside
    /// the window it came from, and half the time you then want to read it back. The chip carries
    /// the confirmation now, which is where the state belongs: it is the button's, not the string's.
    private var primaryTextView: Text {
        Text(verbatim: compact
             ? Self.compactPrimaryText(serverState: serverState, projectName: projectName)
             : Self.primaryText(serverState: serverState, projectName: projectName))
    }

    private var trafficDivider: some View {
        Rectangle()
            .fill(DSColors.separator)
            .frame(width: 1, height: 12)
            .accessibilityHidden(true)
    }

    /// How much has arrived, as a glyph and a figure.
    ///
    /// The bare number had no subject. Beside a warning triangle and a count it read as the first
    /// half of a pair — two numbers, one of them explained — and the question it answers, "how many
    /// requests", was carried entirely by a tooltip. The glyph is the subject, so it takes
    /// `DSGlyph.inlineSmall` and `labelSecondary`, the tier the ladder reserves for "a mark that
    /// qualifies the count beside it": the same rung and the same reasoning as the unmatched
    /// triangle below.
    ///
    /// The figure itself moves up to `labelPrimary`. It was the one number in the well nobody could
    /// read at a glance, at 55% alpha next to an amber badge at full strength — and the house rule
    /// that nothing a user must read sits at `labelTertiary` is really a rule about which of two
    /// things in a pair is the content.
    private var requestCountElement: some View {
        HStack(spacing: DSSpacing.xs) {
            Image(systemName: "chart.bar.fill")
                .font(.system(size: DSGlyph.inlineSmall, weight: .semibold))
                .foregroundStyle(DSColors.labelSecondary)
            Text(verbatim: "\(requestCount)")
                .font(DSTypography.Figure.small)
                .foregroundStyle(DSColors.labelPrimary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("serverStatusWell.requestCount")
        .accessibilityLabel(Self.requestCountLabel(requestCount))
    }

    @ViewBuilder
    private var unmatchedElement: some View {
        if let onShowUnmatched {
            Button(action: onShowUnmatched) {
                unmatchedBadge
                    .frame(height: DSToolbarGeometry.height)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .onHover { isUnmatchedHovered = $0 }
            .animation(.easeOut(duration: DSAnimation.micro), value: isUnmatchedHovered)
            .help("Show the requests no endpoint or journey answered")
            .accessibilityIdentifier("serverStatusWell.unmatched")
            .accessibilityLabel(Self.unmatchedLabel(unmatchedCount, actionable: true))
        } else {
            unmatchedBadge
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("serverStatusWell.unmatched")
                .accessibilityLabel(Self.unmatchedLabel(unmatchedCount, actionable: false))
        }
    }

    private var unmatchedBadge: some View {
        HStack(spacing: DSSpacing.xxs) {
            // The icon carries the warning as shape as well as colour, so the badge survives
            // Differentiate Without Color — and it is what lets the colour move on hover below
            // without the badge stopping saying "warning".
            //
            // `inlineSmall`, which `DSGlyph` names this glyph for by hand: a mark that qualifies the
            // count beside it rather than being the control itself.
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: DSGlyph.inlineSmall, weight: .semibold))
            // `Figure.small` rather than `codeSmall`, which is the same face without
            // `.monospacedDigit()`. The two counts in this well sit a few points apart and both tick
            // while a run is in flight; one of them shuffling as it crosses 9 and the other not is a
            // difference you see without being able to name.
            Text(verbatim: "\(unmatchedCount)")
                .font(DSTypography.Figure.small)
        }
        .foregroundStyle(unmatchedColor)
        .contentShape(.rect)
    }

    /// The address, and whether the pointer is on it.
    ///
    /// A colour change rather than the `accentSubtle` well every icon button in the window lights up
    /// with, for the reason `DSClearButton` states for its own hover: both of these controls sit
    /// inside a capsule that already has a fill and a hairline, with `DSControlHeight.verticalPadding`
    /// between them and its edge, so a second well would read as a control that had come loose from
    /// the well it lives in. `accentText` and not a lift toward `labelPrimary`, because at rest this
    /// is already `labelPrimary` — there is nowhere brighter to go, and blue is what the rest of the
    /// window uses to say "this word is a control" (`DSButton`'s ghost variant, the editor's "Add"
    /// and "Format").
    private var primaryColor: Color {
        guard isRunning else { return DSColors.labelSecondary }
        return isURLHovered ? DSColors.accentText : DSColors.labelPrimary
    }

    /// The well's own surface: green while something is listening, the neutral recess otherwise.
    ///
    /// The well was `tertiary` in every state, which meant the toolbar looked identical whether or
    /// not the app was doing the one thing it exists to do. The dot said so, at 7pt. Tinting the
    /// surface says it at the size of the well, and it costs nothing to read — see
    /// ``DSColors/successSubtle`` for the measurement.
    ///
    /// **Running only, deliberately.** An error tint was the obvious next step and is not taken: the
    /// window already puts errors in an alert, and a red toolbar segment that persists after the
    /// alert is dismissed is a wall of colour saying something already said. The quiet states —
    /// stopped, starting, stopping — keep the recess, which is the same call `DSColors` records for
    /// server state generally: "a state nobody has to act on is a label rather than a signal".
    private var wellFill: Color {
        isRunning ? DSColors.successSubtle : DSColors.tertiary
    }

    private var wellBorder: Color {
        isRunning ? DSColors.successMuted : DSColors.border
    }

    /// Only offer copying when an address exists; compact mode keeps the whole address clickable.
    private var showsCopyAffordance: Bool { isRunning && !compact }

    /// The unmatched badge, and whether the pointer is on it. Same answer as the address above, so
    /// the well's two buttons respond to the pointer the same way rather than inventing one idiom
    /// each. The warning is not lost while the colour is borrowed: the filled triangle is the half of
    /// this badge that survives Differentiate Without Color, and it is unchanged.
    private var unmatchedColor: Color {
        isUnmatchedHovered ? DSColors.accentText : DSColors.httpStatusColor(for: 404)
    }

    // MARK: - State-derived properties

    private var isRunning: Bool { serverState.runningPort != nil }

    private var isTransitioning: Bool {
        switch serverState {
        case .starting, .stopping: true
        default:                   false
        }
    }

    /// A confirmation left over from a server that has since stopped would point at a URL that no
    /// longer answers, so it dies with the run.
    private var showsCopyConfirmation: Bool { showingCopied && isRunning }

    private var hasTraffic: Bool { requestCount > 0 || unmatchedCount > 0 }

    private var dotColor: Color {
        switch serverState {
        case .running:              DSColors.success
        case .error:                DSColors.destructive
        case .stopped:              DSColors.labelTertiary
        // A shade brighter than stopped: at 36% opacity the pulse is invisible, and "in flight" is
        // exactly the moment the dot is worth looking at.
        case .starting, .stopping:  DSColors.labelSecondary
        }
    }

    /// Repeats only while a transition is in flight; `isPulsing` is never set under Reduce Motion, so
    /// this collapses to a one-shot ease and the dot holds still.
    private var pulseAnimation: Animation {
        guard isPulsing, !reduceMotion else { return .easeOut(duration: DSAnimation.normal) }
        return .easeInOut(duration: 0.8).repeatForever(autoreverses: true)
    }

    private var spokenPrimaryLabel: String {
        Self.primaryAccessibilityLabel(serverState: serverState, projectName: projectName)
    }

    private var wellHelpText: String {
        Self.helpText(
            serverState: serverState,
            projectName: projectName,
            requestCount: requestCount,
            unmatchedCount: unmatchedCount
        )
    }

    // MARK: - Actions

    private func syncPulse() {
        isPulsing = isTransitioning && !reduceMotion
    }

    func copyURL() {
        guard let url = Self.copyableURL(serverState: serverState) else { return }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
        withAnimation(.easeOut(duration: DSAnimation.fast)) { showingCopied = true }

        // Copying twice in quick succession would otherwise leave two timers racing, and the first to
        // land would clear the confirmation the second had only just put up.
        copyResetTask?.cancel()
        copyResetTask = Task {
            try? await Task.sleep(for: .milliseconds(1500))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: DSAnimation.fast)) { showingCopied = false }
        }
    }

    // MARK: - Pure text rules

    /// What a click copies, or nil when nothing is listening.
    ///
    /// The scheme survives here even though the well drops it: a URL without one is not pasteable
    /// into a browser, a `curl`, or a client's base-URL field.
    nonisolated static func copyableURL(serverState: ServerState) -> String? {
        guard let port = serverState.runningPort else { return nil }
        return "http://localhost:\(port)"
    }

    /// The middle of the well: where to reach the server, or which project is loaded when it is down.
    ///
    /// `http://` is seven characters that never change, and the well is the width of a toolbar — so
    /// the displayed form drops it and the copied form keeps it.
    /// Says what the *server* is doing, never what the project is called.
    ///
    /// It used to fall back to the project name, which put the same string in two places a centimetre
    /// apart: the window title already carries it. Two identical words side by side read as a
    /// rendering fault, and neither of them answered the question the well exists to answer.
    nonisolated static func primaryText(serverState: ServerState, projectName: String?) -> String {
        if let port = serverState.runningPort {
            return "localhost:\(port)"
        }
        let hasProject = projectName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        guard hasProject else { return "No project" }

        switch serverState {
        case .starting: return "Starting\u{2026}"
        case .stopping: return "Stopping\u{2026}"
        case .error:    return "Server error"
        default:        return "Server stopped"
        }
    }

    /// A 96pt toolbar well cannot hold the state mark and a full address or sentence. Keep the
    /// distinguishing word (or listening port) visible instead of clipping both ends of it.
    nonisolated static func compactPrimaryText(serverState: ServerState, projectName: String?) -> String {
        if let port = serverState.runningPort { return String(port) }
        let hasProject = projectName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        guard hasProject else { return "No project" }
        switch serverState {
        case .starting: return "Starting"
        case .stopping: return "Stopping"
        case .error: return "Error"
        default: return "Stopped"
        }
    }

    /// Spoken form of the server state, phrased to sit at the end of a sentence.
    nonisolated static func stateDescription(_ serverState: ServerState) -> String {
        switch serverState {
        case .stopped:              "server stopped"
        case .starting:             "server starting"
        case .running:              "server running"
        case .stopping:             "server stopping"
        case .error(let message):   "server error: \(message)"
        }
    }

    nonisolated static func primaryAccessibilityLabel(
        serverState: ServerState,
        projectName: String?
    ) -> String {
        if let url = copyableURL(serverState: serverState) {
            return "Server base URL \(url), click to copy"
        }
        // The project name, not `primaryText`. What is shown and what is spoken diverge here on
        // purpose: the display drops the name because the window title is a centimetre away, but a
        // VoiceOver user moving through the toolbar has no such neighbour to lean on. Composing the
        // spoken form from `primaryText` produced "Server stopped, server stopped".
        return "\(spokenSubject(projectName)), \(stateDescription(serverState))"
    }

    /// What to call the thing the well is describing, when speaking rather than showing.
    nonisolated static func spokenSubject(_ projectName: String?) -> String {
        let trimmed = projectName?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else { return "No project" }
        return trimmed
    }

    nonisolated static func requestCountLabel(_ count: Int) -> String {
        switch count {
        case 0:  "No requests logged"
        case 1:  "1 request logged"
        default: "\(count) requests logged"
        }
    }

    /// - Parameter actionable: Whether a click filters the log. Promising "show them" when
    ///   `onShowUnmatched` is nil would be a lie VoiceOver has no way to walk back.
    nonisolated static func unmatchedLabel(_ count: Int, actionable: Bool) -> String {
        let subject = count == 1 ? "1 unmatched request" : "\(count) unmatched requests"
        guard actionable else { return subject }
        return count == 1 ? "\(subject), show it" : "\(subject), show them"
    }

    nonisolated static func helpText(
        serverState: ServerState,
        projectName: String?,
        requestCount: Int,
        unmatchedCount: Int
    ) -> String {
        var sentences: [String] = []
        if let url = copyableURL(serverState: serverState) {
            sentences.append("Server running at \(url). Click the address to copy it.")
        } else {
            sentences.append("\(spokenSubject(projectName)) — \(stateDescription(serverState)).")
        }
        sentences.append("\(requestCountLabel(requestCount)).")
        if unmatchedCount > 0 {
            sentences.append("\(unmatchedCount) matched no endpoint or journey.")
        }
        return sentences.joined(separator: " ")
    }
}

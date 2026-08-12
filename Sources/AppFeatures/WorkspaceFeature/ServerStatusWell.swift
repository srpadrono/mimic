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
/// Everything rendered here is a function of ``ServerState`` and two counts, so every string it can
/// show is built by a `nonisolated static` function below. That keeps the wording testable without
/// standing up a window, which is how the rest of this module tests view logic.
struct ServerStatusWell: View {
    let serverState: ServerState
    let projectName: String?
    let requestCount: Int
    let unmatchedCount: Int
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

    init(
        serverState: ServerState,
        projectName: String?,
        requestCount: Int,
        unmatchedCount: Int,
        onShowUnmatched: (() -> Void)? = nil
    ) {
        self.serverState = serverState
        self.projectName = projectName
        self.requestCount = requestCount
        self.unmatchedCount = unmatchedCount
        self.onShowUnmatched = onShowUnmatched
    }

    var body: some View {
        HStack(spacing: DSSpacing.sm) {
            stateDot
            primaryElement

            if hasTraffic {
                trafficDivider
                requestCountElement
            }

            if unmatchedCount > 0 {
                unmatchedElement
            }
        }
        .padding(.horizontal, DSSpacing.md)
        // `DSControlHeight.verticalPadding`, which is what this 3 always was: the inset above and
        // below a control's own content, half of `DSSpacing.sm` and deliberately off the spacing
        // scale because it is internal geometry rather than a gap between two things. The request
        // log's header wells and the endpoint editor's fields take the same rung.
        .padding(.vertical, DSControlHeight.verticalPadding)
        .background {
            Capsule()
                .fill(DSColors.tertiary)
                .strokeBorder(DSColors.border, lineWidth: DSStroke.hairline)
        }
        // A floor as well as a ceiling. Xcode's activity view keeps its width whether it is reporting
        // a build or sitting idle, so the toolbar does not re-flow every time the text changes
        // length. Sized to content alone this read as a small chip rather than the window's status.
        // Bounded, because a `.principal` toolbar item sizes to its content regardless — `maxWidth:
        // .infinity` was tried here and changed nothing, so claiming it fills the bar would be a lie
        // in a comment. What actually closed the toolbar's void was moving the content actions into
        // the centre column beside the server control; this well just has to stay legible between
        // them.
        .frame(minWidth: 220, maxWidth: 420)
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

    private var stateDot: some View {
        Circle()
            .fill(dotColor)
            .frame(width: 7, height: 7)
            .scaleEffect(isPulsing ? 1.25 : 1.0)
            .opacity(isPulsing ? 0.45 : 1.0)
            .animation(pulseAnimation, value: isPulsing)
            // The state it encodes is spoken by the element beside it; on its own it would be an
            // unlabelled stop in the VoiceOver rotor.
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var primaryElement: some View {
        if isRunning {
            Button(action: copyURL) {
                primaryLabel
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

    private var primaryLabel: some View {
        primaryTextView
            // Monospaced only for the address: digits that change as the port changes should not
            // reflow the row, and a project name in SF Mono reads as a filename.
            .font(isRunning ? DSTypography.codeSmall : DSTypography.label)
            .foregroundStyle(primaryColor)
            .lineLimit(1)
            .truncationMode(.middle)
            .contentTransition(.opacity)
            .contentShape(.rect)
    }

    private var primaryTextView: Text {
        showsCopyConfirmation
            ? Text("Copied")
            : Text(verbatim: Self.primaryText(serverState: serverState, projectName: projectName))
    }

    private var trafficDivider: some View {
        Rectangle()
            .fill(DSColors.separator)
            .frame(width: 1, height: 12)
            .accessibilityHidden(true)
    }

    private var requestCountElement: some View {
        Text(verbatim: "\(requestCount)")
            .font(DSTypography.codeSmall)
            .foregroundStyle(DSColors.labelSecondary)
            .accessibilityIdentifier("serverStatusWell.requestCount")
            .accessibilityLabel(Self.requestCountLabel(requestCount))
    }

    @ViewBuilder
    private var unmatchedElement: some View {
        if let onShowUnmatched {
            Button(action: onShowUnmatched) {
                unmatchedBadge
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
            Text(verbatim: "\(unmatchedCount)")
                .font(DSTypography.codeSmall)
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

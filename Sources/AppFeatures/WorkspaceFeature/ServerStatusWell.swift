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
            stateChip
            primaryElement

            // Xcode's arrangement, and the reason the well can afford to be this wide: the activity
            // text sits at the leading edge and the issue counts are pinned to the trailing one, so
            // the space between them is structure rather than slack. Packed left in a 460pt well the
            // same content would leave two hundred points of empty green, which reads as a layout
            // fault rather than as a status bar.
            //
            // The state mark stays leading in every state. A group centred as a whole would slide it
            // sideways with the length of the address, and a status light you have to look for is
            // the one thing this well cannot afford.
            Spacer(minLength: DSSpacing.md)

            if hasTraffic {
                trafficDivider
                requestCountElement
            }

            if unmatchedCount > 0 {
                unmatchedElement
            }
        }
        // 12 and not the 8 a chip's own inset would suggest, because the well is a capsule: the first
        // 11pt of it is curve, and a 16pt state chip set 8pt in has its top and bottom corners inside
        // that curve.
        .padding(.horizontal, DSSpacing.md)
        // `DSControlHeight.verticalPadding`, which is what this 3 always was: the inset above and
        // below a control's own content, half of `DSSpacing.sm` and deliberately off the spacing
        // scale because it is internal geometry rather than a gap between two things. The request
        // log's header wells and the endpoint editor's fields take the same rung.
        .padding(.vertical, DSControlHeight.verticalPadding)
        // The well carries no width of its own. It used to — a fixed `minWidth`/`maxWidth` pair —
        // and that is the frame that could not follow the panels: a `.principal` item sizes to its
        // content's ideal width, so the well held one number while the window, the navigator and
        // the inspector all moved around it. The width now arrives from outside:
        // `WorkspaceView.wellWidth` measures the centre column and hands this view a `.frame(width:)`,
        // which is how the well stretches and gives way the way Xcode's activity view does. The
        // `Spacer` in the row above is what makes any given width look intentional — content
        // anchored to both edges, slack in the middle.
        //
        // The `Spacer` is also what keeps the fill honest against the item's glass. macOS 26 draws
        // a glass capsule behind every toolbar item, sized to the item's frame; the first cut of
        // this well painted its fill at content width inside a wider frame and shipped two nested
        // pills — a 220pt system capsule with a 120pt badge floating in it. Here the fill wraps the
        // row, the row's `Spacer` accepts whatever width the external frame proposes, and so fill,
        // frame and glass are always the same box.
        .background {
            // A `Capsule`, matching the shape macOS draws behind a toolbar item, for the reason
            // directly above: this fill is standing *on* that glass, and a rounded rect at any radius
            // leaves four crescents of it showing at the corners. The radius ladder would put a 22pt
            // control at `smPlus`; the platform overrules it here, and this is the one place in the
            // window where that is true.
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
            .frame(width: Self.stateChipSide, height: Self.stateChipSide)
            .background {
                RoundedRectangle(cornerRadius: DSCornerRadius.sm, style: .continuous)
                    .fill(dotColor.opacity(0.25))
            }
            // The state it encodes is spoken by the element beside it; on its own it would be an
            // unlabelled stop in the VoiceOver rotor.
            .accessibilityHidden(true)
    }

    /// 16 — the state chip's side, and what sets the well's own height at `DSControlHeight.field`
    /// once `DSControlHeight.verticalPadding` is paid above and below it. Off the spacing scale for
    /// the reason that padding is: it is a control's internal geometry rather than a gap between two
    /// things.
    private static let stateChipSide: CGFloat = 16

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

    /// The address and the word that says what clicking it does, as one control.
    ///
    /// One `Button`, not two. The chip is an affordance on the address rather than a second target
    /// beside it: splitting them would put a 26pt hit area next to a 90pt one that does the same
    /// thing, and the suite clicks the address itself (`WorkspaceShellUITests`, SRVWELL). So the
    /// whole run reads as one control, lights as one control, and answers as one control.
    private var primaryLabel: some View {
        HStack(spacing: DSSpacing.sm) {
            primaryTextView
                // Monospaced only for the address: digits that change as the port changes should not
                // reflow the row, and a project name in SF Mono reads as a filename. Semibold and
                // `.monospacedDigit()` come with `Figure.status` — see that token for why a port is
                // a figure rather than a word.
                .font(isRunning ? DSTypography.Figure.status : DSTypography.label)
                .foregroundStyle(primaryColor)
                .lineLimit(1)
                .truncationMode(.middle)
                .contentTransition(.opacity)

            if showsCopyChip {
                copyChip
            }
        }
        .contentShape(.rect)
    }

    /// The word "Copy", on a well of its own.
    ///
    /// The house rule is that every interactive control answers the pointer, and this one used to
    /// fail a weaker test than that: at rest it did not exist. The address was clickable and nothing
    /// said so — the type's own note calls it the most-copied string in the app — so the affordance
    /// was a tooltip you had to already be hovering to read. A chip is the smallest thing that can
    /// be there before the pointer is.
    ///
    /// It takes a well where the address deliberately does not. That is not the two controls
    /// disagreeing: the address is *type*, and lighting a rectangle behind a line of type inside a
    /// container that already has a fill and a hairline is what `DSClearButton` argues against. The
    /// chip is a chip — a filled rectangle at rest, which is a thing a pointer can be *on*. What
    /// moves under the pointer is the word rather than the fill, and ``copyChipFill`` records the
    /// contrast reading that decided that.
    ///
    /// The hidden "Copied" underneath is what stops the toolbar re-flowing when you click. The two
    /// words differ by about twenty points, and without a floor the divider and both counts slide
    /// right for a second and a half every time the address is copied — a jump the eye reads as the
    /// well having changed shape rather than as a confirmation.
    private var copyChip: some View {
        ZStack {
            Text("Copied").hidden()
            Text(showsCopyConfirmation ? "Copied" : "Copy")
        }
            .font(DSTypography.caption)
            .foregroundStyle(copyChipForeground)
            .padding(.horizontal, DSSpacing.xs)
            // 2, so the chip stands the same 16pt as the state mark's chip at the other end of the
            // well and the two read as one family.
            .padding(.vertical, DSSpacing.xxs)
            .background {
                RoundedRectangle(cornerRadius: DSCornerRadius.xs, style: .continuous)
                    .fill(copyChipFill)
            }
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
        Text(verbatim: Self.primaryText(serverState: serverState, projectName: projectName))
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

    /// The chip appears only when there is a URL to put on the pasteboard. Offering "Copy" beside
    /// "Server stopped" would be a button for an address that does not exist.
    private var showsCopyChip: Bool { isRunning }

    /// Confirmation is green — the one place in this well where the success colour is a *word* — so
    /// it takes ``DSColors/successText``, the variant measured on a tint of itself, rather than
    /// ``DSColors/success``, which is a signal colour and reads 3.94 there.
    private var copyChipForeground: Color {
        if showsCopyConfirmation { return DSColors.successText }
        return isURLHovered ? DSColors.accentText : DSColors.labelSecondary
    }

    /// One fill, in all three states, and it is the only one of the obvious candidates that a 10pt
    /// word can be read on.
    ///
    /// The chip was first drawn as a 6% ink wash that lit to ``DSColors/accentSubtle`` under the
    /// pointer, which is the idiom the rest of the window uses for a hover well — and measured on
    /// the green well it puts "Copy" at 4.27:1 in light and 4.16 in dark at rest, and the hovered
    /// blue at 4.37 and 4.05. Four readings, four failures, on a control whose entire job is to be
    /// legible before you have found it. The tint is what does it: `labelSecondary` clears AA on the
    /// bare toolbar at 4.61 and loses that margin the moment the well goes green.
    ///
    /// ``DSColors/tertiary`` is the recess token, opaque, and it steps *away* from the tint in both
    /// appearances rather than deeper into it. On it the three states read 4.55/4.67 at rest,
    /// 4.98/4.54 hovered and 5.76/5.61 confirming — measured in
    /// `DSContrastTests.runningWellTintIsReadable`. So the fill holds still and the *word* carries
    /// all three states, which is also the quieter animation.
    private var copyChipFill: Color { DSColors.tertiary }

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

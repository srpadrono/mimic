import SwiftUI
import AppKit
import Domain
import DesignSystem

/// Which half of the exchange the detail view is showing.
enum RequestDetailTab: String, CaseIterable, Identifiable {
    case summary = "Summary"
    case headers = "Headers"
    case body = "Body"

    var id: String { rawValue }
}

/// Everything about one logged request, shown in the inspector.
///
/// This used to be a pane carved out of the request log drawer, which is the wrong shape for it. The
/// drawer defaults to 220pt tall and spends 53 of those on chrome; splitting what was left 55/45 gave
/// the detail 74pt, of which its own tab bar and a section header took all but about 11 — and the
/// response, the half you opened it for, started below that fold. The inspector is the full height of
/// the window, so the same content gets roughly six times the room and the drawer goes back to being
/// a list that does not shrink when you click a row.
struct RequestDetailInspector: View {
    /// Everything needed to describe one logged request, bundled so the inspector panel takes one
    /// parameter for "show this request" rather than four that must be kept in step.
    struct Context: Equatable {
        var log: RequestLog
        var endpointName: String?
        var scenarioName: String?
        /// The port the server is on. `nil` when it is stopped.
        var port: Int?

        init(log: RequestLog, endpointName: String? = nil, scenarioName: String? = nil, port: Int? = nil) {
            self.log = log
            self.endpointName = endpointName
            self.scenarioName = scenarioName
            self.port = port
        }
    }

    let log: RequestLog
    let endpointName: String?
    let scenarioName: String?
    /// The port the server is on, for the `curl` command. `nil` when the server is stopped.
    let port: Int?

    @State private var selectedTab: RequestDetailTab
    @State private var searchText: String
    @State private var copyConfirmation: String?
    @State private var copyConfirmationTask: Task<Void, Never>?

    init(
        log: RequestLog,
        endpointName: String? = nil,
        scenarioName: String? = nil,
        port: Int? = nil,
        initialTab: RequestDetailTab = .summary,
        initialSearchText: String = ""
    ) {
        self.log = log
        self.endpointName = endpointName
        self.scenarioName = scenarioName
        self.port = port
        _selectedTab = State(initialValue: initialTab)
        _searchText = State(initialValue: initialSearchText)
    }

    init(context: Context, initialTab: RequestDetailTab = .summary, initialSearchText: String = "") {
        self.init(
            log: context.log,
            endpointName: context.endpointName,
            scenarioName: context.scenarioName,
            port: context.port,
            initialTab: initialTab,
            initialSearchText: initialSearchText
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            requestLine

            // `.standard`, not `.subtle`. This closes a chrome band — the same job the panel header's
            // own rule does. Three bands in this window were drawn at `border` (9%) while the other
            // seven used the panel weight, at identical thickness, so some bands ended visibly and
            // some barely did.
            DSDivider(style: .standard, identifier: "requestDetail.requestLine")

            Picker("View", selection: $selectedTab) {
                ForEach(RequestDetailTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            // Edge to edge between the row's insets, like everything above and below it. A segmented
            // control sizes to its titles, so in a 290pt inspector this one spanned x=48 to x=240 and
            // floated in the middle of a panel where every other row starts at 12 — which reads as a
            // control nobody finished placing rather than as a deliberate centre.
            //
            // `.infinity`, never a number. `maxWidth` caps *and* expands, and a numeric cap here would
            // do to this control what it did to the breadcrumb crumbs: make every one of them exactly
            // as wide as the cap, whatever the row could actually give them.
            .frame(maxWidth: .infinity)
            .padding(.horizontal, DSSpacing.md)
            .padding(.vertical, DSSpacing.sm)
            // The control-row rung. A small segmented control measures 20, so with `sm` above and
            // below this row already stood at 32 — stating it means the journey editor's behaviour
            // row and this one cannot drift apart the next time a control size changes underneath
            // them.
            .frame(height: DSBarHeight.controlRow)
            .accessibilityIdentifier("requestDetail.tabs")
            .accessibilityLabel("Request detail section")

            if selectedTab == .body {
                bodySearchField
            }

            ScrollView {
                switch selectedTab {
                case .summary: summaryContent
                case .headers: headersContent
                case .body: bodyContent
                }
            }
            .background(DSColors.dominant)

            copyBar
        }
        // The panel carries its own surface rather than inheriting one from `DSDrawer`. Without it
        // the tab row and the find field sit on whatever is behind them — which is the window's bare
        // background the moment this view is hosted anywhere else.
        .background(DSColors.secondary)
        // The tab is per-request state: carrying "Body" over to the next request you click is right,
        // but carrying a search term for a payload you are no longer looking at is not.
        .onChange(of: log.id) { _, _ in searchText = "" }
        .onDisappear {
            copyConfirmationTask?.cancel()
        }
        // Deliberately no identifier on this container. One here overrides every descendant's — the
        // accessibility dump showed the tabs, the path, the search field, and all three copy buttons
        // reporting `requestDetail.<uuid>` instead of their own names, which makes each of them
        // unaddressable from a test. `requestDetail.path` is the handle for "detail is showing".
        .accessibilityElement(children: .contain)
    }

    // MARK: - Request line

    /// Method, path, and status — the identity of the request, pinned above the tabs so it stays
    /// visible whichever section you are reading.
    @ViewBuilder
    private var requestLine: some View {
        VStack(alignment: .leading, spacing: DSSpacing.xs) {
            HStack(spacing: DSSpacing.sm) {
                DSMethodBadge(method: log.method.rawValue, size: .compact, identifier: "requestDetail.method")
                statusPill
                Spacer(minLength: 0)
                Text(log.timestamp, style: .time)
                    .font(DSTypography.caption)
                    .foregroundStyle(DSColors.labelTertiary)
            }

            // Two lines, then truncate. `.fixedSize(vertical:)` let this wrap without limit, so a
            // long path made the identity bar taller — the only bar in the window whose height was a
            // function of its content, and the panel below it moved down to make room. Two lines
            // covers essentially every real path; the full string is still selectable and the
            // tooltip carries it whole.
            Text(log.path)
                .font(DSTypography.codeSmall)
                .foregroundStyle(DSColors.labelPrimary)
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)
                .help(log.path)
                .accessibilityIdentifier("requestDetail.path")
        }
        .padding(.horizontal, DSSpacing.md)
        .padding(.vertical, DSSpacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Off the `DSBarHeight` ladder on purpose, and the only bar in the window that is. Two lines
        // of path at 10pt monospaced plus the badge line comes to 46pt with a short path and 59 with
        // a wrapped one — higher than every rung, because this is the one bar carrying a value rather
        // than labelling something. Pinning it to 32 would cost it the second line, which is the line
        // that tells two calls to the same route apart.
        //
        // `band`, not `secondary`. The panel header directly above is `secondary` and closes with a
        // 12% hairline; against an identical tone that rule was doing nothing, and the header and this
        // row read as one three-line block rather than as a header above the thing it names. A step
        // off the panel surface gives the hairline two tones to sit between.
        .background(DSColors.band)
    }

    /// `DSStatusPill` carries the convention this view used to hand-draw twice over: the failure
    /// arm ("drop", "timeout" — `destructiveText` on a tint of itself, always filled, because the
    /// base red reads 4.07:1 on a panel and 3.95 on the `band` this row actually is), and the
    /// `>= 400` fill gate for codes (`accentText`, the 3xx, is the arm that cannot survive its own
    /// fill: 4.35:1 on this `band`). A log with neither a failure label nor a code — nothing came
    /// back at all — takes the component's em-dash failure arm; it used to render `?? 0` here, a
    /// status no server ever sent, in secondary grey.
    @ViewBuilder
    private var statusPill: some View {
        if let failureLabel = log.failureLabel {
            DSStatusPill(failureLabel: failureLabel)
                .accessibilityIdentifier("requestDetail.failure")
        } else {
            DSStatusPill(statusCode: log.responseStatusCode)
                .accessibilityIdentifier("requestDetail.status")
        }
    }

    // MARK: - Summary

    @ViewBuilder
    private var summaryContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            DSSectionHeader("Answered by", identifier: "requestDetail.answeredBy")

            summaryRow("Outcome", value: log.outcome.label, valueColor: outcomeColor)
            summaryRow("Endpoint", value: endpointName ?? "\u{2014}")
            summaryRow("Scenario", value: scenarioName ?? "\u{2014}", valueColor: scenarioName != nil ? DSColors.accentText : nil)

            DSSectionHeader("Sizes", identifier: "requestDetail.sizes")

            summaryRow("Request body", value: Self.byteSummary(log.requestBody))
            summaryRow(
                "Response body",
                value: Self.byteSummary(log.responseBody) + (log.responseBodyTruncated ? " (truncated)" : "")
            )
            summaryRow("Request headers", value: "\(log.requestHeaders.count)")
            summaryRow("Response headers", value: "\(log.responseHeaders.count)")

            if log.outcome.isMissingConfiguration {
                Text("Nothing was configured for this call, so Mimic answered with its fallback. Right-click the row in the request log to create an endpoint for it.")
                    .font(DSTypography.caption)
                    // `labelSecondary`. This sentence is the only place the panel explains what an
                    // unmatched request is and what to do about it — and `DSContrastTests` asserts
                    // that `labelTertiary` clears AA on no surface in this app, in either appearance.
                    // The summary rows just above already carry that correction; this paragraph, and
                    // the truncation note further down, were the two that did not.
                    .foregroundStyle(DSColors.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(DSSpacing.md)
                    .accessibilityIdentifier("requestDetail.unmatchedHint")
            }
        }
    }

    /// Label right-aligned in `InspectorRowMetrics.detailLabelColumn`, value flush left in the rest — the
    /// same seam the overview draws, so the panel does not re-lay itself out when you click a logged
    /// request. The `Spacer` this replaces pushed the two halves to opposite edges of a 280pt panel
    /// and left the values with a ragged right edge.
    @ViewBuilder
    private func summaryRow(_ label: String, value: String, valueColor: Color? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DSSpacing.sm) {
            Text(label)
                .font(DSTypography.caption)
                // `labelSecondary`. These are read, not glanced past — at 36% alpha they measure
                // 2.5:1, and `labelTertiary` is for timestamps and separators.
                .foregroundStyle(DSColors.labelSecondary)
                .frame(width: InspectorRowMetrics.detailLabelColumn, alignment: .trailing)
            Text(value)
                .font(DSTypography.codeSmall)
                .foregroundStyle(valueColor ?? DSColors.labelPrimary)
                .textSelection(.enabled)
                // An endpoint or scenario name is arbitrary length; wrap it rather than clip it.
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, DSSpacing.md)
        .padding(.vertical, DSSpacing.xs + 1)
        .accessibilityElement(children: .combine)
    }

    private var outcomeColor: Color {
        switch log.outcome {
        case .endpoint: DSColors.labelPrimary
        case .journey: DSColors.accentText
        case .unmatched: DSColors.httpStatusColor(for: 404)
        case .blockedByJourney: DSColors.warning
        }
    }

    // MARK: - Headers

    @ViewBuilder
    private var headersContent: some View {
        // Not lazy. A request has a handful of headers, so laziness buys nothing here — and it costs:
        // rows that have not been materialised yet are simply absent, which showed up as a response
        // header silently missing from the panel.
        VStack(alignment: .leading, spacing: 0) {
            // "Request headers", not "Request". The panel's own header a hundred points above this
            // one already says "Request" — it is the mode indicator, and it means "you are looking
            // at a logged request" rather than "the request half of this exchange". Two senses of
            // one word, stacked. The long names are also what the Summary tab's rows already call
            // these ("Request headers 3", "Response body 20 B"), so this is the panel agreeing with
            // itself rather than a new vocabulary.
            headerSection(
                title: "Request headers",
                identifier: "request",
                headers: log.requestHeaders,
                emptyMessage: "No request headers"
            )

            headerSection(
                title: responseSectionTitle("headers"),
                identifier: "response",
                headers: log.responseHeaders,
                emptyMessage: log.failureLabel.map { "No response — the connection was \($0)" }
                    ?? "No response headers"
            )
        }
    }

    @ViewBuilder
    private func headerSection(
        title: String,
        identifier: String,
        headers: [String: String],
        emptyMessage: String
    ) -> some View {
        DSSectionHeader(title, identifier: "requestDetail.headers.\(identifier)")

        if headers.isEmpty {
            emptyNote(emptyMessage, identifier: "requestDetail.headers.\(identifier).empty")
        } else {
            ForEach(Array(headers.sorted(by: { $0.key < $1.key }).enumerated()), id: \.element.key) { index, header in
                // Key above value rather than beside it. The inspector is 220–400pt wide, and a
                // two-column layout at that width truncates both halves of every interesting header.
                VStack(alignment: .leading, spacing: 1) {
                    Text(header.key)
                        .font(DSTypography.caption)
                        // The key is the half you scan for; it cannot be the fainter half.
                        .foregroundStyle(DSColors.labelSecondary)
                    Text(header.value)
                        .font(DSTypography.codeSmall)
                        .foregroundStyle(DSColors.labelPrimary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, DSSpacing.md)
                .padding(.vertical, DSSpacing.xs + 1)
                .background(index % 2 == 0 ? Color.clear : DSColors.rowStripe)
                .accessibilityElement(children: .combine)
            }
        }
    }

    // MARK: - Body

    @ViewBuilder
    private var bodySearchField: some View {
        HStack(spacing: DSSpacing.xs) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: DSGlyph.inline, weight: .medium))
                .foregroundStyle(DSColors.labelTertiary)
            TextField("Find in body", text: $searchText)
                .textFieldStyle(.plain)
                .font(DSTypography.codeSmall)
                .accessibilityIdentifier("requestDetail.bodySearchField")
                .accessibilityLabel("Find in body")

            if !searchText.isEmpty {
                // The same control `DSFilterField` uses, not a second drawing of it. The two were
                // hand-written twice at 10pt and 11pt in identical 18×18 wells, each with a comment
                // claiming to match the other; only the frame ever did, and only one of them answered
                // the pointer.
                DSClearButton(
                    text: $searchText,
                    identifier: "requestDetail.clearBodySearch",
                    label: "Clear the search",
                    help: "Clear the search"
                )
            }
        }
        .padding(.horizontal, DSSpacing.sm)
        // `DSControlHeight.row` — the rung `DSFilterField` and the request log's header controls
        // stand on. This well inferred its height from padding alone, so the app's two search fields
        // were a point apart for no reason anyone chose; the note that fixed that then wrote the
        // number out by hand next to the name of the token holding it.
        .frame(height: DSControlHeight.row)
        .background(
            RoundedRectangle(cornerRadius: DSCornerRadius.sm)
                .fill(DSColors.tertiary)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DSCornerRadius.sm)
                .stroke(DSColors.border, lineWidth: DSStroke.hairline)
        )
        .padding(.horizontal, DSSpacing.md)
        .padding(.bottom, DSSpacing.sm)
    }

    @ViewBuilder
    private var bodyContent: some View {
        // Two sections, so laziness would only add the risk of one of them not appearing. The
        // expensive part of a body is its formatting, and that is already off the main actor.
        VStack(alignment: .leading, spacing: 0) {
            DSSectionHeader("Request body", identifier: "requestDetail.body.request")

            if let requestBody = log.requestBody, !requestBody.isEmpty {
                RequestBodyView(payload: requestBody, searchText: searchText, identifier: "request")
            } else {
                emptyNote("No request body", identifier: "requestDetail.body.request.empty")
            }

            DSSectionHeader(responseSectionTitle("body"), identifier: "requestDetail.body.response")

            if let responseBody = log.responseBody, !responseBody.isEmpty {
                RequestBodyView(payload: responseBody, searchText: searchText, identifier: "response")

                if log.responseBodyTruncated {
                    Text("Truncated at \(RequestLog.maxLoggedBodyBytes / 1024) KB.")
                        .font(DSTypography.caption)
                        // The one thing telling you the payload above is not the whole payload. See
                        // the unmatched note above for why this is not `labelTertiary`.
                        .foregroundStyle(DSColors.labelSecondary)
                        .padding(.horizontal, DSSpacing.md)
                        .padding(.vertical, DSSpacing.xs)
                }
            } else {
                emptyNote(
                    log.failureLabel.map { "No response — the connection was \($0)" } ?? "No response body",
                    identifier: "requestDetail.body.response.empty"
                )
            }
        }
    }

    // MARK: - Copy bar

    /// The three things you actually do with a logged request, as buttons rather than as a single
    /// "copy everything" blob you then have to edit down.
    ///
    /// **The verb is stated once, in front.** The row rendered as `cURL  Response  All` — three bare
    /// nouns in accent blue, no glyph, no shared label — which is the shape of a row of links, not a
    /// row of actions. The tooltips said "copy"; a tooltip is not an affordance, since you have to
    /// have already pointed at the thing to read it. The alternatives lose: prefixing each button
    /// ("Copy cURL / Copy response / Copy all") says the verb three times and nearly doubles a row
    /// that has to fit a 220pt panel, and a `doc.on.doc` on each button puts three identical glyphs in
    /// a row to make one point.
    @ViewBuilder
    private var copyBar: some View {
        VStack(spacing: 0) {
            DSDivider(style: .standard, identifier: "requestDetail.copyBar")

            HStack(spacing: DSSpacing.sm) {
                HStack(spacing: DSSpacing.sm) {
                    // Hidden from VoiceOver, which already hears the whole verb on every button —
                    // each one is labelled with its own `help` ("Copy as a curl command"). This word
                    // is for the eye that has not pointed at anything yet.
                    Text("Copy")
                        .font(DSTypography.caption)
                        .foregroundStyle(DSColors.labelSecondary)
                        .accessibilityHidden(true)

                    copyButton(
                        "cURL",
                        help: port == nil
                            ? "Copy as a curl command — the server is stopped, so the URL has no port"
                            : "Copy as a curl command",
                        identifier: "curl"
                    ) {
                        RequestLogExport.curl(for: log, port: port)
                    }

                    copyButton("Response", help: "Copy the response body", identifier: "responseBody") {
                        log.responseBody.map(RequestLogExport.formattedBody) ?? ""
                    }
                    .disabled(log.responseBody?.isEmpty != false)

                    copyButton("All", help: "Copy the full request and response as text", identifier: "all") {
                        RequestLogQuery.formattedDetails(for: log)
                    }
                }
                // The controls hold their width and the confirmation is what yields. At the
                // inspector's 220pt minimum this row is full once the label and the three buttons are
                // in it, and an `HStack` with nothing prioritised splits the shortfall in proportion
                // — which spends a control's name ("cUR…") on a message about a copy that has already
                // happened.
                .layoutPriority(1)

                Spacer(minLength: 0)

                if let copyConfirmation {
                    Text(copyConfirmation)
                        .font(DSTypography.caption)
                        .foregroundStyle(DSColors.success)
                        // One line. The row is pinned to a single bar height, so wrapping is not
                        // shorter text, it is clipped text.
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .transition(.opacity)
                        .accessibilityIdentifier("requestDetail.copyConfirmation")
                }
            }
            .padding(.horizontal, DSSpacing.md)
            // The panel-header rung, so the bar that closes the inspector carries the weight of the
            // bars that open every other panel. Not, as this note used to say, so that it lines up
            // with the status bar beneath it — that bar is gone, and the copy bar is now the bottom
            // edge of the inspector column.
            .frame(height: DSBarHeight.panelHeader)
            .background(DSColors.secondary)
        }
    }

    /// `DSButton`'s ghost variant — accent text, no fill, no border — which is what these were
    /// hand-drawing: a `.plain` button tinted accent, padded, and pinned to 20pt, which is `.small`'s
    /// height exactly. The one thing the hand-written version left out was any response to the
    /// pointer, and these three are the buttons in this panel a user goes looking for most.
    @ViewBuilder
    private func copyButton(
        _ title: String,
        help: String,
        identifier: String,
        content: @escaping () -> String
    ) -> some View {
        DSButton(
            title,
            variant: .ghost,
            size: .small,
            identifier: "requestDetail.copy.\(identifier)"
        ) {
            copy(content(), confirmation: "Copied \(title.lowercased())")
        }
        .help(help)
        // Applied outside, so it wins over the `ds.button.…` name `DSButton` gives itself and the
        // title it uses as a label. The suite reaches these by `requestDetail.copy.<id>`.
        .accessibilityIdentifier("requestDetail.copy.\(identifier)")
        .accessibilityLabel(help)
    }

    private func copy(_ text: String, confirmation: String) {
        Self.write(text, to: .general)

        copyConfirmationTask?.cancel()
        withAnimation(.easeOut(duration: DSAnimation.fast)) {
            copyConfirmation = confirmation
        }
        copyConfirmationTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: DSAnimation.fast)) {
                copyConfirmation = nil
            }
        }
    }

    // MARK: - Shared bits

    @ViewBuilder
    private func emptyNote(_ message: String, identifier: String) -> some View {
        Text(message)
            .font(DSTypography.caption)
            // The only thing in an empty section, so it is the thing to read.
            .foregroundStyle(DSColors.labelSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DSSpacing.md)
            .accessibilityIdentifier(identifier)
    }

    /// Names what answered, so an empty response section explains itself.
    ///
    /// Takes the noun rather than assuming one, because the same sentence heads both the headers
    /// section and the body section and each has to say which of the two it is — the panel header
    /// above them already spends the bare word "Request" on the mode.
    private func responseSectionTitle(_ noun: String) -> String {
        switch log.outcome {
        case .endpoint: "Response \(noun)"
        case .journey: "Response \(noun) (journey)"
        case .unmatched: "Response \(noun) (no endpoint configured)"
        case .blockedByJourney: "Response \(noun) (blocked by the active journey)"
        }
    }

    // MARK: - Testable seams

    static func write(_ text: String, to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// A body's size in the units a person reads, or a dash when there is no body.
    nonisolated static func byteSummary(_ body: String?) -> String {
        guard let body, !body.isEmpty else { return "\u{2014}" }
        let bytes = body.utf8.count
        if bytes < 1024 { return "\(bytes) B" }
        return String(format: "%.1f KB", Double(bytes) / 1024)
    }
}

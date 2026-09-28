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

    var onSaveAsMock: ((UUID) -> Void)?
    let log: RequestLog
    let endpointName: String?
    let scenarioName: String?
    /// The port the server is on, for the `curl` command. `nil` when the server is stopped.
    let port: Int?

    private var captureIssue: String? {
        do { try ResponseCapture.validate(log); return nil }
        catch { return error.localizedDescription }
    }

    @State private var selectedTab: RequestDetailTab
    private let tabSelection: Binding<RequestDetailTab>?
    @State private var searchText: String
    @State private var copyConfirmation: String?
    @State private var copyConfirmationTask: Task<Void, Never>?
    /// Drives the find field's focus ring, which `.textFieldStyle(.plain)` would otherwise drop.
    @FocusState private var searchFieldIsFocused: Bool

    init(
        log: RequestLog,
        endpointName: String? = nil,
        scenarioName: String? = nil,
        port: Int? = nil,
        onSaveAsMock: ((UUID) -> Void)? = nil,
        initialTab: RequestDetailTab = .summary,
        initialSearchText: String = "",
        tabSelection: Binding<RequestDetailTab>? = nil
    ) {
        self.onSaveAsMock = onSaveAsMock
        self.log = log
        self.endpointName = endpointName
        self.scenarioName = scenarioName
        self.port = port
        _selectedTab = State(initialValue: initialTab)
        self.tabSelection = tabSelection
        _searchText = State(initialValue: initialSearchText)
    }

    init(context: Context, onSaveAsMock: ((UUID) -> Void)? = nil, initialTab: RequestDetailTab = .summary, initialSearchText: String = "", tabSelection: Binding<RequestDetailTab>? = nil) {
        self.init(
            log: context.log,
            endpointName: context.endpointName,
            scenarioName: context.scenarioName,
            port: context.port,
            onSaveAsMock: onSaveAsMock,
            initialTab: initialTab,
            initialSearchText: initialSearchText,
            tabSelection: tabSelection
        )
    }

    private var activeTab: RequestDetailTab { tabSelection?.wrappedValue ?? selectedTab }
    private var activeTabBinding: Binding<RequestDetailTab> { tabSelection ?? $selectedTab }

    var body: some View {
        VStack(spacing: 0) {
            identity

            DSSegmentedControl(
                "Request detail section",
                segments: RequestDetailTab.allCases.map { tab in
                    DSSegmentedControl<RequestDetailTab>.Segment(
                        tab.rawValue, value: tab, identifier: "requestDetail.tab.\(tab.id.lowercased())"
                    )
                },
                selection: activeTabBinding,
                fillsWidth: true,
                identifier: "requestDetail.tabs"
            )
            .padding(.horizontal, DSInspectorMetrics.inset)
            .padding(.bottom, DSSpacing.md)

            if activeTab == .body {
                bodySearchField
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    captureControls
                    switch activeTab {
                    case .summary: summaryContent
                    case .headers: headersContent
                    case .body: bodyContent
                    }
                }
                .padding(.bottom, DSSpacing.lg)
            }
        }
        // The tab follows the inspector across requests; a search term belongs to one payload.
        .onChange(of: log.id) { _, _ in searchText = "" }
        .onDisappear {
            copyConfirmationTask?.cancel()
        }
        // No identifier on this container: one here would override every descendant's.
        .accessibilityElement(children: .contain)
    }

    // Capture guidance stays inside the scrolling region; wrapped text in the fixed part of the
    // inspector can trigger an AppKit constraint loop in small windows.
    @ViewBuilder
    private var captureControls: some View {
        if log.outcome == .passthrough, let onSaveAsMock {
            VStack(alignment: .leading, spacing: DSSpacing.sm) {
                DSButton(
                    "Save response as mock",
                    systemImage: "square.and.arrow.down",
                    variant: .primary,
                    size: .medium,
                    identifier: "requestDetail.saveMock"
                ) { onSaveAsMock(log.id) }
                .disabled(captureIssue != nil)
                .help("Saves the response body and safe headers in this project. Review private data before sharing.")
                .accessibilityIdentifier("requestDetail.saveMock")
                .accessibilityLabel("Save response as mock")

                if let captureIssue {
                    Text(captureIssue)
                        .font(DSTypography.callout)
                        .foregroundStyle(DSColors.labelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("requestDetail.captureIssue")
                }
            }
            .padding(.horizontal, DSInspectorMetrics.inset)
            .padding(.bottom, DSSpacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Identity

    /// Method and path, the status with what answered, timing and size, and the copy actions.
    @ViewBuilder
    private var identity: some View {
        VStack(alignment: .leading, spacing: DSSpacing.sm) {
            HStack(alignment: .firstTextBaseline, spacing: DSSpacing.sm) {
                DSMethodLabel(log.method.rawValue, fixedWidth: false, identifier: "requestDetail.method")
                // Two lines, then truncate in the middle; the tooltip carries the whole path.
                Text(log.path)
                    .font(DSTypography.codeLarge)
                    .foregroundStyle(DSColors.labelPrimary)
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .help(log.path)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("requestDetail.path")
            }

            HStack(spacing: DSSpacing.md) {
                statusLabel
                Spacer(minLength: DSSpacing.sm)
                HStack(spacing: 0) {
                    if let metrics = metricsText {
                        Text(metrics + " \u{00B7} ")
                    }
                    Text(log.timestamp, format: RequestLogQuery.timestampFormat)
                        .accessibilityIdentifier("requestDetail.timestamp")
                }
                .font(DSTypography.Figure.regular)
                .foregroundStyle(DSColors.labelSecondary)
                .lineLimit(1)
            }

            Text(outcomeExplanation)
                .font(DSTypography.callout)
                .foregroundStyle(outcomeExplanationColor)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("requestDetail.outcome")

            copyActions
        }
        .padding(.horizontal, DSInspectorMetrics.inset)
        .padding(.top, DSSpacing.xs)
        .padding(.bottom, DSSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Dot and code; a failed exchange shows its failure in the error colour.
    @ViewBuilder
    private var statusLabel: some View {
        if let failureLabel = log.failureLabel {
            DSInspectorStatus(statusCode: nil, failure: failureLabel)
                .accessibilityIdentifier("requestDetail.failure")
        } else {
            DSInspectorStatus(statusCode: log.responseStatusCode)
                .accessibilityIdentifier("requestDetail.status")
        }
    }

    /// "2 ms · 214 B", or whichever half is known.
    private var metricsText: String? {
        let parts = [
            log.durationMs.map(RequestLogQuery.formattedDuration),
            RequestLogQuery.formattedSize(for: log),
        ].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " \u{00B7} ")
    }

    /// One sentence saying what answered, coloured like the outcome.
    private var outcomeExplanation: String {
        switch log.outcome {
        case .endpoint:
            if let endpointName, let scenarioName { return "Answered by \(endpointName), \(scenarioName)" }
            return endpointName.map { "Answered by \($0)" } ?? "Answered by an endpoint"
        case .journey: return "Answered by the active journey"
        case .unmatched: return "No endpoint matched, so Mimic answered with its fallback"
        case .blockedByJourney: return "Blocked by the active journey"
        case .proxyFailure: return "The real backend could not be reached"
        case .passthrough: return "Passed through to \(log.backendName ?? "the real backend")"
        }
    }

    private var outcomeExplanationColor: Color {
        switch log.outcome {
        case .endpoint, .journey, .passthrough: DSColors.labelSecondary
        default: outcomeColor
        }
    }

    // MARK: - Summary

    @ViewBuilder
    private var summaryContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            DSInspectorSectionHeader("Answered by", identifier: "requestDetail.answeredBy")

            summaryRow("Outcome", value: log.outcome.label, valueColor: outcomeColor)
            if let name = log.backendName { summaryRow("Backend", value: name) }
            if let port = log.listenerPort { summaryRow("Local URL", value: "http://localhost:\(port)") }
            if let upstream = log.upstreamURL { summaryRow("Forwarded to", value: upstream) }
            if let duration = log.durationMs { summaryRow("Duration", value: RequestLogQuery.formattedDuration(duration)) }
            summaryRow("Endpoint", value: endpointName ?? "\u{2014}")
            summaryRow("Scenario", value: scenarioName ?? "\u{2014}",
                       valueColor: scenarioName != nil ? DSColors.accent : DSColors.labelSecondary)

            DSInspectorSectionHeader("Sizes", identifier: "requestDetail.sizes")

            summaryRow("Request body", value: Self.byteSummary(log.requestBody)
                       + (log.requestBodyTruncated == true ? " (truncated)" : ""))
            summaryRow(
                "Response body",
                value: (log.responseBodyIsBinary == true
                        ? "Binary or non-UTF-8 (not previewed)"
                        : Self.byteSummary(log.responseBody))
                    + (log.responseBodyTruncated ? " (truncated)" : "")
            )
            summaryRow("Request headers", value: "\(log.requestHeaders.count)")
            summaryRow("Response headers", value: "\(log.responseHeaders.count)")

            if log.outcome.isMissingConfiguration {
                Text("Nothing was configured for this call, so Mimic answered with its fallback. Right-click the row in the request log to create an endpoint for it.")
                    .font(DSTypography.callout)
                    .foregroundStyle(DSColors.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineSpacing(DSSpacing.xxs)
                    .padding(.horizontal, DSInspectorMetrics.inset)
                    .padding(.top, DSSpacing.md)
                    .accessibilityIdentifier("requestDetail.unmatchedHint")
            }
        }
    }

    /// Summary, journey and project fields share the same label/value alignment.
    @ViewBuilder
    private func summaryRow(_ label: String, value: String, valueColor: Color? = nil) -> some View {
        DSInspectorValueRow(label, value: value, color: valueColor ?? DSColors.labelPrimary,
                            identifier: "requestDetail.summary.\(label.lowercased())")
    }

    private var outcomeColor: Color {
        switch log.outcome {
        case .endpoint: DSColors.labelPrimary
        case .journey: DSColors.accent
        case .unmatched: DSColors.warning
        case .blockedByJourney: DSColors.warning
        case .proxyFailure: DSColors.error
        case .passthrough: DSColors.success
        }
    }

    // MARK: - Headers

    @ViewBuilder
    private var headersContent: some View {
        // Not lazy: rows not yet materialised would simply be missing.
        VStack(alignment: .leading, spacing: 0) {
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
                emptyMessage: log.failureLabel.map { "No response. The connection was \($0)." }
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
        DSInspectorSectionHeader(title, identifier: "requestDetail.headers.\(identifier)")

        if headers.isEmpty {
            emptyNote(emptyMessage, identifier: "requestDetail.headers.\(identifier).empty")
        } else {
            ForEach(Array(headers.sorted(by: { $0.key < $1.key }).enumerated()), id: \.element.key) { index, header in
                // Name above value: the inspector is too narrow for two useful columns.
                VStack(alignment: .leading, spacing: DSSpacing.xxs) {
                    Text(header.key)
                        .font(DSTypography.code)
                        .foregroundStyle(DSColors.labelSecondary)
                    Text(header.value)
                        .font(DSTypography.code)
                        .foregroundStyle(DSColors.labelPrimary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, DSSpacing.sm)
                .padding(.vertical, DSSpacing.xs)
                .background {
                    RoundedRectangle(cornerRadius: DSCornerRadius.mark)
                        .fill(index % 2 == 0 ? Color.clear : DSColors.zebra)
                }
                .padding(.horizontal, DSSpacing.sm)
                .accessibilityElement(children: .combine)
                // Keyed by the header's name, so the row keeps its identity when the sort moves it.
                .accessibilityIdentifier("requestDetail.headers.\(identifier).\(header.key)")
            }
        }
    }

    // MARK: - Body

    @ViewBuilder
    private var bodySearchField: some View {
        HStack(spacing: DSSpacing.xs + 2) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: DSGlyph.field, weight: .regular))
                .foregroundStyle(DSColors.labelTertiary)
                .accessibilityHidden(true)
            TextField("Find in body", text: $searchText)
                .textFieldStyle(.plain)
                .font(DSTypography.callout)
                .focused($searchFieldIsFocused)
                .accessibilityIdentifier("requestDetail.bodySearchField")
                .accessibilityLabel("Find in body")

            if !searchText.isEmpty {
                DSClearButton(
                    text: Binding(
                        get: { searchText },
                        set: {
                            searchText = $0
                            searchFieldIsFocused = true
                        }
                    ),
                    identifier: "requestDetail.clearBodySearch",
                    label: "Clear the search",
                    help: "Clear the search"
                )
            }
        }
        .dsFieldChrome(height: DSControlHeight.regular, cornerRadius: DSControlHeight.regular / 2,
                       isFocused: searchFieldIsFocused)
        .padding(.horizontal, DSInspectorMetrics.inset)
        .padding(.bottom, DSSpacing.sm)
    }

    @ViewBuilder
    private var bodyContent: some View {
        // Two sections; laziness would only risk one of them not appearing.
        VStack(alignment: .leading, spacing: 0) {
            DSInspectorSectionHeader("Request body", identifier: "requestDetail.body.request")

            if let requestBody = log.requestBody, !requestBody.isEmpty {
                RequestBodyView(payload: requestBody, searchText: searchText, identifier: "request")
            } else {
                emptyNote("No request body", identifier: "requestDetail.body.request.empty")
            }
            if log.requestBodyTruncated == true {
                truncationNote(identifier: "request")
            }

            DSInspectorSectionHeader(responseSectionTitle("body"), identifier: "requestDetail.body.response")

            if log.responseBodyIsBinary == true {
                emptyNote("Binary or non-UTF-8 response body is not previewed",
                          identifier: "requestDetail.body.response.empty")
            } else if let responseBody = log.responseBody, !responseBody.isEmpty {
                RequestBodyView(payload: responseBody, searchText: searchText, identifier: "response")

                if log.responseBodyTruncated {
                    truncationNote(identifier: "response")
                }
            } else {
                emptyNote(
                    log.failureLabel.map { "No response. The connection was \($0)." } ?? "No response body",
                    identifier: "requestDetail.body.response.empty"
                )
            }
        }
    }

    private func truncationNote(identifier: String) -> some View {
        Text("Truncated at \(RequestLog.maxLoggedBodyBytes / 1024) KB.")
            .font(DSTypography.callout)
            .foregroundStyle(DSColors.labelSecondary)
            .padding(.horizontal, DSInspectorMetrics.inset)
            .padding(.vertical, DSSpacing.xs)
            .accessibilityIdentifier("requestDetail.body.\(identifier).truncated")
    }

    // MARK: - Copy actions

    /// The three things you do with a logged request. cURL is the main one, so it gets the filled
    /// secondary button; the others are quieter.
    @ViewBuilder
    private var copyActions: some View {
        HStack(spacing: DSSpacing.xs) {
            copyButton(
                "Copy as cURL",
                variant: .secondary,
                help: RequestLogExport.curlUnavailability(for: log).map { "Copy as a curl command. \($0)" }
                    ?? (port == nil
                        ? "Copy as a curl command. The server is stopped, so the URL has no port."
                        : "Copy as a curl command"),
                identifier: "curl",
                confirmation: "Copied cURL"
            ) {
                RequestLogExport.curl(for: log, port: port)
            }
            .disabled(RequestLogExport.curlUnavailability(for: log) != nil)

            copyButton(
                "Response",
                variant: .ghost,
                help: log.responseBodyTruncated
                    ? "Copy the available response body preview" : "Copy the response body",
                identifier: "responseBody",
                confirmation: "Copied response"
            ) {
                log.responseBody.map(RequestLogExport.formattedBody) ?? ""
            }
            .disabled(log.responseBody?.isEmpty != false)

            copyButton(
                "All",
                variant: .ghost,
                help: "Copy the full request and response as text",
                identifier: "all",
                confirmation: "Copied all"
            ) {
                RequestLogQuery.formattedDetails(for: log)
            }
            // The buttons keep their width; the confirmation yields.
            .layoutPriority(1)

            Spacer(minLength: 0)

            if let copyConfirmation {
                ViewThatFits(in: .horizontal) {
                    Text(copyConfirmation)
                        .font(DSTypography.caption)
                        .fixedSize(horizontal: true, vertical: false)
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: DSGlyph.field))
                        .accessibilityLabel(copyConfirmation)
                }
                .foregroundStyle(DSColors.success)
                .transition(.opacity)
                .accessibilityIdentifier("requestDetail.copyConfirmation")
            }
        }
        .padding(.top, DSSpacing.xxs)
    }

    @ViewBuilder
    private func copyButton(
        _ title: String,
        variant: DSButtonVariant,
        help: String,
        identifier: String,
        confirmation: String,
        content: @escaping () -> String
    ) -> some View {
        DSButton(
            title,
            systemImage: variant == .secondary ? "doc.on.doc" : nil,
            variant: variant,
            size: .small,
            identifier: "requestDetail.copy.\(identifier)"
        ) {
            copy(content(), confirmation: confirmation)
        }
        .fixedSize()
        .help(help)
        // Applied outside, so it wins over the `ds.button.…` name the suite does not use.
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
            .font(DSTypography.callout)
            .foregroundStyle(DSColors.labelTertiary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, DSInspectorMetrics.inset)
            .padding(.vertical, DSSpacing.xs)
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
        case .proxyFailure: "Backend failure \(noun)"
        case .passthrough: "Response \(noun) (real backend)"
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

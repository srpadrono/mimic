import SwiftUI
import AppKit
import Domain
import DesignSystem
import FeatureSupport

/// Which part of the exchange the detail view is showing: what arrived, what answered, and when.
enum RequestDetailTab: String, CaseIterable, Identifiable {
    case request = "Request"
    case response = "Response"
    case timing = "Timing"

    var id: String { rawValue }
}

/// Everything about one logged request, beside the request log in the centre column.
///
/// The request line and what came back head it, with the one action the outcome calls for; below
/// them the Request, Response and Timing tabs each lay their facts out as two columns — a name on
/// the left, its value on the right, both in the code face — in sections divided by hairlines.
struct RequestDetailView: View {
    /// Everything needed to describe one logged request, resolved against the current project so
    /// endpoint and scenario names follow renames.
    struct Context: Equatable {
        var log: RequestLog
        var endpointName: String?
        var scenarioName: String?
        /// Whether the endpoint that answered is still in the project, so it can be opened.
        var endpointExists: Bool
        /// The port the call arrived on, or the server's current one. `nil` when neither is known.
        var port: Int?

        init(
            log: RequestLog,
            endpointName: String? = nil,
            scenarioName: String? = nil,
            endpointExists: Bool = false,
            port: Int? = nil
        ) {
            self.log = log
            self.endpointName = endpointName
            self.scenarioName = scenarioName
            self.endpointExists = endpointExists
            self.port = port
        }
    }

    let context: Context
    var onCreateEndpoint: ((HTTPMethod, String) -> Void)?
    var onSaveAsMock: ((UUID) -> Void)?
    var onGoToEndpoint: ((UUID) -> Void)?
    /// Deselects the request, which gives the centre column back to the editor.
    var onClose: (() -> Void)?

    @State private var selectedTab: RequestDetailTab
    private let tabSelection: Binding<RequestDetailTab>?
    @State private var copyConfirmation: String?
    @State private var copyConfirmationTask: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The name column of Summary rows, and of header and query rows.
    private static let summaryKeyWidth: CGFloat = 96
    private static let pairNameWidth: CGFloat = 150
    /// The vertical rhythm between the header's lines and between sections.
    private static let blockSpacing: CGFloat = 14

    init(
        context: Context,
        onCreateEndpoint: ((HTTPMethod, String) -> Void)? = nil,
        onSaveAsMock: ((UUID) -> Void)? = nil,
        onGoToEndpoint: ((UUID) -> Void)? = nil,
        onClose: (() -> Void)? = nil,
        initialTab: RequestDetailTab = .request,
        tabSelection: Binding<RequestDetailTab>? = nil
    ) {
        self.context = context
        self.onCreateEndpoint = onCreateEndpoint
        self.onSaveAsMock = onSaveAsMock
        self.onGoToEndpoint = onGoToEndpoint
        self.onClose = onClose
        _selectedTab = State(initialValue: initialTab)
        self.tabSelection = tabSelection
    }

    init(
        log: RequestLog,
        endpointName: String? = nil,
        scenarioName: String? = nil,
        port: Int? = nil,
        onSaveAsMock: ((UUID) -> Void)? = nil,
        initialTab: RequestDetailTab = .request
    ) {
        self.init(
            context: Context(log: log, endpointName: endpointName, scenarioName: scenarioName, port: port),
            onSaveAsMock: onSaveAsMock,
            initialTab: initialTab
        )
    }

    private var log: RequestLog { context.log }
    private var activeTab: RequestDetailTab { tabSelection?.wrappedValue ?? selectedTab }
    private var activeTabBinding: Binding<RequestDetailTab> { tabSelection ?? $selectedTab }

    private var captureIssue: String? {
        do { try ResponseCapture.validate(log); return nil }
        catch { return error.localizedDescription }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: Self.blockSpacing) {
                requestLine
                statusLine
                DSSegmentedControl(
                    "Request detail section",
                    segments: RequestDetailTab.allCases.map { tab in
                        DSSegmentedControl<RequestDetailTab>.Segment(
                            tab.rawValue, value: tab, identifier: "requestDetail.tab.\(tab.id.lowercased())"
                        )
                    },
                    selection: activeTabBinding,
                    identifier: "requestDetail.tabs"
                )
            }
            .padding(.horizontal, DSSpacing.xl)
            .padding(.top, DSSpacing.lg)
            .padding(.bottom, Self.blockSpacing)

            ScrollView {
                // Not lazy: rows not yet materialised would simply be missing.
                VStack(alignment: .leading, spacing: Self.blockSpacing) {
                    switch activeTab {
                    case .request: requestContent
                    case .response: responseContent
                    case .timing: timingContent
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, DSSpacing.xl)
                .padding(.bottom, DSSpacing.lg)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onDisappear { copyConfirmationTask?.cancel() }
        // Named with `.contain`, so every control inside keeps its own identifier.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("requestDetail")
    }

    // MARK: - Header

    /// Method and path in the code face, then the copy action and the one thing to do next. When the
    /// path and the actions do not fit on one line, the actions drop onto a line of their own.
    private var requestLine: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: DSSpacing.md - 2) {
                requestIdentity
                requestActions
            }
            VStack(alignment: .leading, spacing: DSSpacing.sm) {
                HStack(alignment: .center, spacing: DSSpacing.md - 2) { requestIdentity }
                HStack(alignment: .center, spacing: DSSpacing.md - 2) { requestActions }
            }
        }
    }

    @ViewBuilder
    private var requestIdentity: some View {
        Text(log.method.rawValue)
            .font(DSTypography.codeLarge.weight(.semibold))
            .foregroundStyle(DSColors.methodColor(for: log.method.rawValue))
            .fixedSize()
            .accessibilityLabel("\(log.method.rawValue) method")
            .accessibilityIdentifier("requestDetail.method")

        // Middle truncation keeps the route's head and its last segment; the tooltip has it all.
        Text(log.path)
            .font(DSTypography.codeLarge)
            .foregroundStyle(DSColors.labelPrimary)
            .lineLimit(1)
            .truncationMode(.middle)
            .textSelection(.enabled)
            .help(log.path)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("requestDetail.path")
    }

    @ViewBuilder
    private var requestActions: some View {
        if let copyConfirmation {
            Label(copyConfirmation, systemImage: "checkmark.circle.fill")
                .font(DSTypography.caption)
                .foregroundStyle(DSColors.success)
                .labelStyle(.titleAndIcon)
                .fixedSize()
                .transition(.opacity)
                .accessibilityIdentifier("requestDetail.copyConfirmation")
        }

        DSButton("Copy as cURL", variant: .secondary, size: .medium, identifier: "requestDetail.copy.curl") {
            copy(RequestLogExport.curl(for: log, port: context.port), confirmation: "Copied cURL")
        }
        .fixedSize()
        .disabled(RequestLogExport.curlUnavailability(for: log) != nil)
        .help(curlHelp)
        // Applied outside, so it wins over the `ds.button.…` name the suite does not use. The
        // label carries the tooltip, so a disabled button still says why.
        .accessibilityIdentifier("requestDetail.copy.curl")
        .accessibilityLabel(curlHelp)

        nextAction

        if let onClose {
            DSIconButton("Close request", systemImage: "xmark", identifier: "requestDetail.close", action: onClose)
        }
    }

    private var curlHelp: String {
        if let issue = RequestLogExport.curlUnavailability(for: log) { return "Copy as a curl command. \(issue)" }
        return context.port == nil
            ? "Copy as a curl command. The server is stopped, so the URL has no port."
            : "Copy as a curl command"
    }

    /// Create an endpoint for a call nothing answered, keep a real response as a mock, or open the
    /// endpoint that answered.
    @ViewBuilder
    private var nextAction: some View {
        if log.outcome.isMissingConfiguration, let onCreateEndpoint {
            let path = RequestLogQuery.mockablePath(from: log.path)
            DSButton("Create endpoint", systemImage: "plus", variant: .primary, size: .medium,
                     identifier: "requestDetail.createEndpoint") {
                onCreateEndpoint(log.method, path)
            }
            .fixedSize()
            .help("Create an endpoint for \(log.method.rawValue) \(path)")
            .accessibilityIdentifier("requestDetail.createEndpoint")
            .accessibilityLabel("Create endpoint")
        } else if log.outcome == .passthrough, let onSaveAsMock {
            DSButton("Save response as mock", systemImage: "square.and.arrow.down", variant: .primary,
                     size: .medium, identifier: "requestDetail.saveMock") {
                onSaveAsMock(log.id)
            }
            .fixedSize()
            .disabled(captureIssue != nil)
            .help("Saves the response body and safe headers in this project. Review private data before sharing.")
            .accessibilityIdentifier("requestDetail.saveMock")
            .accessibilityLabel("Save response as mock")
        } else if log.outcome == .endpoint, context.endpointExists,
                  let endpointID = log.matchedEndpointID, let onGoToEndpoint {
            DSButton("Go to endpoint", variant: .secondary, size: .medium, identifier: "requestDetail.goToEndpoint") {
                onGoToEndpoint(endpointID)
            }
            .fixedSize()
            .help("Open \(context.endpointName ?? "the endpoint that answered") in the editor")
            .accessibilityIdentifier("requestDetail.goToEndpoint")
            .accessibilityLabel("Go to endpoint")
        }
    }

    /// The status and what produced it, then duration, size and arrival time.
    ///
    /// On one line while the whole sentence fits beside the status and the timing. When it does not,
    /// the sentence takes its own full-width line under them and wraps, rather than being squeezed
    /// to a letter; in the narrowest column the timing moves under the status too.
    private var statusLine: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: Self.blockSpacing) {
                statusLabel
                outcomeText.fixedSize()
                Spacer(minLength: DSSpacing.sm)
                timingText
            }
            VStack(alignment: .leading, spacing: DSSpacing.xs) {
                HStack(alignment: .firstTextBaseline, spacing: Self.blockSpacing) {
                    statusLabel
                    Spacer(minLength: DSSpacing.sm)
                    timingText
                }
                wrappingOutcomeText
            }
            VStack(alignment: .leading, spacing: DSSpacing.xs) {
                statusLabel
                timingText
                wrappingOutcomeText
            }
        }
    }

    private var outcomeText: some View {
        Text(outcomeExplanation)
            .font(DSTypography.callout)
            .foregroundStyle(outcomeExplanationColor)
            .accessibilityIdentifier("requestDetail.outcome")
    }

    /// The sentence on a line of its own, wrapping to the column. No ideal width, so `ViewThatFits`
    /// judges the arrangement by the status and timing alone.
    private var wrappingOutcomeText: some View {
        outcomeText
            .fixedSize(horizontal: false, vertical: true)
            .frame(minWidth: 0, idealWidth: 0, maxWidth: .infinity, alignment: .leading)
    }

    private var timingText: some View {
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
        .fixedSize()
    }

    /// Dot, code and reason phrase; a failed exchange shows its failure in the error colour.
    @ViewBuilder
    private var statusLabel: some View {
        if let failureLabel = log.failureLabel {
            DSStatusLabel(statusCode: nil, reason: failureLabel)
                .accessibilityIdentifier("requestDetail.failure")
        } else if let code = log.responseStatusCode {
            DSStatusLabel(statusCode: code, reason: HTTPStatusText.reasonPhrase(for: code))
                .accessibilityIdentifier("requestDetail.status")
        } else {
            DSStatusLabel(statusCode: nil)
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

    /// One sentence saying what answered.
    private var outcomeExplanation: String {
        Self.outcomeExplanation(for: log, endpointName: context.endpointName, scenarioName: context.scenarioName)
    }

    nonisolated static func outcomeExplanation(for log: RequestLog, endpointName: String?, scenarioName: String?) -> String {
        switch log.outcome {
        case .endpoint:
            if let endpointName, let scenarioName { return "Answered by \(endpointName), \(scenarioName)" }
            return endpointName.map { "Answered by \($0)" } ?? "Answered by an endpoint"
        case .journey: return "Answered by the active journey"
        case .unmatched:
            return log.responseStatusCode.map { "No endpoint matched, so Mimic returned \($0)" }
                ?? "No endpoint matched"
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

    private var outcomeColor: Color {
        switch log.outcome {
        case .endpoint: DSColors.labelPrimary
        case .journey: DSColors.accent
        case .unmatched, .blockedByJourney: DSColors.warning
        case .proxyFailure: DSColors.error
        case .passthrough: DSColors.success
        }
    }

    // MARK: - Request

    /// Where the request arrived, its query, its headers and its body.
    @ViewBuilder
    private var requestContent: some View {
        VStack(alignment: .leading, spacing: DSSpacing.xs) {
            sectionTitle("Summary", identifier: "requestDetail.request.summary")
            summaryRow("URL", value: Self.requestURL(for: log, port: context.port))
            if let portSummary = Self.portSummary(for: log) { summaryRow("Port", value: portSummary) }
        }

        let query = Self.queryItems(in: log.path)
        if !query.isEmpty {
            DSDivider(identifier: "requestDetail.query")
            VStack(alignment: .leading, spacing: 0) {
                sectionTitle("Query", identifier: "requestDetail.query")
                ForEach(Array(query.enumerated()), id: \.offset) { index, item in
                    pairRow(name: item.name, value: item.value, identifier: "requestDetail.query.\(index)")
                }
            }
        }

        DSDivider(identifier: "requestDetail.headers.request")
        headerSection(identifier: "request", headers: log.requestHeaders, emptyMessage: "No headers")

        DSDivider(identifier: "requestDetail.body.request")
        VStack(alignment: .leading, spacing: DSSpacing.xs + 2) {
            sectionTitle("Body", identifier: "requestDetail.body.request")
            if let requestBody = log.requestBody, !requestBody.isEmpty {
                RequestBodyView(payload: requestBody, identifier: "request")
            } else {
                emptyNote("No body", identifier: "requestDetail.body.request.empty")
            }
            if log.requestBodyTruncated == true {
                truncationNote(identifier: "request")
            }
        }
    }

    // MARK: - Response

    /// What answered, then the response's headers and body.
    @ViewBuilder
    private var responseContent: some View {
        VStack(alignment: .leading, spacing: DSSpacing.xs) {
            sectionTitle("Answered by", identifier: "requestDetail.answeredBy")
            summaryRow("Outcome", value: log.outcome.label, valueColor: outcomeColor)
            if let name = log.backendName { summaryRow("Backend", value: name) }
            if let upstream = log.upstreamURL { summaryRow("Forwarded to", value: upstream) }
            summaryRow("Endpoint", value: context.endpointName ?? "\u{2014}")
            summaryRow("Scenario", value: context.scenarioName ?? "\u{2014}",
                       valueColor: context.scenarioName != nil ? DSColors.accent : DSColors.labelSecondary)

            if log.outcome.isMissingConfiguration {
                Text("Nothing was configured for this call, so Mimic answered with its fallback. Create an endpoint to mock it.")
                    .font(DSTypography.callout)
                    .foregroundStyle(DSColors.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, DSSpacing.xs)
                    .accessibilityIdentifier("requestDetail.unmatchedHint")
            }
            if log.outcome == .passthrough, onSaveAsMock != nil, let captureIssue {
                Text(captureIssue)
                    .font(DSTypography.callout)
                    .foregroundStyle(DSColors.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, DSSpacing.xs)
                    .accessibilityIdentifier("requestDetail.captureIssue")
            }
        }

        DSDivider(identifier: "requestDetail.headers.response")
        headerSection(
            identifier: "response",
            headers: log.responseHeaders,
            emptyMessage: log.failureLabel.map { "No response. The connection was \($0)." } ?? "No headers"
        )

        DSDivider(identifier: "requestDetail.body.response")
        VStack(alignment: .leading, spacing: DSSpacing.xs + 2) {
            sectionTitle("Body", identifier: "requestDetail.body.response")
            if log.responseBodyIsBinary == true {
                emptyNote("Binary or non-UTF-8 response body is not previewed",
                          identifier: "requestDetail.body.response.empty")
            } else if let responseBody = log.responseBody, !responseBody.isEmpty {
                RequestBodyView(payload: responseBody, identifier: "response")
                if log.responseBodyTruncated {
                    truncationNote(identifier: "response")
                }
            } else {
                emptyNote(
                    log.failureLabel.map { "No response. The connection was \($0)." } ?? "No body",
                    identifier: "requestDetail.body.response.empty"
                )
            }
        }
    }

    // MARK: - Timing

    /// When the request arrived, how long the answer took, and how much each half carried.
    @ViewBuilder
    private var timingContent: some View {
        VStack(alignment: .leading, spacing: DSSpacing.xs) {
            sectionTitle("Timing", identifier: "requestDetail.timing")
            summaryRow("Received", value: Self.receivedText(for: log.timestamp))
            summaryRow("Duration", value: log.durationMs.map(RequestLogQuery.formattedDuration) ?? "\u{2014}")
        }

        DSDivider(identifier: "requestDetail.sizes")
        VStack(alignment: .leading, spacing: DSSpacing.xs) {
            sectionTitle("Sizes", identifier: "requestDetail.sizes")
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
        }
    }

    // MARK: - Rows

    /// A small muted section title, optionally with a count beside it ("Headers 6").
    private func sectionTitle(_ title: String, count: Int? = nil, identifier: String) -> some View {
        HStack(spacing: DSSpacing.xs + 2) {
            Text(title)
                .font(DSTypography.captionSemibold)
                .foregroundStyle(DSColors.labelTertiary)
            if let count {
                Text("\(count)")
                    .font(DSTypography.caption)
                    .monospacedDigit()
                    .foregroundStyle(DSColors.labelTertiary)
            }
        }
        .padding(.bottom, DSSpacing.xs)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("ds.sectionheader.\(identifier)")
    }

    /// A Summary, Answered by or Timing fact: a label in the text face, its value in the code face.
    /// Every tab's rows share the identifier scheme `requestDetail.summary.<label>`.
    private func summaryRow(_ label: String, value: String, valueColor: Color = DSColors.labelPrimary) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DSSpacing.md) {
            Text(label)
                .font(DSTypography.callout)
                .foregroundStyle(DSColors.labelSecondary)
                .lineLimit(1)
                .frame(width: Self.summaryKeyWidth, alignment: .leading)
            Text(value)
                .font(DSTypography.code)
                .foregroundStyle(valueColor)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: DSRowHeight.groupHeader)
        .accessibilityRepresentation {
            Text("\(label): \(value)")
                .accessibilityIdentifier("requestDetail.summary.\(label.lowercased())")
        }
    }

    /// A header or query item: the name in one column, the value in the next.
    private func pairRow(name: String, value: String?, identifier: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(name)
                .foregroundStyle(DSColors.labelSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(name)
                .frame(width: Self.pairNameWidth, alignment: .leading)
            Text(value ?? "")
                .foregroundStyle(DSColors.labelPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(DSTypography.code)
        .padding(.vertical, DSSpacing.xxs)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(identifier)
    }

    @ViewBuilder
    private func headerSection(identifier: String, headers: [String: String], emptyMessage: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionTitle("Headers", count: headers.isEmpty ? nil : headers.count,
                         identifier: "requestDetail.headers.\(identifier)")
            if headers.isEmpty {
                emptyNote(emptyMessage, identifier: "requestDetail.headers.\(identifier).empty")
            } else {
                ForEach(headers.sorted(by: { $0.key < $1.key }), id: \.key) { header in
                    // Keyed by the header's name, so the row keeps its identity when the sort moves it.
                    pairRow(name: header.key, value: header.value,
                            identifier: "requestDetail.headers.\(identifier).\(header.key)")
                }
            }
        }
    }

    private func emptyNote(_ message: String, identifier: String) -> some View {
        Text(message)
            .font(DSTypography.callout)
            .foregroundStyle(DSColors.labelTertiary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier(identifier)
    }

    private func truncationNote(identifier: String) -> some View {
        Text("Truncated at \(RequestLog.maxLoggedBodyBytes / 1024) KB.")
            .font(DSTypography.callout)
            .foregroundStyle(DSColors.labelSecondary)
            .accessibilityIdentifier("requestDetail.body.\(identifier).truncated")
    }

    // MARK: - Copying

    private func copy(_ text: String, confirmation: String) {
        Self.write(text, to: .general)

        copyConfirmationTask?.cancel()
        withAnimation(reduceMotion ? nil : Animation.easeOut(duration: DSAnimation.fast)) {
            copyConfirmation = confirmation
        }
        copyConfirmationTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            withAnimation(reduceMotion ? nil : Animation.easeOut(duration: DSAnimation.fast)) {
                copyConfirmation = nil
            }
        }
    }

    // MARK: - Testable seams

    static func write(_ text: String, to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// The address the client called: the listener's port when the log recorded one, otherwise the
    /// server's current port, otherwise the path alone rather than a guessed port.
    nonisolated static func requestURL(for log: RequestLog, port: Int?) -> String {
        guard let resolved = log.listenerPort ?? port else { return log.path }
        return "http://localhost:\(resolved)\(log.path)"
    }

    /// "Storefront · 18086": the listener that received the request, as the settings sheet names it.
    nonisolated static func portSummary(for log: RequestLog) -> String? {
        let parts = [log.backendName, log.listenerPort.map { String($0) }].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " \u{00B7} ")
    }

    /// The query string's items in the order they were sent, duplicates kept.
    ///
    /// Split by hand rather than through `URLComponents`, which refuses a whole target over one
    /// character it considers illegal — `item[0]=one` is a query clients really send, and the log
    /// stores the target exactly as it arrived.
    nonisolated static func queryItems(in path: String) -> [URLQueryItem] {
        guard let start = path.firstIndex(of: "?") else { return [] }
        var query = path[path.index(after: start)...]
        if let fragment = query.firstIndex(of: "#") { query = query[..<fragment] }
        return query.split(separator: "&", omittingEmptySubsequences: true).map { pair in
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let decode = { (text: Substring) in String(text).removingPercentEncoding ?? String(text) }
            return URLQueryItem(name: decode(parts[0]), value: parts.count > 1 ? decode(parts[1]) : nil)
        }
    }

    /// The arrival time to the millisecond, with its date, for the Timing tab.
    nonisolated static func receivedText(for date: Date) -> String {
        date.formatted(.dateTime.year().month(.abbreviated).day()) + ", "
            + date.formatted(RequestLogQuery.timestampFormat)
    }

    /// A body's size in the units a person reads, or a dash when there is no body.
    nonisolated static func byteSummary(_ body: String?) -> String {
        guard let body, !body.isEmpty else { return "\u{2014}" }
        let bytes = body.utf8.count
        if bytes < 1024 { return "\(bytes) B" }
        return String(format: "%.1f KB", Double(bytes) / 1024)
    }
}

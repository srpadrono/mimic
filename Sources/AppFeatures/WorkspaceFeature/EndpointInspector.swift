import SwiftUI
import Domain
import DesignSystem

/// The inspector's "Endpoint" section: where an endpoint lives and how it is served.
struct EndpointInspectorSettings: View {
    struct Context {
        var editedScenarioID: UUID?
        var onEditScenario: (_ endpointID: UUID, _ scenarioID: UUID) -> Void
        var globalDelayMs: Int
        var backends: [BackendConfiguration]
        var groups: [String]
        var onUpdateGroupTag: (_ endpointID: UUID, _ groupTag: String?) -> Void
        var onUpdateBackend: (_ endpointID: UUID, _ backendID: UUID?) -> Void
    }

    let endpoint: Endpoint
    let context: Context

    @State private var groupTag = ""
    @FocusState private var isGroupFocused: Bool

    private var backend: BackendConfiguration? {
        context.backends.first { $0.id == (endpoint.backendID ?? ServerConfiguration.primaryID) }
            ?? context.backends.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DSInspectorSectionHeader("Endpoint", identifier: "inspector.endpoint")

            row("Group") {
                HStack(spacing: DSSpacing.xs) {
                    TextField("None", text: $groupTag)
                        .textFieldStyle(.plain)
                        .font(DSTypography.callout)
                        .focused($isGroupFocused)
                        .onSubmit(commitGroup)
                        .onChange(of: isGroupFocused) { _, focused in
                            if !focused { commitGroup() }
                        }
                        .accessibilityIdentifier("endpointEditor.groupTag")
                        .accessibilityLabel("Group tag")
                    if !context.groups.isEmpty {
                        Menu {
                            ForEach(context.groups, id: \.self) { group in
                                Button(group) {
                                    groupTag = group
                                    commitGroup()
                                }
                            }
                            Divider()
                            Button("No group") {
                                groupTag = ""
                                commitGroup()
                            }
                        } label: {
                            Image(systemName: "chevron.down")
                                .font(.system(size: DSGlyph.disclosure - 1, weight: .semibold))
                                .foregroundStyle(DSColors.labelTertiary)
                                .frame(width: 14, height: DSControlHeight.regular)
                                .contentShape(Rectangle())
                        }
                        .menuStyle(.button)
                        .buttonStyle(.plain)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .help("Choose an existing group")
                        .accessibilityIdentifier("inspector.groupMenu")
                        .accessibilityLabel("Existing groups")
                    }
                }
                .dsFieldChrome(isFocused: isGroupFocused)
            }

            row("Base delay") {
                HStack(spacing: DSSpacing.xs) {
                    Text("\(context.globalDelayMs)")
                        .font(DSTypography.Figure.regular)
                        .foregroundStyle(DSColors.labelSecondary)
                        .accessibilityIdentifier("endpointEditor.globalDelay")
                        .accessibilityLabel("Global delay in milliseconds")
                        .accessibilityValue("\(context.globalDelayMs)")
                    Spacer(minLength: 0)
                    Text("ms")
                        .font(DSTypography.callout)
                        .foregroundStyle(DSColors.labelTertiary)
                        .accessibilityHidden(true)
                }
                .dsFieldChrome(isFocused: false)
                .help("Set in server settings. It is added to every endpoint's delay.")
            }
            Text("Project delay is added to this endpoint's delay.")
                .font(DSTypography.caption)
                .foregroundStyle(DSColors.labelTertiary)
                .padding(.leading, DSInspectorMetrics.inset + DSInspectorMetrics.labelColumn + DSSpacing.md)
                .padding(.trailing, DSInspectorMetrics.inset)
                .padding(.bottom, DSSpacing.xs)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("endpointEditor.globalDelay.note")

            row("Port") {
                Menu {
                    ForEach(context.backends) { option in
                        Button("\(option.name) · \(String(option.port))") {
                            context.onUpdateBackend(endpoint.id,
                                                    option.id == ServerConfiguration.primaryID ? nil : option.id)
                        }
                    }
                } label: {
                    HStack(spacing: DSSpacing.xs) {
                        Text(backend.map { "\($0.name) · \(String($0.port))" } ?? "Primary")
                            .font(DSTypography.callout)
                            .foregroundStyle(DSColors.labelPrimary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.down")
                            .font(.system(size: DSGlyph.disclosure - 1, weight: .semibold))
                            .foregroundStyle(DSColors.labelTertiary)
                    }
                    .dsFieldChrome(isFocused: false)
                    .contentShape(Rectangle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .disabled(context.backends.count < 2)
                .accessibilityIdentifier("endpointEditor.backend")
                .accessibilityLabel("Backend")
            }

            row("When unmatched") {
                Text(backend?.effectiveUpstream != nil ? "Forward to upstream" : "Return 404")
                    .font(DSTypography.callout)
                    .foregroundStyle(DSColors.labelSecondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(backend?.effectiveUpstream.map { "Unmatched requests go to \($0)" }
                          ?? "Unmatched requests get a 404. Set an upstream in server settings to forward them.")
                    .accessibilityIdentifier("inspector.unmatchedBehavior")
            }
        }
        .onAppear { groupTag = endpoint.groupTag ?? "" }
        .onChange(of: endpoint.id) { groupTag = endpoint.groupTag ?? "" }
        .onChange(of: endpoint.groupTag) { _, value in
            if !isGroupFocused { groupTag = value ?? "" }
        }
    }

    private func commitGroup() {
        let trimmed = groupTag.trimmingCharacters(in: .whitespaces)
        let value: String? = trimmed.isEmpty ? nil : trimmed
        guard value != endpoint.groupTag else { return }
        context.onUpdateGroupTag(endpoint.id, value)
    }

    private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: DSSpacing.md) {
            // The design's 88pt column holds "When unmatched" at 12pt only just; tighten and, as a
            // last resort, scale a little rather than cut the label to "When unmatc…".
            Text(label)
                .font(DSTypography.callout)
                .foregroundStyle(DSColors.labelSecondary)
                .lineLimit(1)
                .allowsTightening(true)
                .minimumScaleFactor(0.85)
                .frame(width: DSInspectorMetrics.labelColumn, alignment: .leading)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, DSInspectorMetrics.inset)
        .frame(height: DSRowHeight.list)
    }
}

/// The inspector's "Traffic" section: a small chart of the last fifteen minutes and three figures.
struct EndpointTrafficSummary: View {
    let logs: [RequestLog]
    var onSelect: (UUID) -> Void = { _ in }

    nonisolated struct Bucket: Equatable {
        var served: Int
        var errors: Int
    }

    nonisolated static let bucketCount = 15

    /// One bucket per minute, oldest first.
    nonisolated static func buckets(for logs: [RequestLog], now: Date) -> [Bucket] {
        var buckets = Array(repeating: Bucket(served: 0, errors: 0), count: bucketCount)
        for log in logs {
            let minutesAgo = Int(now.timeIntervalSince(log.timestamp) / 60)
            guard minutesAgo >= 0, minutesAgo < bucketCount else { continue }
            let index = bucketCount - 1 - minutesAgo
            if isError(log) { buckets[index].errors += 1 } else { buckets[index].served += 1 }
        }
        return buckets
    }

    nonisolated static func isError(_ log: RequestLog) -> Bool {
        guard let status = log.responseStatusCode else { return true }
        return status >= 500
    }

    nonisolated static func medianDuration(of logs: [RequestLog]) -> Int? {
        let durations = logs.compactMap(\.durationMs).sorted()
        guard !durations.isEmpty else { return nil }
        return durations[durations.count / 2]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Traffic")
                    .font(DSTypography.bodySemibold)
                    .foregroundStyle(DSColors.labelPrimary)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Text("Last 15 minutes")
                    .font(DSTypography.caption)
                    .foregroundStyle(DSColors.labelTertiary)
            }

            if logs.isEmpty {
                Text("No requests yet")
                    .font(DSTypography.callout)
                    .foregroundStyle(DSColors.labelTertiary)
                    .accessibilityIdentifier("inspector.traffic.empty")
            } else {
                TimelineView(.periodic(from: .now, by: 30)) { timeline in
                    chart(Self.buckets(for: logs, now: timeline.date))
                }
                HStack(spacing: DSSpacing.lg) {
                    figure("\(logs.filter { !Self.isError($0) }.count)", caption: "served",
                           identifier: "inspector.traffic.served")
                    figure("\(logs.filter(Self.isError).count)", caption: "errors",
                           color: logs.contains(where: Self.isError) ? DSColors.error : DSColors.labelPrimary,
                           identifier: "inspector.traffic.errors")
                    figure(Self.medianDuration(of: logs).map { "\($0) ms" } ?? "—", caption: "median",
                           identifier: "inspector.traffic.median")
                }
                if let latest = logs.max(by: { $0.timestamp < $1.timestamp }) {
                    DSButton("Show latest request", variant: .ghost, size: .small,
                             identifier: "inspector.traffic.latest") { onSelect(latest.id) }
                        .padding(.leading, -DSSpacing.sm)
                }
            }
        }
        .padding(.horizontal, DSInspectorMetrics.inset)
        .padding(.top, DSSpacing.lg)
        .overlay(alignment: .top) {
            Rectangle().fill(DSColors.separator).frame(height: DSStroke.hairline)
                .padding(.horizontal, DSInspectorMetrics.inset)
        }
        .padding(.top, DSSpacing.lg)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("inspector.traffic")
    }

    private func chart(_ buckets: [Bucket]) -> some View {
        let peak = max(1, buckets.map { $0.served + $0.errors }.max() ?? 1)
        return HStack(alignment: .bottom, spacing: 3) {
            ForEach(Array(buckets.enumerated()), id: \.offset) { _, bucket in
                let total = bucket.served + bucket.errors
                RoundedRectangle(cornerRadius: 2)
                    .fill(bucket.errors > bucket.served ? DSColors.error.opacity(0.85) : DSColors.success.opacity(0.7))
                    .frame(height: total == 0 ? 2 : max(3, 44 * CGFloat(total) / CGFloat(peak)))
                    .opacity(total == 0 ? 0.35 : 1)
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 44, alignment: .bottom)
        .accessibilityHidden(true)
    }

    private func figure(_ value: String, caption: String, color: Color = DSColors.labelPrimary,
                        identifier: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value)
                .font(DSTypography.Figure.large)
                .foregroundStyle(color)
            Text(caption)
                .font(DSTypography.caption)
                .foregroundStyle(DSColors.labelSecondary)
        }
        // One element that reads "2 served". `.combine` on macOS left the label empty and put
        // "2, served" in the value, so the figure announced no name of its own.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(value) \(caption)")
        .accessibilityIdentifier(identifier)
    }
}

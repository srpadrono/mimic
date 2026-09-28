import SwiftUI

// Guarded so previews do not ship.
//
// `#Preview` expands to a `PreviewRegistry` conformance, which is compiled into whatever
// configuration builds the file, so ungated previews would ship in the Release binary. Every
// `#Preview` in this project sits inside `#if DEBUG`.
#if DEBUG
// MARK: - DSButton

#Preview("DSButton — Variants") {
    VStack(spacing: DSSpacing.md) {
        DSButton("Primary action", variant: .primary, identifier: "preview.primary") {}
        DSButton("Secondary action", variant: .secondary, identifier: "preview.secondary") {}
        DSButton("Delete", variant: .destructive, identifier: "preview.destructive") {}
        DSButton("Ghost action", variant: .ghost, identifier: "preview.ghost") {}
    }
    .padding()
}

#Preview("DSButton — Sizes") {
    VStack(spacing: DSSpacing.md) {
        DSButton("Small", variant: .primary, size: .small, identifier: "preview.small") {}
        DSButton("Medium", variant: .primary, size: .medium, identifier: "preview.medium") {}
        DSButton("Large", variant: .primary, size: .large, identifier: "preview.large") {}
    }
    .padding()
}

// MARK: - DSTextField

#Preview("DSTextField — States") {
    @Previewable @State var normal = ""
    @Previewable @State var withError = "bad value"

    VStack(spacing: DSSpacing.md) {
        DSTextField("Project name", text: $normal, placeholder: "My API Mock", identifier: "preview.name")
        DSTextField("Port", text: $withError, validation: "Port must be between 1024 and 65535", identifier: "preview.port")
    }
    .padding()
    .frame(width: 300)
}

// MARK: - DSMethodLabel and DSStatusLabel

#Preview("DSMethodLabel") {
    VStack(alignment: .leading, spacing: DSSpacing.xs) {
        ForEach(["GET", "POST", "PUT", "PATCH", "DELETE"], id: \.self) { method in
            DSMethodLabel(method, identifier: "preview.\(method.lowercased())")
        }
    }
    .padding()
}

#Preview("DSStatusLabel") {
    VStack(alignment: .leading, spacing: DSSpacing.xs) {
        DSStatusLabel(statusCode: 200)
        DSStatusLabel(statusCode: 302)
        DSStatusLabel(statusCode: 404, reason: "Not Found")
        DSStatusLabel(statusCode: 503)
        DSStatusLabel(statusCode: nil, reason: "timeout 30000ms")
        DSStatusLabel("Running", color: DSColors.success)
    }
    .padding()
}

// MARK: - DSSegmentedControl

#Preview("DSSegmentedControl") {
    @Previewable @State var selection = "all"

    DSSegmentedControl(
        "Show",
        segments: [
            DSSegmentedControl<String>.Segment("All", value: "all", identifier: "preview.all"),
            DSSegmentedControl<String>.Segment("Unmatched", value: "unmatched", count: 3, countColor: DSColors.warning,
                  identifier: "preview.unmatched"),
        ],
        selection: $selection,
        identifier: "preview.segments"
    )
    .padding()
}

// MARK: - DSBanner

#Preview("DSBanner — Kinds") {
    VStack(spacing: DSSpacing.sm) {
        DSBanner(.info, message: "The server restarts when you change its port.", identifier: "preview.info")
        DSBanner(.warning, message: "Two endpoints answer the same route.", actionTitle: "Show",
                 identifier: "preview.warning") {}
        DSBanner(.error, message: "Port 8080 is already in use.", identifier: "preview.error")
    }
    .padding()
    .frame(width: 420)
}

// MARK: - DSEmptyState

#Preview("DSEmptyState — With Icon") {
    DSEmptyState(
        systemImage: "list.bullet.indent",
        heading: "No endpoints",
        message: "Add an endpoint to define a mock route, or import a HAR file or an OpenAPI spec.",
        actionTitle: "Add endpoint",
        identifier: "preview.endpoints"
    ) {}
}

#Preview("DSEmptyState — Without Icon") {
    DSEmptyState(
        heading: "No selection",
        message: "Select an endpoint to view its details.",
        identifier: "preview.noSelection"
    )
}

// MARK: - DSSectionHeader

#Preview("DSSectionHeader") {
    VStack(spacing: 0) {
        DSSectionHeader("Endpoints", identifier: "preview.endpoints") {
            Button(action: {}) {
                Image(systemName: "plus")
            }
            .buttonStyle(.plain)
        }
        DSDivider()
        DSSectionHeader("Recent projects", identifier: "preview.recent")
    }
    .frame(width: 300)
}

// MARK: - DSCodeBlock

#Preview("DSCodeBlock") {
    VStack(spacing: DSSpacing.md) {
        DSCodeBlock("http://localhost:8080", identifier: "preview.url")
        DSCodeBlock("""
        {
          "id": 1,
          "name": "Test User",
          "email": "test@example.com"
        }
        """, identifier: "preview.json")
    }
    .padding()
    .frame(width: 400)
}

// MARK: - DSPanelHeader

#Preview("DSPanelHeader") {
    VStack(spacing: 0) {
        DSPanelHeader("Requests", subtitle: "12 requests", identifier: "preview.requests") {
            DSPanelHeaderButton(systemImage: "trash", help: "Clear log", identifier: "preview.clear") {}
        }
        DSPanelHeader("Scenarios", subtitle: "/api/users/{id}", identifier: "preview.scenarios")
        Spacer()
    }
    .frame(width: 360, height: 160)
    .background(DSColors.content)
}

// MARK: - DSSplitPane

#Preview("DSSplitPane — Vertical") {
    @Previewable @State var showSecondary = true
    @Previewable @State var secondaryHeight: CGFloat = 140

    DSSplitPane(
        axis: .vertical,
        isSecondaryPresented: $showSecondary,
        secondaryThickness: $secondaryHeight,
        minimumPrimaryThickness: 120,
        minimumSecondaryThickness: 80,
        defaultSecondaryThickness: 140,
        identifier: "preview.split"
    ) {
        VStack {
            Text("Primary pane")
                .font(DSTypography.body)
            Button(showSecondary ? "Hide secondary" : "Show secondary") {
                showSecondary.toggle()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    } secondary: {
        Text("Secondary pane — drag the divider, or drag it shut")
            .font(DSTypography.body)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(DSColors.window)
    }
    .frame(width: 600, height: 400)
}

// MARK: - DSDivider

#Preview("DSDivider") {
    VStack(spacing: DSSpacing.md) {
        Text("Above").font(DSTypography.body)
        DSDivider()
        HStack(spacing: DSSpacing.md) {
            Text("Leading").font(DSTypography.body)
            DSDivider(axis: .vertical)
            Text("Trailing").font(DSTypography.body)
        }
        .frame(height: DSRowHeight.list)
    }
    .padding()
    .frame(width: 200)
}

// MARK: - DSHoverHighlight

#Preview("DSHoverHighlight") {
    VStack(spacing: DSSpacing.sm) {
        Text("Hover over these rows")
            .font(DSTypography.body)
            .foregroundStyle(DSColors.labelSecondary)

        ForEach(0..<3) { i in
            HStack {
                Text("Row \(i + 1)")
                    .font(DSTypography.body)
                Spacer()
            }
            .padding(DSSpacing.sm)
            .dsHoverHighlight()
        }
    }
    .padding()
    .frame(width: 240)
}

// MARK: - DSLoadingPlaceholder

#Preview("DSLoadingPlaceholder") {
    DSLoadingPlaceholder(identifier: "preview")
        .frame(width: 400, height: 200)
}
#endif

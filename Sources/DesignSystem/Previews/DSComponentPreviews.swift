import SwiftUI

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

// MARK: - DSStatusBadge

#Preview("DSStatusBadge — States") {
    HStack(spacing: DSSpacing.md) {
        DSStatusBadge(state: .idle)
        DSStatusBadge(state: .running)
        DSStatusBadge(state: .stopped)
        DSStatusBadge(state: .error)
    }
    .padding()
}

// MARK: - DSMethodBadge

#Preview("DSMethodBadge — Standard") {
    HStack(spacing: DSSpacing.sm) {
        DSMethodBadge(method: "GET")
        DSMethodBadge(method: "POST")
        DSMethodBadge(method: "PUT")
        DSMethodBadge(method: "PATCH")
        DSMethodBadge(method: "DELETE")
    }
    .padding()
}

#Preview("DSMethodBadge — Compact") {
    HStack(spacing: DSSpacing.sm) {
        DSMethodBadge(method: "GET", size: .compact)
        DSMethodBadge(method: "POST", size: .compact)
        DSMethodBadge(method: "PUT", size: .compact)
        DSMethodBadge(method: "PATCH", size: .compact)
        DSMethodBadge(method: "DELETE", size: .compact)
    }
    .padding()
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

// MARK: - DSDrawer

#Preview("DSDrawer — Edges") {
    @Previewable @State var showRight = true
    @Previewable @State var showBottom = true

    VStack(spacing: 0) {
        HStack(spacing: 0) {
            VStack {
                Text("Main content")
                    .font(DSTypography.body)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                HStack(spacing: DSSpacing.md) {
                    Button(showRight ? "Hide right" : "Show right") {
                        withAnimation(DSAnimation.drawerToggle) { showRight.toggle() }
                    }
                    Button(showBottom ? "Hide bottom" : "Show bottom") {
                        withAnimation(DSAnimation.drawerToggle) { showBottom.toggle() }
                    }
                }
                .padding(.bottom, DSSpacing.md)
            }

            DSDrawer(edge: .trailing, isPresented: $showRight, identifier: "preview.right") {
                Text("Right drawer")
                    .font(DSTypography.body)
                    .frame(width: 180)
                    .frame(maxHeight: .infinity)
                    .background(DSColors.secondary)
            }
        }

        DSDrawer(edge: .bottom, isPresented: $showBottom, identifier: "preview.bottom") {
            Text("Bottom drawer")
                .font(DSTypography.body)
                .frame(maxWidth: .infinity)
                .frame(height: 120)
                .background(DSColors.secondary)
        }
    }
    .frame(width: 600, height: 400)
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
            .background(DSColors.secondary)
    }
    .frame(width: 600, height: 400)
}

// MARK: - DSDivider

#Preview("DSDivider — Styles") {
    VStack(spacing: DSSpacing.md) {
        Text("Subtle").font(DSTypography.label)
        DSDivider(style: .subtle)
        Text("Standard").font(DSTypography.label)
        DSDivider(style: .standard)
        Text("Strong").font(DSTypography.label)
        DSDivider(style: .strong)
    }
    .padding()
    .frame(width: 200)
}

// MARK: - DSHoverHighlight

#Preview("DSHoverHighlight") {
    VStack(spacing: DSSpacing.sm) {
        Text("Hover over these rows")
            .font(DSTypography.label)
            .foregroundStyle(.secondary)

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

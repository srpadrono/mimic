import SwiftUI

// Preview scaffolding is excluded from release builds.
#if DEBUG
#Preview("Spacing Scale") {
    VStack(alignment: .leading, spacing: DSSpacing.sm) {
        spacingRow("xxs", DSSpacing.xxs)
        spacingRow("xs", DSSpacing.xs)
        spacingRow("sm", DSSpacing.sm)
        spacingRow("md", DSSpacing.md)
        spacingRow("lg", DSSpacing.lg)
        spacingRow("xl", DSSpacing.xl)
        spacingRow("2xl", DSSpacing.xxl)
        spacingRow("3xl", DSSpacing.xxxl)
    }
    .padding()
}

#Preview("Typography") {
    VStack(alignment: .leading, spacing: DSSpacing.md) {
        Text("Large title (26pt bold)").font(DSTypography.largeTitle)
        Text("Title (20pt semibold)").font(DSTypography.title)
        Text("Headline (15pt semibold)").font(DSTypography.headline)
        Text("Body semibold (13pt)").font(DSTypography.bodySemibold)
        Text("Body medium (13pt)").font(DSTypography.bodyMedium)
        Text("Body (13pt)").font(DSTypography.body)
        Text("Callout medium (12pt)").font(DSTypography.calloutMedium)
        Text("Callout (12pt)").font(DSTypography.callout)
        Text("Caption semibold (11pt)").font(DSTypography.captionSemibold)
        Text("Caption (11pt)").font(DSTypography.caption)
        Divider()
        Text("Code large (SF Mono 13pt)").font(DSTypography.codeLarge)
        Text("Code (SF Mono 12pt)").font(DSTypography.code)
        Text("GET (method, SF Mono 11pt semibold)").font(DSTypography.method)
        Text("200 (status, SF Mono 12pt medium)").font(DSTypography.status)
        Text("1,024 (figure)").font(DSTypography.Figure.regular)
        Text("38 ms (large figure)").font(DSTypography.Figure.large)
    }
    .padding()
}

#Preview("Colors") {
    VStack(alignment: .leading, spacing: DSSpacing.sm) {
        colorRow("Window", DSColors.window)
        colorRow("Content", DSColors.content)
        colorRow("Code", DSColors.code)
        colorRow("Raised", DSColors.raised)
        colorRow("Sheet", DSColors.sheet)
        colorRow("Field", DSColors.field)
        colorRow("Hover", DSColors.hover)
        colorRow("Zebra", DSColors.zebra)
        Divider()
        colorRow("Accent", DSColors.accent)
        colorRow("Selection soft", DSColors.selectionSoft)
        colorRow("Selection inactive", DSColors.selectionInactive)
        colorRow("Success", DSColors.success)
        colorRow("Redirect", DSColors.redirect)
        colorRow("Warning", DSColors.warning)
        colorRow("Error", DSColors.error)
        Divider()
        colorRow("Label primary", DSColors.labelPrimary)
        colorRow("Label secondary", DSColors.labelSecondary)
        colorRow("Label tertiary", DSColors.labelTertiary)
        colorRow("Field border", DSColors.fieldBorder)
        colorRow("Separator", DSColors.separator)
        Divider()
        Text("HTTP method colors").font(DSTypography.body).foregroundStyle(DSColors.labelSecondary)
        HStack(spacing: DSSpacing.sm) {
            methodColorDot("GET")
            methodColorDot("POST")
            methodColorDot("PUT")
            methodColorDot("PATCH")
            methodColorDot("DELETE")
        }
    }
    .padding()
}

#Preview("Animation Durations") {
    VStack(alignment: .leading, spacing: DSSpacing.sm) {
        animRow("fast", DSAnimation.fast)
        animRow("normal", DSAnimation.normal)
        animRow("slow", DSAnimation.slow)
    }
    .padding()
}

private func spacingRow(_ name: String, _ value: CGFloat) -> some View {
    HStack {
        Text(name).font(DSTypography.code).frame(width: 40, alignment: .leading)
        Rectangle().fill(Color.accentColor).frame(width: value, height: 16)
        Text("\(Int(value))pt").font(DSTypography.body).foregroundStyle(DSColors.labelSecondary)
    }
}

private func colorRow(_ name: String, _ color: Color) -> some View {
    HStack {
        RoundedRectangle(cornerRadius: DSCornerRadius.field)
            .fill(color)
            .frame(width: 24, height: 24)
            .overlay(
                RoundedRectangle(cornerRadius: DSCornerRadius.field)
                    .stroke(DSColors.fieldBorder, lineWidth: DSStroke.hairline)
            )
        Text(name).font(DSTypography.body)
    }
}

private func methodColorDot(_ method: String) -> some View {
    HStack(spacing: 4) {
        Circle().fill(DSColors.methodColor(for: method)).frame(width: 12, height: 12)
        Text(method).font(DSTypography.code)
    }
}

private func animRow(_ name: String, _ value: Double) -> some View {
    HStack {
        Text(name).font(DSTypography.code).frame(width: 60, alignment: .leading)
        Text(String(format: "%.2fs", value)).font(DSTypography.body).foregroundStyle(DSColors.labelSecondary)
    }
}
#endif

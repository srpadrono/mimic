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
        Text("Display (28pt bold)").font(DSTypography.display)
        Text("Title (21pt semibold)").font(DSTypography.title)
        Text("Heading (18pt semibold)").font(DSTypography.heading)
        Text("Subheading (15pt medium)").font(DSTypography.subheading)
        Text("Body Bold (14pt semibold)").font(DSTypography.bodyBold)
        Text("Body Medium (14pt medium)").font(DSTypography.bodyMedium)
        Text("Body (14pt regular)").font(DSTypography.body)
        Text("Label (13pt regular)").font(DSTypography.label)
        Text("Caption (11pt medium)").font(DSTypography.caption)
        Divider()
        Text("Code Large (SF Mono 14pt)").font(DSTypography.codeLarge)
        Text("Code Bold (SF Mono 13pt medium)").font(DSTypography.codeBold)
        Text("Code (SF Mono 13pt regular)").font(DSTypography.code)
        Text("Code Small (SF Mono 12pt)").font(DSTypography.codeSmall)
    }
    .padding()
}

#Preview("Colors") {
    VStack(alignment: .leading, spacing: DSSpacing.sm) {
        colorRow("Dominant", DSColors.dominant)
        colorRow("Secondary", DSColors.secondary)
        colorRow("Tertiary", DSColors.tertiary)
        colorRow("Surface Elevated", DSColors.surfaceElevated)
        colorRow("Accent", DSColors.accent)
        colorRow("Accent Subtle", DSColors.accentSubtle)
        colorRow("Accent Muted", DSColors.accentMuted)
        colorRow("Destructive", DSColors.destructive)
        colorRow("Success", DSColors.success)
        colorRow("Warning", DSColors.warning)
        Divider()
        colorRow("Label Primary", DSColors.labelPrimary)
        colorRow("Label Secondary", DSColors.labelSecondary)
        colorRow("Label Tertiary", DSColors.labelTertiary)
        colorRow("Border", DSColors.border)
        colorRow("Separator", DSColors.separator)
        Divider()
        Text("HTTP Method Colors").font(DSTypography.label).foregroundStyle(DSColors.labelSecondary)
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
        animRow("micro", DSAnimation.micro)
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
        Text("\(Int(value))pt").font(DSTypography.label).foregroundStyle(DSColors.labelSecondary)
    }
}

private func colorRow(_ name: String, _ color: Color) -> some View {
    HStack {
        RoundedRectangle(cornerRadius: DSCornerRadius.sm)
            .fill(color)
            .frame(width: 24, height: 24)
            .overlay(
                RoundedRectangle(cornerRadius: DSCornerRadius.sm)
                    .stroke(DSColors.border, lineWidth: DSStroke.hairline)
            )
        Text(name).font(DSTypography.body)
    }
}

private func methodColorDot(_ method: String) -> some View {
    HStack(spacing: 4) {
        Circle().fill(DSColors.methodColor(for: method)).frame(width: 12, height: 12)
        Text(method).font(DSTypography.codeSmall)
    }
}

private func animRow(_ name: String, _ value: Double) -> some View {
    HStack {
        Text(name).font(DSTypography.code).frame(width: 60, alignment: .leading)
        Text(String(format: "%.2fs", value)).font(DSTypography.label).foregroundStyle(DSColors.labelSecondary)
    }
}
#endif

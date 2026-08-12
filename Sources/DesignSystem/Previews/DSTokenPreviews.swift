import SwiftUI

// Guarded so previews do not ship.
//
// `#Preview` expands to a `PreviewRegistry` conformance, which is compiled into whatever
// configuration builds the file — and nothing here was gated, so 386 lines of preview scaffolding
// went into the Release binary. Every `#Preview` elsewhere in this project is already inside
// `#if DEBUG`; the design system's were the exception.
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
        Text("Display (28px bold)").font(DSTypography.display)
        Text("Title (20px semibold)").font(DSTypography.title)
        Text("Heading (16px semibold)").font(DSTypography.heading)
        Text("Subheading (14px medium)").font(DSTypography.subheading)
        Text("Body Bold (13px semibold)").font(DSTypography.bodyBold)
        Text("Body Medium (13px medium)").font(DSTypography.bodyMedium)
        Text("Body (13px regular)").font(DSTypography.body)
        Text("Label (11px regular)").font(DSTypography.label)
        Text("Caption (10px medium)").font(DSTypography.caption)
        Divider()
        Text("Code Large (SF Mono 13px)").font(DSTypography.codeLarge)
        Text("Code Bold (SF Mono 12px medium)").font(DSTypography.codeBold)
        Text("Code (SF Mono 12px regular)").font(DSTypography.code)
        Text("Code Small (SF Mono 11px)").font(DSTypography.codeSmall)
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
        Text("HTTP Method Colors").font(DSTypography.label).foregroundStyle(.secondary)
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
        Text("\(Int(value))pt").font(DSTypography.label).foregroundStyle(.secondary)
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
        Text(String(format: "%.2fs", value)).font(DSTypography.label).foregroundStyle(.secondary)
    }
}
#endif

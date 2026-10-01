import AppKit
import DesignSystem
import SnapshotSupport
import SwiftUI

/// How the design image is shown against the live section.
enum OverlayMode: String, CaseIterable, Identifiable {
    case off = "Off"
    case overlay = "Overlay"
    case difference = "Difference"
    case sideBySide = "Side by side"

    var id: String { rawValue }
}

/// The gallery: every component and section down the side, one on the canvas at its artboard
/// size, and the artboard itself laid over it to compare.
struct GalleryView: View {
    @Environment(\.openWindow) private var openWindow
    @State private var selection: String? = GalleryCatalog.selected.first?.id
    @State private var appearance: SnapshotRenderer.Appearance = .dark
    @State private var overlay: OverlayMode = .off
    @State private var opacity = 0.5
    @State private var zoom = 1.0
    @State private var status: String?

    /// Every entry, or only the ones `MIMIC_SECTION` names.
    private let entries = GalleryCatalog.selected
    private let references = try? DesignReferenceCatalog.inRepository()

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(GalleryEntry.Group.allCases) { group in
                    let members = entries.filter { $0.group == group }
                    if !members.isEmpty {
                        Section(group.rawValue) {
                            ForEach(members) { entry in
                                Text(entry.title).tag(entry.id)
                            }
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        } detail: {
            if let entry = entries.first(where: { $0.id == selection }) {
                canvas(for: entry)
            } else {
                Text("Choose a component or section").foregroundStyle(DSColors.labelSecondary)
            }
        }
        .toolbar { controls }
        .onChange(of: appearance, initial: true) { _, appearance in
            NSApp.appearance = NSAppearance(named: appearance == .dark ? .darkAqua : .aqua)
        }
    }

    @ToolbarContentBuilder
    private var controls: some ToolbarContent {
        ToolbarItemGroup {
            Picker("Appearance", selection: $appearance) {
                ForEach(SnapshotRenderer.Appearance.allCases) { Text($0.rawValue.capitalized).tag($0) }
            }
            .pickerStyle(.segmented)
            Picker("Design", selection: $overlay) {
                ForEach(OverlayMode.allCases) { Text($0.rawValue).tag($0) }
            }
            Slider(value: $opacity, in: 0...1) { Text("Opacity") }
                .frame(width: 100)
                .disabled(overlay != .overlay)
            Picker("Zoom", selection: $zoom) {
                Text("50%").tag(0.5)
                Text("100%").tag(1.0)
                Text("200%").tag(2.0)
            }
            Button("Export report", systemImage: "square.and.arrow.up", action: exportReport)
        }
    }

    private func canvas(for entry: GalleryEntry) -> some View {
        let reference = referenceImage(for: entry)
        return ScrollView([.horizontal, .vertical]) {
            HStack(alignment: .top, spacing: 24) {
                ZStack(alignment: .topLeading) {
                    entry.content()
                        .frame(width: entry.size.width, height: entry.size.height)
                        .clipped()
                    if let reference, overlay == .overlay || overlay == .difference {
                        Image(nsImage: reference)
                            .resizable()
                            .frame(width: entry.size.width, height: entry.size.height)
                            .opacity(overlay == .overlay ? opacity : 1)
                            .blendMode(overlay == .difference ? .difference : .normal)
                            .allowsHitTesting(false)
                    }
                }
                if let reference, overlay == .sideBySide {
                    Image(nsImage: reference)
                        .resizable()
                        .frame(width: entry.size.width, height: entry.size.height)
                }
            }
            .scaleEffect(zoom, anchor: .topLeading)
            .frame(
                width: (entry.size.width * (overlay == .sideBySide ? 2 : 1) + 24) * zoom,
                height: entry.size.height * zoom,
                alignment: .topLeading
            )
            .padding(32)
        }
        .background(DSColors.window)
        .overlay(alignment: .bottomLeading) {
            footer(entry: entry, missingReference: reference == nil ? missingReferenceNote(for: entry) : nil)
        }
        .id("\(entry.id)-\(appearance.rawValue)")
    }

    private func footer(entry: GalleryEntry, missingReference: String?) -> some View {
        HStack(spacing: DSSpacing.md) {
            Text("\(entry.referenceID) \u{00B7} \(Int(entry.size.width)) \u{00D7} \(Int(entry.size.height)) pt")
            if let missingReference {
                Text(missingReference).foregroundStyle(DSColors.warning)
            }
            if entry.window != nil {
                Button("Open in a window", systemImage: "macwindow") {
                    openWindow(id: GalleryWindow.sceneID, value: entry.id)
                }
                .help("Open this window on its own, with its toolbar")
                .accessibilityIdentifier("gallery.openInWindow")
            }
            if let status { Text(status).foregroundStyle(DSColors.labelSecondary) }
        }
        .font(DSTypography.caption)
        .padding(DSSpacing.sm)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: DSCornerRadius.field))
        .padding(DSSpacing.md)
    }

    /// Why an entry has no design image in the current appearance.
    private func missingReferenceNote(for entry: GalleryEntry) -> String {
        if !entry.hasArtboard {
            return "The design has no artboard for this entry."
        }
        if let references, let section = references.section(entry.referenceID),
           !references.draws(section, in: appearance.rawValue) {
            return "The design draws this board in one appearance only. Switch appearance to compare."
        }
        return "No design image. Run swift Scripts/export_design_references.swift."
    }

    private func referenceImage(for entry: GalleryEntry) -> NSImage? {
        guard let references, let section = references.section(entry.referenceID),
              references.draws(section, in: appearance.rawValue),
              let image = references.image(for: section, theme: appearance.rawValue) else { return nil }
        return NSImage(cgImage: image, size: section.frame.size)
    }

    /// Renders every entry in the current appearance and writes a fidelity report beside it.
    private func exportReport() {
        let report = FidelityReport(directory: FidelityReport.defaultDirectory())
        for entry in entries {
            if let catalog = references, let section = catalog.section(entry.referenceID),
               !catalog.draws(section, in: appearance.rawValue) { continue }
            guard let actual = SnapshotRenderer.render(entry.content(), size: entry.size, appearance: appearance)
            else { continue }
            let reference = references.flatMap { catalog in
                catalog.section(entry.referenceID).flatMap { catalog.image(for: $0, theme: appearance.rawValue) }
            }
            report.add(id: entry.id, title: entry.title, appearance: appearance.rawValue,
                       actual: actual, reference: reference)
        }
        do {
            try report.write()
            status = "Report written to \(report.directory.path)"
            NSWorkspace.shared.open(report.directory.appendingPathComponent("index.html"))
        } catch {
            status = "Could not write the report: \(error.localizedDescription)"
        }
    }
}

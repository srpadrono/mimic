import CoreGraphics
import Foundation
import SnapshotSupport
import Testing
@testable import MimicGallery

/// Renders every gallery entry and scores it against its artboard.
///
/// The scores are a report, not a gate: the design is drawn by WebKit and the app by AppKit, so no
/// section will ever match to the pixel, and a threshold would only move with every font update.
/// What this suite does assert is that the catalogue and the design manifest agree, and that every
/// entry draws at its artboard's size. The report lands in `$MIMIC_FIDELITY_REPORT`, or in the
/// temporary directory, with an `index.html` that shows each section beside its design.
@Suite("Design fidelity", .serialized)
@MainActor
struct DesignFidelityTests {
    private let catalog: DesignReferenceCatalog

    init() throws {
        catalog = try DesignReferenceCatalog.inRepository()
    }

    @Test("Every gallery entry names a section the design manifest has")
    func everyEntryHasAReferenceSection() {
        let known = Set(catalog.sections.map(\.id))
        let missing = GalleryCatalog.entries.filter(\.hasArtboard).map(\.referenceID).filter { !known.contains($0) }
        #expect(missing.isEmpty, "Unknown design sections: \(missing)")
    }

    @Test("Every window entry opens in a window of its own, where its toolbar draws")
    func windowEntriesOpenInAWindow() {
        let windows = GalleryCatalog.entries.filter { $0.group == .windows }
        #expect(windows.map(\.id) == ["workspace.window", "workspace.skeleton"])
        #expect(windows.allSatisfy { $0.window != nil })
        #expect(GalleryCatalog.entries.filter { $0.group != .windows }.allSatisfy { $0.window == nil })
    }

    @Test("The toolbar entries are the approved toolbar design's states")
    func toolbarEntriesFollowTheToolbarBoard() throws {
        let toolbar = GalleryCatalog.entries(matching: "toolbar")
        #expect(toolbar.map(\.id) == ["toolbar.running", "toolbar.stopped", "toolbar.restartRequired", "toolbar.compact"])
        for entry in toolbar {
            let section = try #require(catalog.section(entry.id))
            #expect(section.board == "Toolbar")
        }
    }

    @Test("Every gallery entry is drawn at its artboard section's size")
    func entriesMatchTheirSectionSize() {
        for entry in GalleryCatalog.entries where entry.referenceID == entry.id {
            guard let section = catalog.section(entry.referenceID) else { continue }
            #expect(section.frame.size == entry.size, "\(entry.id) is \(entry.size), its artboard is \(section.frame.size)")
        }
    }

    @Test("A section filter keeps only the entries it names")
    func sectionFilterMatchesIdsPrefixesAndGroups() {
        let all = GalleryCatalog.entries
        #expect(GalleryCatalog.entries(matching: nil).count == all.count)
        #expect(GalleryCatalog.entries(matching: " ").count == all.count)

        let journeys = GalleryCatalog.entries(matching: "journeys").map(\.id)
        #expect(!journeys.isEmpty)
        #expect(journeys.allSatisfy { $0.hasPrefix("journeys.") })

        #expect(GalleryCatalog.entries(matching: "Journeys.Navigator").map(\.id) == ["journeys.navigator"])
        #expect(GalleryCatalog.entries(matching: "journeys.navigator, tokens.colour").map(\.id)
            == ["journeys.navigator", "tokens.colour"])
        #expect(GalleryCatalog.entries(matching: "request log").map(\.id) == ["requestLog.drawer", "requestLog.detail"])
        #expect(GalleryCatalog.entries(matching: "journey").isEmpty)
    }

    @Test("Scoring every section against its artboard writes a report", arguments: SnapshotRenderer.Appearance.allCases)
    func writeFidelityReport(appearance: SnapshotRenderer.Appearance) throws {
        let report = FidelityReport(directory: FidelityReport.defaultDirectory())
        // `MIMIC_SECTION` narrows the report to one section; unset, every entry is scored.
        for entry in GalleryCatalog.selected {
            // The Tokens board is drawn on one dark canvas; scoring its sections in light would
            // compare the background, not the tokens.
            if let section = catalog.section(entry.referenceID),
               !catalog.draws(section, in: appearance.rawValue) { continue }
            let image = try #require(
                SnapshotRenderer.render(entry.content(), size: entry.size, appearance: appearance),
                "\(entry.id) drew nothing"
            )
            #expect(image.width == Int(entry.size.width * 2) && image.height == Int(entry.size.height * 2))
            let reference = catalog.section(entry.referenceID).flatMap {
                catalog.image(for: $0, theme: appearance.rawValue)
            }
            report.add(id: entry.id, title: entry.title, appearance: appearance.rawValue,
                       actual: image, reference: reference)
        }
        try report.write()
        print("Design fidelity (\(appearance.rawValue)), report in \(report.directory.path):\n\(report.summary())")
    }
}

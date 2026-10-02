import CoreGraphics
import Foundation
import SnapshotSupport
import Testing
@testable import MimicGallery

/// Renders every gallery entry and compares it with its approved rendering in `Snapshots/`.
///
/// This is the gate the design fidelity report is not: a baseline is an earlier rendering of the
/// same entry on the same CI macOS image, so a moved control, a resized row or a lost colour fails
/// here in seconds, without launching the app or touching the mouse. It replaces pixel assertions
/// in the XCUITest suite, which were slow and the flakiest checks there.
///
/// Baselines are recorded by CI, not on a developer Mac: fonts rasterise differently on another
/// macOS version. When an entry is new or changed on purpose, the failing run pushes the new
/// renderings to the `snapshots/<branch>` branch, laid out as they would be committed, with a
/// difference image for each change under `Differences/`. Check out the approved PNGs from there
/// into `Snapshots/` and commit them (CONTRIBUTING.md, Test gates).
@Suite("Gallery snapshots", .serialized)
@MainActor
struct GallerySnapshotTests {
    /// The baselines sit beside this file in the checkout the tests were built from.
    private static let baselines = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Snapshots", isDirectory: true)

    /// Where new and changed renderings go: `$MIMIC_SNAPSHOT_OUTPUT`, else the temporary directory.
    private static var output: URL {
        if let path = ProcessInfo.processInfo.environment["MIMIC_SNAPSHOT_OUTPUT"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.temporaryDirectory.appendingPathComponent("MimicSnapshots", isDirectory: true)
    }

    @Test("Every gallery entry draws as its approved snapshot", arguments: SnapshotRenderer.Appearance.allCases)
    func entriesMatchTheirBaselines(appearance: SnapshotRenderer.Appearance) throws {
        var missing: [String] = []
        var changed: [String] = []

        // `MIMIC_SECTION` narrows the run to one section; unset, every entry is checked.
        for entry in GalleryCatalog.selected {
            let name = "\(entry.id).\(appearance.rawValue).png"
            let image = try #require(
                SnapshotRenderer.render(entry.content(), size: entry.size, appearance: appearance,
                                        focusesList: entry.focusesList),
                "\(entry.id) drew nothing"
            )
            let result = SnapshotBaseline.check(
                actual: image,
                baseline: PNG.read(Self.baselines.appendingPathComponent(name))
            )
            switch result.verdict {
            case .matches:
                continue
            case .missing:
                PNG.write(image, to: Self.output.appendingPathComponent("new/\(name)"))
                missing.append(name)
            case .changed(let score):
                PNG.write(image, to: Self.output.appendingPathComponent("changed/\(name)"))
                if let difference = result.difference {
                    PNG.write(difference, to: Self.output.appendingPathComponent("difference/\(name)"))
                }
                let percent = String(format: "%.2f%%", score.mismatchedFraction * 100)
                changed.append("\(name): \(percent) of pixels changed" + (score.sizesMatched ? "" : ", and its size"))
            }
        }

        #expect(
            missing.isEmpty,
            "No approved snapshot for \(missing.count) entries: \(missing.joined(separator: ", ")). New renderings are in \(Self.output.path)/new."
        )
        #expect(
            changed.isEmpty,
            "\(changed.count) entries no longer match their snapshot:\n\(changed.joined(separator: "\n"))\nRenderings and differences are in \(Self.output.path)."
        )
    }
}

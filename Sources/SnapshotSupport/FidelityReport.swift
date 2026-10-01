import CoreGraphics
import Foundation

/// A folder of renderings beside their design images, with a page that shows them side by side.
///
/// Written by the design fidelity tests and the gallery's Export button. Each entry leaves three
/// PNGs (`<id>.actual.png`, `<id>.reference.png`, `<id>.difference.png`), and the report keeps a
/// `report.json` and an `index.html` sorted worst first.
public final class FidelityReport {
    public struct Entry: Codable, Sendable, Equatable {
        public var id: String
        public var title: String
        public var appearance: String
        /// `nil` when the section has no exported design image yet.
        public var score: FidelityScore?
    }

    public let directory: URL
    public private(set) var entries: [Entry] = []

    public init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Where reports go when nothing says otherwise: `$MIMIC_FIDELITY_REPORT`, else a folder in the
    /// temporary directory.
    public static func defaultDirectory() -> URL {
        if let path = ProcessInfo.processInfo.environment["MIMIC_FIDELITY_REPORT"], !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        return FileManager.default.temporaryDirectory.appendingPathComponent("MimicFidelity")
    }

    /// Scores `actual` against `reference`, writes the images, and records the entry.
    @discardableResult
    public func add(id: String, title: String, appearance: String, actual: CGImage, reference: CGImage?) -> Entry {
        let stem = "\(id).\(appearance)"
        PNG.write(actual, to: directory.appendingPathComponent("\(stem).actual.png"))
        var score: FidelityScore?
        if let reference {
            let result = FidelityComparison.compare(actual, with: reference)
            score = result.score
            PNG.write(reference, to: directory.appendingPathComponent("\(stem).reference.png"))
            if let difference = result.difference {
                PNG.write(difference, to: directory.appendingPathComponent("\(stem).difference.png"))
            }
        }
        let entry = Entry(id: id, title: title, appearance: appearance, score: score)
        entries.removeAll { $0.id == id && $0.appearance == appearance }
        entries.append(entry)
        return entry
    }

    /// Writes `report.json` and `index.html`. Safe to call after every entry.
    public func write() throws {
        let sorted = entries.sorted { ($0.score?.similarity ?? -1) < ($1.score?.similarity ?? -1) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(sorted).write(to: directory.appendingPathComponent("report.json"), options: .atomic)
        try html(for: sorted).write(to: directory.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
    }

    /// One line per entry, worst first, for a test log.
    public func summary() -> String {
        entries
            .sorted { ($0.score?.similarity ?? -1) < ($1.score?.similarity ?? -1) }
            .map { entry in
                guard let score = entry.score else { return "\(entry.id) \(entry.appearance): no design image" }
                let percent = String(format: "%.1f%%", score.similarity * 100)
                return "\(entry.id) \(entry.appearance): \(percent) within tolerance"
                    + (score.sizesMatched ? "" : " (size differs from the design)")
            }
            .joined(separator: "\n")
    }

    private func html(for entries: [Entry]) -> String {
        let rows = entries.map { entry -> String in
            let stem = "\(entry.id).\(entry.appearance)"
            let figure = entry.score.map { String(format: "%.1f%% within tolerance, mean delta %.3f", $0.similarity * 100, $0.meanDelta) }
                ?? "No design image"
            return """
            <section><h2>\(escape(entry.title)) <small>\(escape(entry.id)) · \(entry.appearance) · \(figure)</small></h2>
            <div class="row"><figure><img src="\(stem).actual.png"><figcaption>App</figcaption></figure>
            <figure><img src="\(stem).reference.png"><figcaption>Design</figcaption></figure>
            <figure><img src="\(stem).difference.png"><figcaption>Difference</figcaption></figure></div></section>
            """
        }
        return """
        <!doctype html><html><head><meta charset="utf-8"><title>Mimic design fidelity</title>
        <style>body{font:13px -apple-system,sans-serif;margin:24px;background:#1b1b1d;color:#eee}
        h2{font-size:15px}small{color:#999;font-weight:400}.row{display:flex;gap:12px;align-items:flex-start}
        figure{margin:0;flex:1}img{width:100%;border:1px solid #333}figcaption{color:#999}</style></head>
        <body><h1>Design fidelity</h1>\(rows.joined(separator: "\n"))</body></html>
        """
    }

    private func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
    }
}

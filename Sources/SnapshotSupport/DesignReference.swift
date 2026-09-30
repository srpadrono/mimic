import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The exported design artboards and where each section sits on them.
///
/// Reads `Design/Reference/sections.json` and the PNGs beside it, which
/// `Scripts/export_design_references.swift` writes from the canvas in `Design/Canvas`.
public struct DesignReferenceCatalog: Sendable {
    public struct Board: Decodable, Sendable, Equatable {
        public let source: String
        public let width: Double
        public let height: Double
        public let themes: [String?]
    }

    public struct Section: Decodable, Sendable, Equatable, Identifiable {
        public let id: String
        public let board: String
        /// `[x, y, width, height]` in points on the board.
        public let rect: [Double]
        public let title: String

        public var frame: CGRect {
            guard rect.count == 4 else { return .zero }
            return CGRect(x: rect[0], y: rect[1], width: rect[2], height: rect[3])
        }
    }

    private struct Manifest: Decodable {
        let scale: Double
        let boards: [String: Board]
        let sections: [Section]
    }

    public let directory: URL
    public let scale: Double
    public let boards: [String: Board]
    public let sections: [Section]

    public init(directory: URL) throws {
        let manifest = try JSONDecoder().decode(
            Manifest.self,
            from: Data(contentsOf: directory.appendingPathComponent("sections.json"))
        )
        self.directory = directory
        self.scale = manifest.scale
        self.boards = manifest.boards
        self.sections = manifest.sections
    }

    /// The catalog next to this source file in a checkout, for tests and the gallery run from Xcode.
    public static func inRepository(file: StaticString = #filePath) throws -> DesignReferenceCatalog {
        var url = URL(fileURLWithPath: "\(file)")
        while url.pathComponents.count > 1 {
            url.deleteLastPathComponent()
            let candidate = url.appendingPathComponent("Design/Reference")
            if FileManager.default.fileExists(atPath: candidate.appendingPathComponent("sections.json").path) {
                return try DesignReferenceCatalog(directory: candidate)
            }
        }
        throw CocoaError(.fileNoSuchFile)
    }

    public func section(_ id: String) -> Section? {
        sections.first { $0.id == id }
    }

    /// The file a board's image is exported to: `Main-dark.png`, or `Tokens.png` for an unthemed board.
    public func imageURL(board: String, theme: String?) -> URL {
        let themed = boards[board].map { !$0.themes.isEmpty } ?? true
        let name = themed ? "\(board)-\(theme ?? "dark").png" : "\(board).png"
        return directory.appendingPathComponent(name)
    }

    /// The section's crop of its board, at the export scale, or `nil` when the board has not been
    /// exported yet.
    public func image(for section: Section, theme: String?) -> CGImage? {
        guard let board = PNG.read(imageURL(board: section.board, theme: theme)) else { return nil }
        let frame = section.frame
        let crop = CGRect(
            x: frame.minX * scale,
            y: frame.minY * scale,
            width: frame.width * scale,
            height: frame.height * scale
        ).integral
        return board.cropping(to: crop)
    }
}

/// Reads and writes PNG files without AppKit.
public enum PNG {
    public static func read(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    @discardableResult
    public static func write(_ image: CGImage, to url: URL) -> Bool {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        ) else { return false }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination)
    }
}

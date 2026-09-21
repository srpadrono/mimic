import Foundation
import Domain

/// Immutable private storage retained only while its log entry is retained.
final class CapturedResponseFile: Sendable {
    let directory: URL
    let url: URL

    init(data: Data) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mimic-response-" + UUID().uuidString, isDirectory: true)
        self.directory = directory
        url = directory.appendingPathComponent("body")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        do {
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    static func capture(_ data: Data) throws -> CapturedResponseBody {
        let file = try CapturedResponseFile(data: data)
        return CapturedResponseBody(byteCount: data.count) {
            try String(contentsOf: file.url, encoding: .utf8)
        }
    }
}

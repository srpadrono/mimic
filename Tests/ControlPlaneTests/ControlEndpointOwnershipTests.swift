import Domain
import Foundation
import Testing
@testable import ControlPlane

@Suite("Control discovery ownership")
struct ControlEndpointOwnershipTests {
    @Test("A replacement waits until owner-checked cleanup finishes")
    func cleanupAndReplacementShareOneLock() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mimic-discovery-lock-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("control.json")
        let first = ControlEndpoint(port: 8787, pid: 1111, mode: "app", token: "first-token")
        let second = ControlEndpoint(port: 8788, pid: 2222, mode: "app", token: "second-token")
        try ControlEndpointFile.write(first, to: url)

        let startWriter = DispatchSemaphore(value: 0)
        let writerStarted = DispatchSemaphore(value: 0)
        let writerFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            startWriter.wait()
            writerStarted.signal()
            try? ControlEndpointFile.write(second, to: url)
            writerFinished.signal()
        }

        // Without a lock on either side, the second advertisement lands between the read and
        // unlink, then the older owner deletes it. The writer must remain blocked at this point.
        ControlEndpointFile.remove(expected: first, at: url, afterOwnershipCheck: {
            startWriter.signal()
            #expect(writerStarted.wait(timeout: .now() + 5) == .success)
            #expect(writerFinished.wait(timeout: .now() + 1) == .timedOut)
        })
        #expect(writerFinished.wait(timeout: .now() + 5) == .success)
        let surviving = try ControlCoding.decode(ControlEndpoint.self, from: Data(contentsOf: url))
        #expect(surviving == second)

        let lockPath = url.path + ".lock"
        let mode = try FileManager.default.attributesOfItem(atPath: lockPath)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o600)
    }

    @Test("Cleanup does not remove an already replaced advertisement")
    func cleanupKeepsReplacementAdvertisement() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mimic-discovery-owners-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("control.json")
        let first = ControlEndpoint(port: 8787, pid: 1111, mode: "app", token: "shared-ci-token")
        // A CI token may be stable across processes and the same port can be reused after a
        // restart. A process may also publish a new port under the same pid. Each owner field that
        // matters therefore gets a replacement whose other key fields stay equal.
        let replacements = [
            ControlEndpoint(port: 8787, pid: 2222, mode: "app", token: "shared-ci-token"),
            ControlEndpoint(port: 8788, pid: 1111, mode: "app", token: "shared-ci-token"),
            ControlEndpoint(port: 8787, pid: 1111, mode: "app", token: "new-token"),
        ]

        for second in replacements {
            try ControlEndpointFile.write(first, to: url)
            try ControlEndpointFile.write(second, to: url)

            // Reverting removal to a path-only unlink makes this read fail.
            ControlEndpointFile.remove(expected: first, at: url)
            let surviving = try ControlCoding.decode(ControlEndpoint.self, from: Data(contentsOf: url))
            #expect(surviving == second)

            ControlEndpointFile.remove(expected: second, at: url)
            #expect(!FileManager.default.fileExists(atPath: url.path))
        }
    }

    @Test("A damaged advertisement is never deleted on an assumed identity")
    func cleanupKeepsUndecodableFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mimic-discovery-damaged-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("control.json")
        let bytes = Data(#"{"pid":not-json}"#.utf8)
        try bytes.write(to: url)

        let expected = ControlEndpoint(port: 8787, pid: 1111, mode: "app", token: "owner-token")
        ControlEndpointFile.remove(expected: expected, at: url)
        #expect(try Data(contentsOf: url) == bytes)
    }
}

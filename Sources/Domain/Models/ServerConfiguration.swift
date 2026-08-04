import Foundation

public struct ServerConfiguration: Codable, Sendable, Equatable {
    public var port: Int
    public var globalDelayMs: Int

    public static let `default` = ServerConfiguration(port: 8080, globalDelayMs: 0)

    public init(port: Int, globalDelayMs: Int) {
        self.port = port
        self.globalDelayMs = globalDelayMs
    }
}

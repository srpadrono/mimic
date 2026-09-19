import Foundation

public struct ServerConfiguration: Codable, Sendable, Equatable {
    public var port: Int
    public var globalDelayMs: Int
    /// Optional upstream for the original listener. Nil keeps the existing mock-only behavior.
    public var upstreamURL: String?
    /// Additional listeners in the same project, each with its own upstream.
    public var backends: [BackendConfiguration]

    public static let `default` = ServerConfiguration(port: 8080, globalDelayMs: 0)

    public init(port: Int, globalDelayMs: Int, upstreamURL: String? = nil, backends: [BackendConfiguration] = []) {
        self.port = port
        self.globalDelayMs = globalDelayMs
        self.upstreamURL = upstreamURL
        self.backends = backends
    }

    private enum CodingKeys: String, CodingKey { case port, globalDelayMs, upstreamURL, backends }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        port = try container.decode(Int.self, forKey: .port)
        globalDelayMs = try container.decode(Int.self, forKey: .globalDelayMs)
        upstreamURL = try container.decodeIfPresent(String.self, forKey: .upstreamURL)
        backends = try container.decodeIfPresent([BackendConfiguration].self, forKey: .backends) ?? []
    }
}

public struct BackendConfiguration: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public var name: String
    public var port: Int
    public var upstreamURL: String?

    public init(id: UUID = UUID(), name: String, port: Int, upstreamURL: String? = nil) {
        self.id = id
        self.name = name
        self.port = port
        self.upstreamURL = upstreamURL
    }
}

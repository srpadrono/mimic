import Foundation

public struct ServerConfiguration: Codable, Sendable, Equatable {
    public var port: Int
    public var globalDelayMs: Int
    public var upstreamURL: String?
    public var backends: [BackendConfiguration]
    public var primaryName: String
    public var passthroughEnabled: Bool
    public var captureResponses: Bool

    public static let `default` = ServerConfiguration(port: 8080, globalDelayMs: 0)
    public static let primaryID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

    public init(port: Int, globalDelayMs: Int, upstreamURL: String? = nil, backends: [BackendConfiguration] = [],
                primaryName: String = "Primary", passthroughEnabled: Bool? = nil, captureResponses: Bool = false) {
        self.port = port
        self.globalDelayMs = globalDelayMs
        self.upstreamURL = upstreamURL
        self.backends = backends
        self.primaryName = primaryName
        self.passthroughEnabled = passthroughEnabled ?? (upstreamURL != nil)
        self.captureResponses = captureResponses
    }

    public var listeners: [BackendConfiguration] {
        [BackendConfiguration(id: Self.primaryID, name: primaryName, port: port, upstreamURL: upstreamURL,
                              passthroughEnabled: passthroughEnabled, captureResponses: captureResponses)] + backends
    }

    public func backend(id: UUID?) -> BackendConfiguration? {
        listeners.first { $0.id == (id ?? Self.primaryID) }
    }

    public func hasSameListeners(as other: ServerConfiguration) -> Bool {
        listeners.map { "\($0.id):\($0.port)" }.sorted()
            == other.listeners.map { "\($0.id):\($0.port)" }.sorted()
    }

    private enum CodingKeys: String, CodingKey {
        case port, globalDelayMs, upstreamURL, backends, primaryName, passthroughEnabled, captureResponses
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        port = try c.decode(Int.self, forKey: .port)
        globalDelayMs = try c.decode(Int.self, forKey: .globalDelayMs)
        upstreamURL = try c.decodeIfPresent(String.self, forKey: .upstreamURL)
        backends = try c.decodeIfPresent([BackendConfiguration].self, forKey: .backends) ?? []
        primaryName = try c.decodeIfPresent(String.self, forKey: .primaryName) ?? "Primary"
        passthroughEnabled = try c.decodeIfPresent(Bool.self, forKey: .passthroughEnabled) ?? (upstreamURL != nil)
        captureResponses = try c.decodeIfPresent(Bool.self, forKey: .captureResponses) ?? false
    }
}

public struct BackendConfiguration: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public var name: String
    public var port: Int
    public var upstreamURL: String?
    public var passthroughEnabled: Bool
    public var captureResponses: Bool
    public var localURL: String { "http://localhost:\(port)" }
    public var effectiveUpstream: String? { passthroughEnabled ? upstreamURL : nil }

    public init(id: UUID = UUID(), name: String, port: Int, upstreamURL: String? = nil,
                passthroughEnabled: Bool? = nil, captureResponses: Bool = false) {
        self.id = id
        self.name = name
        self.port = port
        self.upstreamURL = upstreamURL
        self.passthroughEnabled = passthroughEnabled ?? (upstreamURL != nil)
        self.captureResponses = captureResponses
    }

    private enum CodingKeys: String, CodingKey { case id, name, port, upstreamURL, passthroughEnabled, captureResponses }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        port = try c.decode(Int.self, forKey: .port)
        upstreamURL = try c.decodeIfPresent(String.self, forKey: .upstreamURL)
        passthroughEnabled = try c.decodeIfPresent(Bool.self, forKey: .passthroughEnabled) ?? (upstreamURL != nil)
        captureResponses = try c.decodeIfPresent(Bool.self, forKey: .captureResponses) ?? false
    }
}

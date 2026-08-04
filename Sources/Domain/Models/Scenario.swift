import Foundation

public struct Scenario: Identifiable, Codable, Sendable, Equatable {
    public enum ContentType: String, Codable, Sendable {
        case json = "application/json"
        case plainText = "text/plain"
    }

    public let id: UUID
    public var name: String
    public var statusCode: Int
    public var headers: [String: String]
    public var body: String?
    public var bodyContentType: ContentType

    public init(
        id: UUID = UUID(),
        name: String,
        statusCode: Int = 200,
        headers: [String: String] = [:],
        body: String? = nil,
        bodyContentType: ContentType = .json
    ) {
        self.id = id
        self.name = name
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
        self.bodyContentType = bodyContentType
    }
}

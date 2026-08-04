import Foundation

// MARK: - HAR 1.2 Codable Models
// Spec: http://www.softwareishard.com/blog/har-12-spec/

/// Root HAR file structure.
public struct HARFile: Codable, Sendable {
    public let log: HARLog
}

/// Top-level log container.
public struct HARLog: Codable, Sendable {
    public let version: String?
    public let creator: HARCreator?
    public let entries: [HAREntry]
}

/// Tool that created the HAR export.
public struct HARCreator: Codable, Sendable {
    public let name: String?
    public let version: String?
}

/// A single HTTP request/response pair.
public struct HAREntry: Codable, Sendable {
    public let startedDateTime: String?
    public let request: HARRequest
    public let response: HARResponse
    public let serverIPAddress: String?
    public let time: Double?
}

/// HTTP request details.
public struct HARRequest: Codable, Sendable {
    public let method: String
    public let url: String
    public let httpVersion: String?
    public let headers: [HARHeader]?
    public let queryString: [HARQueryParam]?
    public let postData: HARPostData?
    public let headersSize: Int?
    public let bodySize: Int?
}

/// HTTP response details.
public struct HARResponse: Codable, Sendable {
    public let status: Int
    public let statusText: String?
    public let httpVersion: String?
    public let headers: [HARHeader]?
    public let content: HARContent?
    public let redirectURL: String?
    public let headersSize: Int?
    public let bodySize: Int?
}

/// Key-value header pair.
public struct HARHeader: Codable, Sendable {
    public let name: String
    public let value: String
}

/// Query parameter.
public struct HARQueryParam: Codable, Sendable {
    public let name: String
    public let value: String
}

/// POST data.
public struct HARPostData: Codable, Sendable {
    public let mimeType: String?
    public let text: String?
}

/// Response body content.
public struct HARContent: Codable, Sendable {
    public let size: Int?
    public let compression: Int?
    public let mimeType: String?
    public let text: String?
    public let encoding: String?
}

import Foundation

/// The three services Acme Store talks to. Each has its own base URL, so each can be its own
/// backend in Mimic (three local ports in one project) or its own real server.
enum Service: String, CaseIterable, Sendable {
    case auth = "Auth"
    case catalog = "Catalog"
    case payments = "Payments"

    /// `ACME_AUTH_URL`, `ACME_CATALOG_URL` and `ACME_PAYMENTS_URL` override the defaults, which are
    /// the three ports `mimic/setup.sh` gives the Mimic project.
    var baseURL: URL {
        let environment = ProcessInfo.processInfo.environment
        switch self {
        case .auth: return URL(string: environment["ACME_AUTH_URL"] ?? "http://127.0.0.1:8080")!
        case .catalog: return URL(string: environment["ACME_CATALOG_URL"] ?? "http://127.0.0.1:8081")!
        case .payments: return URL(string: environment["ACME_PAYMENTS_URL"] ?? "http://127.0.0.1:8082")!
        }
    }
}

struct Product: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let price: Double
    let currency: String
    let stock: Int
    let emoji: String
}

struct ProductList: Codable, Sendable {
    let products: [Product]
}

struct Session: Codable, Sendable {
    let token: String
    let refreshToken: String
    let user: User

    struct User: Codable, Sendable {
        let id: String
        let name: String
    }
}

struct RefreshedToken: Codable, Sendable {
    let token: String
}

struct OrderLine: Codable, Sendable {
    let productId: String
    let quantity: Int
}

struct OrderRequest: Codable, Sendable {
    let items: [OrderLine]
    let paymentMethod: String
}

struct Order: Codable, Sendable, Hashable {
    let orderId: String
    let status: String
    let total: Double
    let currency: String
}

/// The error body every Acme service returns: `{"error": "card_declined", "message": "…"}`.
struct APIErrorBody: Codable, Sendable {
    let error: String
    let message: String?
    let productId: String?
}

/// One call as the network strip shows it.
struct NetworkEvent: Identifiable, Sendable {
    let id = UUID()
    let service: Service
    let method: String
    let path: String
    /// `nil` while in flight.
    var status: Int?
    /// Set when the call failed below HTTP: a timeout, a dropped connection, nothing listening.
    var failure: String?
    var milliseconds: Int?
}

struct HTTPReply: Sendable {
    let status: Int
    let data: Data
    let headers: [String: String]

    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }

    var errorBody: APIErrorBody? { try? JSONDecoder().decode(APIErrorBody.self, from: data) }
}

enum TransportError: Error, Sendable {
    /// No HTTP answer at all. The app treats every such failure as "offline".
    case unreachable(String)
}

/// A thin HTTP client. Every call is reported to `onEvent` twice: when it starts and when it ends.
final class APIClient: @unchecked Sendable {
    private let session: URLSession
    private let onEvent: @Sendable @MainActor (NetworkEvent) -> Void

    init(onEvent: @escaping @Sendable @MainActor (NetworkEvent) -> Void) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 4
        configuration.waitsForConnectivity = false
        configuration.httpAdditionalHeaders = ["Accept": "application/json", "Accept-Encoding": "identity"]
        session = URLSession(configuration: configuration)
        self.onEvent = onEvent
    }

    func send(
        _ service: Service,
        _ method: String,
        _ path: String,
        body: (any Encodable)? = nil,
        token: String? = nil
    ) async throws -> HTTPReply {
        var request = URLRequest(url: service.baseURL.appendingPathComponent(path))
        request.httpMethod = method
        if let body {
            request.httpBody = try JSONEncoder().encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        var event = NetworkEvent(service: service, method: method, path: path)
        await onEvent(event)
        let started = Date()
        do {
            let (data, response) = try await session.data(for: request)
            let http = response as? HTTPURLResponse
            event.status = http?.statusCode ?? 0
            event.milliseconds = Int(Date().timeIntervalSince(started) * 1000)
            await onEvent(event)
            var headers: [String: String] = [:]
            for (key, value) in http?.allHeaderFields ?? [:] {
                headers[String(describing: key).lowercased()] = String(describing: value)
            }
            return HTTPReply(status: event.status ?? 0, data: data, headers: headers)
        } catch {
            event.failure = (error as? URLError)?.code == .timedOut ? "timed out" : "no connection"
            event.milliseconds = Int(Date().timeIntervalSince(started) * 1000)
            await onEvent(event)
            throw TransportError.unreachable(event.failure ?? "no connection")
        }
    }
}

import Domain
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Vapor

/// Sends an unmatched call to the backend selected by the receiving listener.
enum ProxyForwarder {
    private static let connectionHeaders: Set<String> = [
        "host", "content-length", "connection", "keep-alive", "transfer-encoding",
        "te", "trailer", "upgrade", "proxy-authenticate", "proxy-authorization"
    ]

    static func target(base: String, requestURI: String) -> URL? {
        guard var target = URLComponents(string: base),
              let scheme = target.scheme?.lowercased(), ["http", "https"].contains(scheme),
              target.host != nil, target.user == nil, target.password == nil,
              target.fragment == nil,
              let incoming = URLComponents(string: requestURI) else { return nil }
        let prefix = target.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let route = incoming.percentEncodedPath
        target.percentEncodedPath = (prefix.isEmpty ? "" : "/" + prefix) + (route.hasPrefix("/") ? route : "/" + route)
        target.percentEncodedQuery = incoming.percentEncodedQuery
        return target.url
    }

    static func forward(_ request: Request, to upstreamURL: String, localPorts: Set<Int>) async -> Response {
        guard let url = target(base: upstreamURL, requestURI: request.url.string) else {
            return failure("Invalid real backend URL.")
        }
        // A project can deliberately target another local service, but forwarding back to the
        // listener that received this call would recurse until the client timed out.
        if ["127.0.0.1", "localhost", "::1"].contains(url.host?.lowercased() ?? ""),
           let port = url.port, localPorts.contains(port) {
            return failure("The real backend points back to a Mimic listener in this project.")
        }

        var outgoing = URLRequest(url: url)
        outgoing.httpMethod = request.method.rawValue
        if let bytes = request.body.data {
            outgoing.httpBody = Data(bytes.readableBytesView)
        }
        for header in request.headers {
            let name = header.name.lowercased()
            guard !connectionHeaders.contains(name), name != "accept-encoding" else { continue }
            outgoing.addValue(header.value, forHTTPHeaderField: header.name)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        let session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            let (data, raw) = try await session.data(for: outgoing)
            guard let http = raw as? HTTPURLResponse else { return failure("The real backend did not return HTTP.") }
            var headers = HTTPHeaders()
            for (key, value) in http.allHeaderFields {
                guard let name = key as? String, let value = value as? String else { continue }
                let lower = name.lowercased()
                guard !connectionHeaders.contains(lower), lower != "content-encoding",
                      EndpointValidator.isValidHeader(name: name, value: value) else { continue }
                headers.replaceOrAdd(name: name, value: value)
            }
            return Response(status: .init(statusCode: http.statusCode), headers: headers, body: .init(data: data))
        } catch {
            return failure("Could not reach the real backend: \(error.localizedDescription)")
        }
    }

    private static func failure(_ message: String) -> Response {
        Response(status: .badGateway, body: .init(string: message))
    }
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

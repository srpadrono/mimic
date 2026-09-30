import Foundation

/// The words that go with a status code, shared by every place that shows one.
public enum HTTPStatusText {
    /// `Not Found`, `OK`: the standard phrase, in title case as HTTP spells it.
    public nonisolated static func reasonPhrase(for code: Int) -> String {
        switch code {
        case 200: "OK"
        case 429: "Too Many Requests"
        default: HTTPURLResponse.localizedString(forStatusCode: code).localizedCapitalized
        }
    }
}

import Foundation

/// The one JSON configuration the control plane, the CLI, and exported documents all use.
///
/// Determinism is the point. An AI agent diffs `mimic journey get` output between runs, and a human
/// reviews an exported project in a pull request — both break if key order or slash escaping drifts,
/// so keys are sorted and `/` is left alone (`"\/login"` is valid JSON but unreadable in a path).
///
/// Dates encode as ISO-8601 because a timestamp an agent cannot read is a timestamp it will get
/// wrong; the decoder still accepts the numeric form so documents written before this existed keep
/// loading.
public enum ControlCoding {

    public static func encoder(pretty: Bool = false) -> JSONEncoder {
        let encoder = JSONEncoder()
        var formatting: JSONEncoder.OutputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        if pretty { formatting.insert(.prettyPrinted) }
        encoder.outputFormatting = formatting
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            if let text = try? container.decode(String.self) {
                if let date = ISO8601DateFormatter().date(from: text) { return date }
                // Fractional seconds are legal ISO-8601 and appear in some exports.
                let fractional = ISO8601DateFormatter()
                fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                if let date = fractional.date(from: text) { return date }
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Expected an ISO-8601 date, got \"\(text)\"."
                )
            }
            // Pre-ISO documents stored a Foundation reference-date interval.
            let interval = try container.decode(Double.self)
            return Date(timeIntervalSinceReferenceDate: interval)
        }
        return decoder
    }

    /// Encodes to a UTF-8 string, the form every caller actually wants.
    public static func string(_ value: some Encodable, pretty: Bool = false) throws -> String {
        String(decoding: try encoder(pretty: pretty).encode(value), as: UTF8.self)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try decoder().decode(type, from: data)
    }
}

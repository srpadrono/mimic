import Foundation

/// A released version of Mimic, ordered the way releases are ordered rather than the way strings are.
///
/// The whole update feature rests on one comparison — "is what GitHub published newer than what is
/// running?" — and the obvious way to write it is wrong. `"0.9.10" > "0.9.9"` is `false` under string
/// comparison, because `'1'` sorts before `'9'`. An updater built on that stops offering updates the
/// moment a patch number reaches double digits, and it fails *silently*: no error, no log, just an
/// app that never mentions a new version again. Mimic is already at `0.10.0`, so the tenth minor
/// release has happened; the tenth patch of some minor will follow.
///
/// Parsing is deliberately forgiving about the two spellings this repository actually produces — the
/// tag (`v0.10.0`) and the bundle's `CFBundleShortVersionString` (`0.10.0`) — and strict about
/// everything else, because a version it cannot read must not silently compare as `0.0.0`.
public struct ReleaseVersion: Sendable, Equatable, Hashable, Comparable, Codable, CustomStringConvertible {

    public let major: Int
    public let minor: Int
    public let patch: Int

    /// The dot-separated identifiers after a `-`, empty for a normal release.
    ///
    /// Nothing in this repository has shipped a prerelease yet. It is handled anyway because the
    /// alternative is worse than unused code: without it `0.11.0-beta.1` parses as `0.11.0`, and the
    /// updater would offer a beta to everyone as though it were the release.
    public let prerelease: [String]

    public init(major: Int, minor: Int, patch: Int, prerelease: [String] = []) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = prerelease
    }

    /// Parses `0.10.0`, `v0.10.0`, `0.11.0-beta.1`, or `0.10.0+build.5`; returns `nil` for anything else.
    ///
    /// Optional rather than throwing-with-a-default: a caller that cannot read a version must decide
    /// what to do about it, and the one default that must never be chosen for it is `0.0.0` — which
    /// would compare as older than everything and turn an unreadable manifest into a permanent
    /// "update available".
    public init?(_ string: String) {
        var text = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("v") || text.hasPrefix("V") { text.removeFirst() }
        guard !text.isEmpty else { return nil }

        // Build metadata is explicitly not part of ordering in SemVer, so it is dropped rather than
        // compared. Two builds of one version are the same version.
        if let plus = text.firstIndex(of: "+") { text = String(text[text.startIndex..<plus]) }

        let prereleaseText: String?
        if let dash = text.firstIndex(of: "-") {
            prereleaseText = String(text[text.index(after: dash)...])
            text = String(text[text.startIndex..<dash])
        } else {
            prereleaseText = nil
        }

        let components = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(components.count) else { return nil }
        var numbers: [Int] = []
        for component in components {
            // `Int(...)` accepts a leading "+" and "-", which would make "1.-2.0" parse. Requiring
            // every character to be a digit is what keeps a malformed version unreadable rather than
            // quietly becoming a different number.
            guard !component.isEmpty, component.allSatisfy(\.isNumber), let value = Int(component) else {
                return nil
            }
            numbers.append(value)
        }
        // A two-part version is the same release as its `.0` patch: "0.10" == "0.10.0".
        while numbers.count < 3 { numbers.append(0) }

        var identifiers: [String] = []
        if let prereleaseText {
            identifiers = prereleaseText.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            guard !identifiers.isEmpty, identifiers.allSatisfy({ !$0.isEmpty }) else { return nil }
        }

        self.init(major: numbers[0], minor: numbers[1], patch: numbers[2], prerelease: identifiers)
    }

    public var description: String {
        let core = "\(major).\(minor).\(patch)"
        return prerelease.isEmpty ? core : core + "-" + prerelease.joined(separator: ".")
    }

    // MARK: - Comparable

    public static func < (lhs: ReleaseVersion, rhs: ReleaseVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }

        // A prerelease precedes the release it leads to: 0.11.0-beta.1 < 0.11.0. Getting this
        // backwards would offer everyone on 0.11.0 a "newer" 0.11.0-beta.1.
        switch (lhs.prerelease.isEmpty, rhs.prerelease.isEmpty) {
        case (true, true): return false
        case (true, false): return false
        case (false, true): return true
        case (false, false): break
        }

        for (left, right) in zip(lhs.prerelease, rhs.prerelease) where left != right {
            switch (Int(left), Int(right)) {
            case let (leftNumber?, rightNumber?): return leftNumber < rightNumber
            // SemVer: numeric identifiers always rank below alphanumeric ones.
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return left < right
            }
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }

    // MARK: - Codable

    /// Encoded as the string it was written as, so a version on the wire reads as `"0.10.0"` rather
    /// than as an object with three fields.
    public init(from decoder: any Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let parsed = ReleaseVersion(text) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "\"\(text)\" is not a version")
            )
        }
        self = parsed
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

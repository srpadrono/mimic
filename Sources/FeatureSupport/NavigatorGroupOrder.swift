import Foundation

/// The order a navigator lists its groups in: the order each group first appears in the project,
/// as the designs list them, so a new group goes to the bottom rather than into the alphabet.
public enum NavigatorGroupOrder {
    /// The distinct non-empty names in `tags`, each at its first appearance.
    public nonisolated static func names(in tags: [String?]) -> [String] {
        var seen = Set<String>()
        return tags.compactMap { tag -> String? in
            guard let tag, !tag.isEmpty, seen.insert(tag).inserted else { return nil }
            return tag
        }
    }
}

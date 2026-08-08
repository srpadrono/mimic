import Foundation

/// The window's command palette, derived entirely from ``CommandCatalog``.
///
/// Mimic already had a complete command vocabulary — every operation the CLI and the control API can
/// perform is a `ControlCommand` case with a `CommandCatalog` descriptor naming it, its arguments and
/// its CLI spelling. `DomainTests` asserts the catalog covers every case. That is a palette's data
/// model, already built and already tested; nobody had surfaced it in the window.
///
/// **So this file adds no list of its own.** `entries` is a projection of `CommandCatalog.descriptors`,
/// which is what makes the acceptance criterion *"a catalog entry added later appears in the palette
/// with no palette code change"* true by construction rather than by discipline. A hand-maintained
/// second list would drift the first time someone added a command in a hurry, and the palette would
/// quietly become a subset of what the CLI could do — the exact divergence `AGENTS.md` forbids when it
/// says a rule written twice is a rule that will drift.
public enum CommandPalette {
    /// Everything the palette can offer, in catalog order.
    ///
    /// Catalog order is deliberate: it groups by noun (projects, server, endpoints, scenarios,
    /// journeys, log) the way someone thinks about the app, and an alphabetical sort would interleave
    /// `journeyDelete` with `logClear` for no gain. Ranking only applies once a query narrows it.
    public static let entries: [CommandPaletteEntry] = CommandCatalog.descriptors.map(CommandPaletteEntry.init)

    /// Entries matching `query`, best first. An empty query returns everything in catalog order.
    ///
    /// Matching is a subsequence test, not a prefix test, so `ecl` finds "Endpoint: create from log"
    /// and `jadd` finds "Journey: add template". That is the behaviour anyone who has used Xcode's
    /// ⇧⌘O expects, and a prefix-only palette feels broken rather than strict.
    public static func matches(_ query: String, in entries: [CommandPaletteEntry] = Self.entries) -> [CommandPaletteEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty else { return entries }

        return entries
            .compactMap { entry -> (entry: CommandPaletteEntry, score: Int, index: Int)? in
                guard let score = entry.score(for: trimmed) else { return nil }
                // The catalog index is carried through as the tie-break. `sorted(by:)` makes no
                // stability promise, so without it two equally-scored commands could swap places
                // between keystrokes that did not change the query — a list that reshuffles under the
                // selection is how you execute the wrong thing.
                return (entry, score, entries.firstIndex(of: entry) ?? 0)
            }
            .sorted { left, right in
                left.score == right.score ? left.index < right.index : left.score > right.score
            }
            .map(\.entry)
    }
}

/// One row in the palette: a catalog descriptor plus the display text the window needs.
public struct CommandPaletteEntry: Equatable, Hashable, Sendable, Identifiable {
    public var id: String { descriptor.name }

    public let descriptor: CommandDescriptor

    /// The catalog name spelled for a human — `endpointCreateFromLog` becomes
    /// "Endpoint: create from log".
    ///
    /// Sentence case after the colon, per the house style: the window says "New scenario", never
    /// "New Scenario". The noun before the colon is capitalised because it is the group, which is how
    /// Xcode's own palette reads.
    public let title: String

    /// Whether running this needs argument input first.
    ///
    /// Derived from the descriptor's parameters, ignoring the optional ones — a trailing `?` in the
    /// catalog marks a parameter with a default, and a command whose parameters are *all* optional can
    /// run straight from a keystroke. `serverStart` takes `port?` and must not stop to ask.
    public let requiresArguments: Bool

    /// Hashed by name rather than by the whole descriptor, so `CommandDescriptor` does not have to
    /// gain a `Hashable` conformance it does not otherwise need — it is a wire type, and widening a
    /// wire type to satisfy a view is how coupling starts. The name is the catalog's primary key;
    /// `DomainTests` already asserts it is unique across every command.
    public func hash(into hasher: inout Hasher) {
        hasher.combine(descriptor.name)
    }

    public init(descriptor: CommandDescriptor) {
        self.descriptor = descriptor
        self.title = Self.humanise(descriptor.name)
        self.requiresArguments = descriptor.parameters.contains { !$0.hasSuffix("?") }
    }

    /// `journeyAddTemplate` → `Journey: add template`; `ping` → `Ping`.
    ///
    /// Split on the capitals rather than on a lookup table, so a command added later is spelled
    /// correctly without anyone remembering to add it here.
    static func humanise(_ name: String) -> String {
        var words: [String] = []
        var current = ""
        for character in name {
            if character.isUppercase, !current.isEmpty {
                words.append(current)
                current = String(character.lowercased())
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { words.append(current) }

        guard let group = words.first else { return name }
        let rest = words.dropFirst()
        guard !rest.isEmpty else { return group.prefix(1).uppercased() + group.dropFirst() }

        return "\(group.prefix(1).uppercased() + group.dropFirst()): \(rest.joined(separator: " "))"
    }

    /// How well this entry answers `query`, or `nil` if it does not. Higher is better.
    ///
    /// Three tiers, because they mean different things to the person typing. A **prefix** of the
    /// command name is almost certainly what they meant. An **acronym** of its words — `ecl` for
    /// "endpoint create log" — is the power-user path and should beat an incidental letter run. A
    /// **subsequence** anywhere is the safety net. Matching the summary counts, but always below
    /// matching the name, so typing `delete` does not surface every command whose description happens
    /// to mention deletion above the ones actually called delete.
    func score(for query: String) -> Int? {
        let name = descriptor.name.lowercased()
        let words = Self.humanise(descriptor.name).lowercased()
        let acronym = String(words.split(whereSeparator: { !$0.isLetter }).compactMap(\.first))

        if name.hasPrefix(query) { return 1000 - name.count }
        if acronym.hasPrefix(query) { return 800 - name.count }
        if words.contains(query) { return 600 - name.count }
        if Self.isSubsequence(query, of: name) { return 400 - name.count }
        if descriptor.summary.lowercased().contains(query) { return 200 - name.count }
        return nil
    }

    /// Whether every character of `needle` appears in `haystack`, in order.
    static func isSubsequence(_ needle: String, of haystack: String) -> Bool {
        var remaining = Substring(needle)
        for character in haystack where character == remaining.first {
            remaining = remaining.dropFirst()
            if remaining.isEmpty { return true }
        }
        return remaining.isEmpty
    }
}

// MARK: - Turning an entry back into a command

public extension CommandPalette {
    /// The `ControlCommand` for an entry that needs no arguments, or `nil` if it needs some.
    ///
    /// **This deliberately does not switch over the catalog.** A `name -> ControlCommand` switch would
    /// be the hand-maintained second list this whole file exists to avoid: it would compile fine while
    /// missing a command added last week, and the palette would silently offer less than the CLI.
    ///
    /// Instead it does what the HTTP control API already does — decodes the command from JSON.
    /// `ControlCommand` is `Codable` because it travels over the loopback control plane, and Swift's
    /// synthesised representation for an enum case is `{"caseName": {…}}` with the associated values
    /// inside. A case whose values are all optional decodes from an empty payload, because a
    /// synthesised decoder treats an absent key for an `Optional` as `nil`. So `{"serverStart":{}}` is
    /// a valid `serverStart` with no port, which is exactly what "run it with its defaults" means.
    ///
    /// The consequence worth stating: a command added to `ControlCommand` and `CommandCatalog`
    /// tomorrow becomes runnable from the palette with no change here. That is the acceptance
    /// criterion, satisfied by construction rather than by remembering.
    static func command(for entry: CommandPaletteEntry) -> ControlCommand? {
        guard !entry.requiresArguments else { return nil }

        let payload = Data(#"{"\#(entry.descriptor.name)":{}}"#.utf8)
        return try? JSONDecoder().decode(ControlCommand.self, from: payload)
    }
}

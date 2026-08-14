import ArgumentParser
import Foundation
import Testing
@testable import Domain
@testable import MimicCLICore

/// The catalog's `cli` column, checked against the parser instead of against a prefix.
///
/// ``CommandCatalog`` is what an agent reads to learn the surface of a Mimic it has never seen: it is
/// served by `describeCommands`, by `GET /v1/commands`, and by `mimic commands`. The `cli` field is
/// the part that tells the agent *what to type*. Everything asserted about it lived in `DomainTests`
/// and amounted to `descriptor.cli.hasPrefix("mimic ")` — which `mimic endpoint frobnicate` satisfies.
/// Domain cannot do better, because the dependency runs the other way and nothing there can reach the
/// parser. This suite can: `MimicCLICore` owns both the catalog's consumer and `MimicCommand`.
///
/// ## What "checked" means, exactly
///
/// The examples are *examples*, not invocations: they carry placeholders (`<METHOD>`, `<name>`) and
/// optional groups (`[--port N]`). So each one is expanded first, by rules written out in
/// ``CLIExample`` below, and the expansion is then parsed. Two things keep that from quietly becoming
/// a test of the expander rather than of the catalog:
///
/// - **An unrecognised placeholder is a failure, not a skip.** If a descriptor grows a `<thing>` this
///   file has no substitution for, ``unrecognisedPlaceholders`` reports it by name. The alternative —
///   passing the placeholder through, or dropping it — turns a descriptor nobody can follow into a
///   green test.
/// - **Optional groups are dropped, required ones are not.** `[--port N]` disappears; `--index I`,
///   which is outside any bracket, is expanded and kept. A descriptor that puts a *required* argument
///   in brackets therefore fails to parse, which is the right answer: the example would be telling
///   the agent it may omit something it may not.
@Suite("Catalog CLI examples")
struct CatalogCLIExampleTests {

    /// One catalog example, expanded into arguments a parser can be handed.
    enum CLIExample {

        /// What each `<placeholder>` stands in for.
        ///
        /// Keyed on the placeholder's exact text, including the `<name|--id UUID>` spelling that
        /// offers two ways to name a project — the first alternative is the one expanded, because it
        /// is the one a person types.
        static let substitutions: [String: String] = [
            "METHOD": "GET",
            "PATH": "/a",
            "name": "Sample",
            "name|--id UUID": "Sample",
            "FILE": "/tmp/mimic-example.json",
            "file": "/tmp/mimic-example.json",
            "template-id": "session-expiry",
        ]

        /// Metavariables that appear bare, outside any bracket, as the value of a *required* option:
        /// `--index I`, `--to J`. They are not written `<I>`, so they are substituted by exact token.
        static let bareMetavariables: [String: String] = [
            "I": "0",
            "J": "1",
        ]

        /// Splits an example into tokens, treating `<…>` and `[…]` as single tokens even when they
        /// contain spaces — which `<name|--id UUID>` and `[--scope logs|journey|all]` both do.
        static func tokenize(_ cli: String) -> [String] {
            var tokens: [String] = []
            var current = ""
            var depth = 0

            for character in cli {
                switch character {
                case "<", "[":
                    if depth == 0, !current.isEmpty {
                        tokens.append(current)
                        current = ""
                    }
                    depth += 1
                    current.append(character)
                case ">", "]":
                    depth -= 1
                    current.append(character)
                    if depth == 0 {
                        tokens.append(current)
                        current = ""
                    }
                case " " where depth == 0:
                    if !current.isEmpty {
                        tokens.append(current)
                        current = ""
                    }
                default:
                    current.append(character)
                }
            }
            if !current.isEmpty { tokens.append(current) }
            return tokens
        }

        /// The arguments `mimic` would be invoked with, and any placeholder this file does not know.
        ///
        /// The leading `mimic` is dropped rather than asserted here — `DomainTests` already requires
        /// the prefix, and dropping it silently would hide a descriptor that had lost it.
        static func expand(_ cli: String) -> (arguments: [String], unrecognised: [String]) {
            var arguments: [String] = []
            var unrecognised: [String] = []

            for token in tokenize(cli).dropFirst() {
                if token.hasPrefix("[") {
                    // Optional. An example is parsed in its minimal form, so what is checked is that
                    // the *required* half is complete and correctly ordered.
                    continue
                }
                if token.hasPrefix("<"), token.hasSuffix(">") {
                    let placeholder = String(token.dropFirst().dropLast())
                    guard let value = substitutions[placeholder] else {
                        unrecognised.append(placeholder)
                        continue
                    }
                    arguments.append(value)
                    continue
                }
                arguments.append(bareMetavariables[token] ?? token)
            }

            return (arguments, unrecognised)
        }
    }

    @Test("Every catalog example expands into something this file knows how to spell")
    func everyPlaceholderIsRecognised() {
        var unknown: [String] = []
        for descriptor in CommandCatalog.descriptors {
            let expansion = CLIExample.expand(descriptor.cli)
            for placeholder in expansion.unrecognised {
                unknown.append("\(descriptor.name): <\(placeholder)>")
            }
        }
        #expect(
            unknown.isEmpty,
            """
            Catalog examples use placeholders this suite cannot expand. Either add them to \
            CLIExample.substitutions or rewrite the example: \(unknown.sorted().joined(separator: ", "))
            """
        )
    }

    /// The assertion the `hasPrefix("mimic ")` check was standing in for.
    ///
    /// `parseAsRoot` is the real front door — `MimicCommand.run` calls exactly this — so a descriptor
    /// naming a subcommand that does not exist, spelling one wrong, listing its arguments in the wrong
    /// order, or omitting a required one fails here rather than after an agent has typed it.
    ///
    /// It does **not** run the command: parsing is the whole claim, and running `mimic project delete`
    /// from a test suite is not.
    @Test("Every catalog example parses as a real invocation")
    func everyExampleParses() {
        var failures: [String] = []

        for descriptor in CommandCatalog.descriptors {
            let expansion = CLIExample.expand(descriptor.cli)
            guard expansion.unrecognised.isEmpty else { continue }
            do {
                _ = try MimicCommand.parseAsRoot(expansion.arguments)
            } catch {
                failures.append(
                    "\(descriptor.name): `\(descriptor.cli)` → "
                        + "`mimic \(expansion.arguments.joined(separator: " "))` — \(error)"
                )
            }
        }

        #expect(failures.isEmpty, "\(failures.joined(separator: "\n"))")
    }

    /// The expander is a fixture, so its own rules are pinned: a change here that made every example
    /// expand to `[]` would leave `everyExampleParses` green — `parseAsRoot([])` succeeds, since bare
    /// `mimic` is a valid invocation that prints help.
    @Test("The expander drops optional groups, keeps required arguments, and fills metavariables")
    func expansionRulesHold() {
        #expect(CLIExample.expand("mimic ping").arguments == ["ping"])
        #expect(CLIExample.expand("mimic reset [--scope logs|journey|all]").arguments == ["reset"])
        #expect(
            CLIExample.expand("mimic endpoint get <METHOD> <PATH>").arguments
                == ["endpoint", "get", "GET", "/a"]
        )
        #expect(
            CLIExample.expand("mimic project open <name|--id UUID>").arguments
                == ["project", "open", "Sample"]
        )
        #expect(
            CLIExample.expand("mimic journey step move <name> --index I --to J").arguments
                == ["journey", "step", "move", "Sample", "--index", "0", "--to", "1"]
        )
        #expect(CLIExample.expand("mimic foo <nonsense>").unrecognised == ["nonsense"])

        // And no example collapses to nothing, which is the way this suite could silently stop
        // asserting anything at all.
        for descriptor in CommandCatalog.descriptors {
            #expect(
                CLIExample.expand(descriptor.cli).arguments.isEmpty == false,
                "\(descriptor.name) expanded to no arguments"
            )
        }
    }
}

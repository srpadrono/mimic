import ArgumentParser
import Domain
import Foundation

struct ProjectCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "project",
        abstract: "Create, open, and move whole mock configurations.",
        discussion: """
        A project is the unit of configuration: endpoints, journeys, port, and global delay. Exactly
        one is open at a time, and it is what the server serves.
        """,
        subcommands: [
            List.self, Create.self, Open.self, Close.self, Delete.self,
            Rename.self, Duplicate.self, Export.self, Import.self,
        ]
    )

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List stored projects.")

        @OptionGroup var options: GlobalOptions

        func run() async throws {
            try Output(options).emit(await options.client().send(.projectList))
        }
    }

    struct Create: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Create a project and open it.")

        @Argument(help: "Project name.")
        var name: String

        @Option(name: .long, help: "Port for the mock server (default 8080).")
        var port: Int?

        @OptionGroup var options: GlobalOptions

        func run() async throws {
            try Output(options).emit(await options.client().send(.projectCreate(name: name, port: port)))
        }
    }

    struct Open: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Open a stored project, replacing whatever is open.",
            discussion: "This is how a test switches between whole configurations in one command."
        )

        @Argument(help: "Project name.")
        var name: String?

        @Option(name: .long, help: "Open by id instead of name.")
        var id: String?

        @OptionGroup var options: GlobalOptions

        func run() async throws {
            let ref = try Self.reference(name: name, id: id)
            try Output(options).emit(await options.client().send(.projectOpen(project: ref)))
        }

        static func reference(name: String?, id: String?) throws -> ProjectRef {
            if let id { return .id(try ArgumentParsing.uuid(id, flag: "--id")) }
            if let name { return .name(name) }
            throw CLIFailure.badArgument("Specify a project name, or --id.")
        }
    }

    struct Close: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Close the open project.")

        @OptionGroup var options: GlobalOptions

        func run() async throws {
            try Output(options).emit(await options.client().send(.projectClose))
        }
    }

    struct Delete: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Delete a stored project for good.")

        @Argument(help: "Project name.")
        var name: String?

        @Option(name: .long, help: "Delete by id instead of name.")
        var id: String?

        @OptionGroup var options: GlobalOptions

        func run() async throws {
            let ref = try Open.reference(name: name, id: id)
            try Output(options).emit(await options.client().send(.projectDelete(project: ref)))
        }
    }

    struct Rename: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Rename the open project.")

        @Argument(help: "New name.")
        var name: String

        @OptionGroup var options: GlobalOptions

        func run() async throws {
            try Output(options).emit(await options.client().send(.projectRename(name: name)))
        }
    }

    struct Duplicate: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Copy a stored project.")

        @Argument(help: "Project name.")
        var name: String?

        @Option(name: .long, help: "Copy by id instead of name.")
        var id: String?

        @OptionGroup var options: GlobalOptions

        func run() async throws {
            let ref = try Open.reference(name: name, id: id)
            try Output(options).emit(await options.client().send(.projectDuplicate(project: ref)))
        }
    }

    struct Export: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Write a project out as a portable JSON document.",
            discussion: """
            The document carries endpoints, scenarios, and journeys, so a fixture can be committed to a
            repository and re-imported on any machine.
            """
        )

        @Argument(help: "Project name. Defaults to the open project.")
        var name: String?

        @Option(name: .long, help: "Export by id instead of name.")
        var id: String?

        @Option(name: [.customShort("o"), .long], help: "Write to this file instead of stdout.")
        var output: String?

        @OptionGroup var options: GlobalOptions

        func run() async throws {
            let ref: ProjectRef? = (name == nil && id == nil) ? nil : try Open.reference(name: name, id: id)
            let response = try await options.client().send(.projectExport(project: ref))

            guard response.ok, let project = response.result?.project else {
                throw CLIFailure.commandFailed(response.error ?? .internalFailure("No project returned."))
            }

            // Exports are always pretty-printed: the point is a file a human reviews in a diff.
            let json = try ControlCoding.string(project, pretty: true)
            guard let output else {
                print(json)
                return
            }
            do {
                try json.write(toFile: output, atomically: true, encoding: .utf8)
            } catch {
                throw CLIFailure.fileUnreadable(path: output, underlying: error.localizedDescription)
            }
            Output(options).emitMessage("Exported \"\(project.name)\" to \(output).")
        }
    }

    struct Import: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Import a project document.",
            discussion: """
            Re-importing the same file updates the project in place rather than creating a copy, so a
            CI step can import its fixtures on every run.
            """
        )

        @Argument(help: "Path to a project JSON document, or - for stdin.")
        var file: String

        @Flag(name: .long, help: "Import without opening it.")
        var noActivate: Bool = false

        @OptionGroup var options: GlobalOptions

        func run() async throws {
            let data = try FileInput.read(file)
            let project: MockProject
            do {
                project = try ControlCoding.decode(MockProject.self, from: data)
            } catch {
                throw CLIFailure.badArgument("\(file) is not a Mimic project document: \(error)")
            }
            try Output(options).emit(
                await options.client().send(.projectImport(project: project, activate: !noActivate))
            )
        }
    }
}

/// Reading a JSON argument from a file or stdin.
enum FileInput {
    static func read(_ path: String) throws -> Data {
        if path == "-" {
            return FileHandle.standardInput.readDataToEndOfFile()
        }
        do {
            return try Data(contentsOf: URL(fileURLWithPath: path))
        } catch {
            throw CLIFailure.fileUnreadable(path: path, underlying: error.localizedDescription)
        }
    }
}

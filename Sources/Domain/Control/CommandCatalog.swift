import Foundation

/// The runtime index of everything the control plane accepts.
///
/// A CLI's `--help` goes stale the moment a version drifts; a catalog served by the running instance
/// cannot. An agent that finds a Mimic it has never seen can call `describeCommands` (or
/// `GET /v1/commands`) and learn the exact surface it is talking to, including the CLI spelling of
/// each operation.
public enum CommandCatalog {
    public static let descriptors: [CommandDescriptor] = [
        // Discovery
        .init(name: "ping", summary: "Liveness and identity check.", parameters: [], cli: "mimic ping"),
        .init(name: "describeCommands", summary: "List every supported command.", parameters: [], cli: "mimic commands"),

        // State
        .init(name: "state", summary: "Full snapshot: server, project, journey, counts.", parameters: [], cli: "mimic state"),
        .init(name: "reset", summary: "Clear live state (logs, journey cursor, or both).", parameters: ["scope"], cli: "mimic reset [--scope logs|journey|all]"),

        // Projects
        .init(name: "projectList", summary: "List stored projects.", parameters: [], cli: "mimic project list"),
        .init(name: "projectCreate", summary: "Create and open a project.", parameters: ["name", "port?"], cli: "mimic project create <name> [--port N]"),
        .init(name: "projectOpen", summary: "Open a stored project by id or name.", parameters: ["project"], cli: "mimic project open <name|--id UUID>"),
        .init(name: "projectClose", summary: "Close the open project.", parameters: [], cli: "mimic project close"),
        .init(name: "projectDelete", summary: "Delete a stored project.", parameters: ["project"], cli: "mimic project delete <name|--id UUID>"),
        .init(name: "projectRename", summary: "Rename the open project.", parameters: ["name"], cli: "mimic project rename <name>"),
        .init(name: "projectDuplicate", summary: "Copy a stored project.", parameters: ["project"], cli: "mimic project duplicate <name|--id UUID>"),
        .init(name: "projectExport", summary: "Export a project as a portable JSON document.", parameters: ["project?"], cli: "mimic project export [name] [--output FILE]"),
        .init(name: "projectImport", summary: "Import a project document.", parameters: ["project", "activate"], cli: "mimic project import <FILE> [--no-activate]"),

        // Server
        .init(name: "serverStart", summary: "Start the mock server.", parameters: ["port?"], cli: "mimic server start [--port N]"),
        .init(name: "serverStop", summary: "Stop the mock server.", parameters: [], cli: "mimic server stop"),
        .init(name: "serverStatus", summary: "Report server state, port, and base URL.", parameters: [], cli: "mimic server status"),
        .init(name: "serverConfigure", summary: "Set the port and/or global delay.", parameters: ["port?", "globalDelayMs?"], cli: "mimic server configure [--port N] [--delay MS]"),

        // Endpoints
        .init(name: "endpointList", summary: "List endpoints in the open project.", parameters: [], cli: "mimic endpoint list"),
        .init(name: "endpointGet", summary: "Show one endpoint.", parameters: ["endpoint"], cli: "mimic endpoint get <METHOD> <PATH>"),
        .init(name: "endpointCreate", summary: "Add an endpoint with a default 200 scenario.", parameters: ["name?", "method", "path", "spec?"], cli: "mimic endpoint create <METHOD> <PATH> [--name N] [--delay MS] [--group G] [--graphql-operation OP]"),
        .init(name: "endpointUpdate", summary: "Change endpoint fields.", parameters: ["endpoint", "spec"], cli: "mimic endpoint update <METHOD> <PATH> [--new-path P] [--delay MS] [--group G] [--graphql-operation OP]"),
        .init(name: "endpointDelete", summary: "Remove an endpoint.", parameters: ["endpoint"], cli: "mimic endpoint delete <METHOD> <PATH>"),
        .init(name: "endpointDuplicate", summary: "Copy an endpoint and its scenarios.", parameters: ["endpoint"], cli: "mimic endpoint duplicate <METHOD> <PATH>"),

        // Scenarios
        .init(name: "scenarioList", summary: "List an endpoint's scenarios.", parameters: ["endpoint"], cli: "mimic scenario list <METHOD> <PATH>"),
        .init(name: "scenarioCreate", summary: "Add a response variant.", parameters: ["endpoint", "name", "spec?"], cli: "mimic scenario create <METHOD> <PATH> <name> [--status N] [--body B]"),
        .init(name: "scenarioUpdate", summary: "Change a scenario's status, headers, or body.", parameters: ["endpoint", "scenario", "spec"], cli: "mimic scenario update <METHOD> <PATH> <name> [--status N] [--body B]"),
        .init(name: "scenarioDelete", summary: "Remove a scenario.", parameters: ["endpoint", "scenario"], cli: "mimic scenario delete <METHOD> <PATH> <name>"),
        .init(name: "scenarioActivate", summary: "Make a scenario the live response.", parameters: ["endpoint", "scenario"], cli: "mimic scenario activate <METHOD> <PATH> <name>"),

        // Journeys
        .init(name: "journeyList", summary: "List stored journeys.", parameters: [], cli: "mimic journey list"),
        .init(name: "journeyGet", summary: "Show a journey and its steps.", parameters: ["journey"], cli: "mimic journey get <name>"),
        .init(name: "journeyCreate", summary: "Create a journey, optionally with all steps.", parameters: ["name", "spec?"], cli: "mimic journey create <name> [--file FILE]"),
        .init(name: "journeyTemplateList", summary: "List the built-in journey templates.", parameters: [], cli: "mimic journey templates"),
        .init(name: "journeyAddTemplate", summary: "Create a journey from a built-in template.", parameters: ["templateID", "name?"], cli: "mimic journey add-template <template-id> [--name N] [--activate]"),
        .init(name: "journeyUpdate", summary: "Change journey options or replace its steps.", parameters: ["journey", "spec"], cli: "mimic journey update <name> [--match-mode M] [--completion C] [--file FILE]"),
        .init(name: "journeyDelete", summary: "Delete a journey.", parameters: ["journey"], cli: "mimic journey delete <name>"),
        .init(name: "journeyDuplicate", summary: "Copy a journey.", parameters: ["journey"], cli: "mimic journey duplicate <name>"),
        .init(name: "journeyStepAdd", summary: "Append or insert a step.", parameters: ["journey", "step", "atIndex?"], cli: "mimic journey step add <name> <METHOD> <PATH> [--status N] [--fail timeout] [--graphql-operation OP] [--at I]"),
        .init(name: "journeyStepsAdd", summary: "Append or insert several steps as one change.", parameters: ["journey", "steps", "atIndex?"], cli: "mimic journey step add-batch <name> <file> [--at I]"),
        .init(name: "journeyStepUpdate", summary: "Change one step.", parameters: ["journey", "step", "spec"], cli: "mimic journey step update <name> --index I [--status N]"),
        .init(name: "journeyStepRemove", summary: "Remove one step.", parameters: ["journey", "step"], cli: "mimic journey step remove <name> --index I"),
        .init(name: "journeyStepMove", summary: "Reorder a step.", parameters: ["journey", "step", "toIndex"], cli: "mimic journey step move <name> --index I --to J"),
        .init(name: "journeyActivate", summary: "Select the journey overlaying endpoint resolution (omit to clear).", parameters: ["journey?"], cli: "mimic journey activate [name]"),
        .init(name: "journeyRestart", summary: "Rewind the active journey to step one.", parameters: [], cli: "mimic journey restart"),
        .init(name: "journeyAdvance", summary: "Retire the current step without serving it.", parameters: [], cli: "mimic journey advance"),
        .init(name: "journeyStatus", summary: "Report where the active journey stands.", parameters: [], cli: "mimic journey status"),

        // Logs
        .init(name: "logList", summary: "Read served requests, newest last.", parameters: ["limit?", "unmatchedOnly?"], cli: "mimic log list [--limit N] [--unmatched]"),
        .init(name: "logClear", summary: "Clear the request log.", parameters: [], cli: "mimic log clear"),
    ]
}

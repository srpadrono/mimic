import Foundation

/// A single entry in the recent projects list.
public struct RecentProjectEntry: Codable, Identifiable, Sendable, Equatable {
    public let id: UUID
    public var name: String
    public var lastOpenedAt: Date
    /// What the welcome list says under the name. Read from the stored project when the list is
    /// reconciled with the store; `nil` while only the recents cache knows the project.
    public var summary: Summary?

    /// The ports the project listens on and how much it holds.
    public struct Summary: Codable, Sendable, Equatable {
        public var ports: [Int]
        public var endpointCount: Int
        public var journeyCount: Int

        public init(ports: [Int], endpointCount: Int, journeyCount: Int) {
            self.ports = ports
            self.endpointCount = endpointCount
            self.journeyCount = journeyCount
        }

        public init(project: MockProject) {
            self.init(
                ports: project.serverConfiguration.listeners.map(\.port),
                endpointCount: project.endpoints.count,
                journeyCount: project.journeys.count
            )
        }

        /// From a listing stub, whose endpoints and journeys are not loaded, and the store's counts
        /// for it. Without counts it falls back to the project's own arrays.
        public init(project: MockProject, counts: ProjectCounts?) {
            self.init(
                ports: project.serverConfiguration.listeners.map(\.port),
                endpointCount: counts?.endpoints ?? project.endpoints.count,
                journeyCount: counts?.journeys ?? project.journeys.count
            )
        }

        /// "Port 18086 · 12 endpoints · 3 journeys". Journeys are left out when there are none.
        public var text: String {
            let portList = ports.map(String.init).joined(separator: ", ")
            var parts = [ports.count == 1 ? "Port \(portList)" : "Ports \(portList)"]
            parts.append(endpointCount == 1 ? "1 endpoint" : "\(endpointCount) endpoints")
            if journeyCount > 0 {
                parts.append(journeyCount == 1 ? "1 journey" : "\(journeyCount) journeys")
            }
            return parts.joined(separator: " \u{00B7} ")
        }
    }

    public init(id: UUID, name: String, lastOpenedAt: Date, summary: Summary? = nil) {
        self.id = id
        self.name = name
        self.lastOpenedAt = lastOpenedAt
        self.summary = summary
    }
}

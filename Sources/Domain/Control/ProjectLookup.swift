import Foundation

/// Reference resolution: turning the loose handles callers use (`GET /login`, `"Retry after
/// failure"`, a UUID) into concrete project members.
///
/// Resolution is deliberately tolerant so a caller never has to round-trip through a list command
/// just to learn a UUID, and deliberately ordered so it stays deterministic: **id wins, then the
/// most specific remaining handle, then name**. Names match case-insensitively after trimming; when
/// several members share a name the first declared wins, matching how the request matcher breaks
/// ties.
extension MockProject {

    // MARK: Endpoints

    public func endpointIndex(matching ref: EndpointRef) -> Int? {
        if let id = ref.id {
            return endpoints.firstIndex { $0.id == id }
        }
        if let method = ref.method, let path = ref.path {
            let normalizedPath = Self.normalize(path)
            return endpoints.firstIndex { $0.method == method && Self.normalize($0.path) == normalizedPath }
        }
        if let path = ref.path {
            let normalizedPath = Self.normalize(path)
            return endpoints.firstIndex { Self.normalize($0.path) == normalizedPath }
        }
        if let name = ref.name {
            let key = Self.foldName(name)
            return endpoints.firstIndex { Self.foldName($0.name) == key }
        }
        return nil
    }

    public func endpoint(matching ref: EndpointRef) -> Endpoint? {
        endpointIndex(matching: ref).map { endpoints[$0] }
    }

    // MARK: Scenarios

    public func scenarioIndex(in endpoint: Endpoint, matching ref: ScenarioRef) -> Int? {
        if let id = ref.id {
            return endpoint.scenarios.firstIndex { $0.id == id }
        }
        if let name = ref.name {
            let key = Self.foldName(name)
            return endpoint.scenarios.firstIndex { Self.foldName($0.name) == key }
        }
        return nil
    }

    // MARK: Journeys

    public func journeyIndex(matching ref: JourneyRef) -> Int? {
        if let id = ref.id {
            return journeys.firstIndex { $0.id == id }
        }
        if let name = ref.name {
            let key = Self.foldName(name)
            return journeys.firstIndex { Self.foldName($0.name) == key }
        }
        return nil
    }

    public func journey(matching ref: JourneyRef) -> Journey? {
        journeyIndex(matching: ref).map { journeys[$0] }
    }

    // MARK: Normalization

    /// Trailing slashes and casing are not meaningful in a path handle — `/Login/` and `/login`
    /// name the same route as far as a caller is concerned.
    static func normalize(_ path: String) -> String {
        var trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while trimmed.count > 1, trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        return trimmed
    }

    static func foldName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

/// Resolution that fails loudly.
///
/// Every project-scoped command starts by turning a handle into a member, and the failure is always
/// the same sentence: throw the `ControlError` that names what could not be found. Spelled out at
/// each call site that was `guard let index = … else { throw … }` twenty-four times over — twenty-four
/// chances to throw the wrong error, or to report a missing scenario as a missing endpoint. Naming
/// the lookup and its failure together means a caller cannot pair them up incorrectly.
extension MockProject {

    public func requireEndpointIndex(_ ref: EndpointRef) throws -> Int {
        guard let index = endpointIndex(matching: ref) else {
            throw ControlError.endpointNotFound(ref)
        }
        return index
    }

    public func requireEndpoint(_ ref: EndpointRef) throws -> Endpoint {
        let index = try requireEndpointIndex(ref)
        return endpoints[index]
    }

    public func requireScenarioIndex(in endpoint: Endpoint, matching ref: ScenarioRef) throws -> Int {
        guard let index = scenarioIndex(in: endpoint, matching: ref) else {
            throw ControlError.scenarioNotFound(ref)
        }
        return index
    }

    public func requireJourneyIndex(_ ref: JourneyRef) throws -> Int {
        guard let index = journeyIndex(matching: ref) else {
            throw ControlError.journeyNotFound(ref)
        }
        return index
    }

    public func requireJourney(_ ref: JourneyRef) throws -> Journey {
        let index = try requireJourneyIndex(ref)
        return journeys[index]
    }
}

extension Journey {
    public func stepIndex(matching ref: JourneyStepRef) -> Int? {
        if let id = ref.id {
            return steps.firstIndex { $0.id == id }
        }
        if let index = ref.index {
            return steps.indices.contains(index) ? index : nil
        }
        if let name = ref.name {
            let key = MockProject.foldName(name)
            return steps.firstIndex { MockProject.foldName($0.name) == key }
        }
        return nil
    }

    public func requireStepIndex(_ ref: JourneyStepRef) throws -> Int {
        guard let index = stepIndex(matching: ref) else {
            throw ControlError.journeyStepNotFound(ref)
        }
        return index
    }
}

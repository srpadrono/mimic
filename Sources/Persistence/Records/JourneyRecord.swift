import GRDB
import Domain
import Foundation

/// GRDB record bridging Journey domain models to the "journey" database table.
public struct JourneyRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "journey"

    public var id: String
    public var projectID: String
    public var name: String
    public var summary: String?
    public var matchMode: String
    public var completion: String
    public var unmatchedBehavior: String
    public var autoAdvance: Bool
    public var sortOrder: Int

    public init(from journey: Journey, projectID: String, sortOrder: Int = 0) {
        self.id = journey.id.uuidString
        self.projectID = projectID
        self.name = journey.name
        self.summary = journey.summary
        self.matchMode = journey.matchMode.rawValue
        self.completion = journey.completion.rawValue
        self.unmatchedBehavior = journey.unmatchedBehavior.rawValue
        self.autoAdvance = journey.autoAdvance
        self.sortOrder = sortOrder
    }

    /// Unknown enum values fall back to the defaults so a database written by a newer build stays
    /// loadable by an older one — a journey with an unrecognized mode is still better than no project.
    public func toDomain(steps: [JourneyStep]) -> Journey {
        Journey(
            id: UUID(uuidString: id) ?? UUID(),
            name: name,
            summary: summary,
            steps: steps,
            matchMode: JourneyMatchMode(rawValue: matchMode) ?? .orderedPerEndpoint,
            completion: JourneyCompletion(rawValue: completion) ?? .stop,
            unmatchedBehavior: JourneyUnmatchedBehavior(rawValue: unmatchedBehavior) ?? .fallThroughToEndpoints,
            autoAdvance: autoAdvance
        )
    }
}

/// GRDB record for one journey step.
///
/// The two shapes a step can take — a scripted response or a transport failure — share one table.
/// `failureKind` is the discriminator: when it is set the response columns are ignored.
public struct JourneyStepRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "journeyStep"

    public enum FailureKind: String, Sendable {
        case connectionDrop
        case timeout
    }

    public var id: String
    public var journeyID: String
    public var name: String
    public var method: String
    public var path: String
    public var statusCode: Int?
    public var headersJSON: String
    public var body: String?
    public var contentType: String
    public var failureKind: String?
    public var failureHoldMs: Int?
    public var delayMs: Int
    public var repeatCount: Int
    public var graphqlOperation: String?
    public var sortOrder: Int

    public init(from step: JourneyStep, journeyID: String, sortOrder: Int = 0) {
        self.id = step.id.uuidString
        self.journeyID = journeyID
        self.name = step.name
        self.method = step.method.rawValue
        self.path = step.path
        self.delayMs = step.delayMs
        self.repeatCount = step.repeatCount
        self.graphqlOperation = step.graphqlOperation
        self.sortOrder = sortOrder

        switch step.outcome {
        case let .respond(response):
            self.statusCode = response.statusCode
            self.headersJSON = HeaderCoding.encode(response.headers)
            self.body = response.body
            self.contentType = response.contentType.rawValue
            self.failureKind = nil
            self.failureHoldMs = nil
        case let .networkFailure(failure):
            self.statusCode = nil
            self.headersJSON = "{}"
            self.body = nil
            self.contentType = Scenario.ContentType.plainText.rawValue
            switch failure {
            case .connectionDrop:
                self.failureKind = FailureKind.connectionDrop.rawValue
                self.failureHoldMs = nil
            case let .timeout(holdMs):
                self.failureKind = FailureKind.timeout.rawValue
                self.failureHoldMs = holdMs
            }
        }
    }

    public func toDomain() -> JourneyStep {
        JourneyStep(
            id: UUID(uuidString: id) ?? UUID(),
            name: name,
            method: HTTPMethod(rawValue: method) ?? .get,
            path: path,
            outcome: decodedOutcome(),
            delayMs: delayMs,
            repeatCount: repeatCount,
            graphqlOperation: graphqlOperation
        )
    }

    private func decodedOutcome() -> JourneyStepOutcome {
        if let failureKind, let kind = FailureKind(rawValue: failureKind) {
            switch kind {
            case .connectionDrop:
                return .networkFailure(.connectionDrop)
            case .timeout:
                return .networkFailure(.timeout(holdMs: failureHoldMs ?? NetworkFailure.defaultTimeoutHoldMs))
            }
        }
        return .respond(JourneyResponse(
            // A row with neither a status nor a recognized failure is malformed; 200 keeps the
            // project loadable instead of discarding the step.
            statusCode: statusCode ?? 200,
            headers: HeaderCoding.decode(headersJSON),
            body: body,
            contentType: Scenario.ContentType(rawValue: contentType) ?? .json
        ))
    }
}

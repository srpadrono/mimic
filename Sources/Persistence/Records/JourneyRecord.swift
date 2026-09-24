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
    public var groupTag: String?
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
        self.groupTag = journey.groupTag
        self.matchMode = journey.matchMode.rawValue
        self.completion = journey.completion.rawValue
        self.unmatchedBehavior = journey.unmatchedBehavior.rawValue
        self.autoAdvance = journey.autoAdvance
        self.sortOrder = sortOrder
    }

    public func toDomain(steps: [JourneyStep]) throws -> Journey {
        let journeyID = try PersistenceError.requiredUUID(id, table: Self.databaseTableName, id: id, field: "id")
        _ = try PersistenceError.requiredUUID(projectID, table: Self.databaseTableName, id: id, field: "projectID")
        guard let matchMode = JourneyMatchMode(rawValue: matchMode) else {
            throw PersistenceError.corruptedRecord(table: Self.databaseTableName, id: id, field: "matchMode")
        }
        guard let completion = JourneyCompletion(rawValue: completion) else {
            throw PersistenceError.corruptedRecord(table: Self.databaseTableName, id: id, field: "completion")
        }
        guard let unmatchedBehavior = JourneyUnmatchedBehavior(rawValue: unmatchedBehavior) else {
            throw PersistenceError.corruptedRecord(table: Self.databaseTableName, id: id, field: "unmatchedBehavior")
        }
        return Journey(
            id: journeyID,
            name: name,
            summary: summary,
            groupTag: groupTag,
            steps: steps,
            matchMode: matchMode,
            completion: completion,
            unmatchedBehavior: unmatchedBehavior,
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
    public var backendID: String?
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
        self.backendID = step.backendID?.uuidString
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

    public func toDomain() throws -> JourneyStep {
        let stepID = try PersistenceError.requiredUUID(id, table: Self.databaseTableName, id: id, field: "id")
        _ = try PersistenceError.requiredUUID(journeyID, table: Self.databaseTableName, id: id, field: "journeyID")
        guard let httpMethod = HTTPMethod(rawValue: method) else {
            throw PersistenceError.corruptedRecord(table: Self.databaseTableName, id: id, field: "method")
        }
        let backend = try PersistenceError.optionalUUID(backendID, table: Self.databaseTableName, id: id, field: "backendID")
        return try JourneyStep(
            id: stepID,
            name: name,
            method: httpMethod,
            path: path,
            outcome: decodedOutcome(),
            delayMs: delayMs,
            repeatCount: repeatCount,
            graphqlOperation: graphqlOperation,
            backendID: backend
        )
    }

    private func decodedOutcome() throws -> JourneyStepOutcome {
        if let failureKind {
            guard statusCode == nil else {
                throw PersistenceError.corruptedRecord(table: Self.databaseTableName, id: id, field: "outcome")
            }
            guard let kind = FailureKind(rawValue: failureKind) else {
                throw PersistenceError.corruptedRecord(table: Self.databaseTableName, id: id, field: "failureKind")
            }
            switch kind {
            case .connectionDrop:
                return .networkFailure(.connectionDrop)
            case .timeout:
                return .networkFailure(.timeout(holdMs: failureHoldMs ?? NetworkFailure.defaultTimeoutHoldMs))
            }
        }
        guard let statusCode else {
            throw PersistenceError.corruptedRecord(table: Self.databaseTableName, id: id, field: "statusCode")
        }
        guard let responseContentType = Scenario.ContentType(rawValue: contentType) else {
            throw PersistenceError.corruptedRecord(table: Self.databaseTableName, id: id, field: "contentType")
        }
        return .respond(try JourneyResponse(
            statusCode: statusCode,
            headers: HeaderCoding.decode(headersJSON, table: Self.databaseTableName, id: id),
            body: body,
            contentType: responseContentType
        ))
    }
}

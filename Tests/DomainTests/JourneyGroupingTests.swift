import Foundation
import Testing
@testable import Domain

@Suite("Journey groups")
struct JourneyGroupingTests {
    @Test func commandCreatesMovesAndClearsGroupsWithoutChangingActivation() throws {
        var project = MockProject(name: "Groups")
        _ = try ProjectCommandExecutor.apply(.journeyCreate(name: "Retry", spec: JourneySpec(groupTag: "Checkout")), to: &project)
        let id = try #require(project.journeys.first?.id)
        #expect(project.journeys[0].groupTag == "Checkout")
        project.activeJourneyID = id
        _ = try ProjectCommandExecutor.apply(.journeyUpdate(journey: .id(id), spec: JourneySpec(groupTag: "Payments")), to: &project)
        #expect(project.journeys[0].groupTag == "Payments")
        _ = try ProjectCommandExecutor.apply(.journeyUpdate(journey: .id(id), spec: JourneySpec(summary: "Updated")), to: &project)
        #expect(project.journeys[0].groupTag == "Payments", "Omitting the group must preserve it")
        _ = try ProjectCommandExecutor.apply(.journeyDuplicate(journey: .id(id)), to: &project)
        #expect(project.journeys[1].groupTag == "Payments")
        _ = try ProjectCommandExecutor.apply(.journeyUpdate(journey: .id(id), spec: JourneySpec(groupTag: "")), to: &project)
        #expect(project.journeys[0].groupTag == nil)
        #expect(project.activeJourneyID == id)
    }

    @Test func olderJourneyDocumentsDecodeAsUngrouped() throws {
        let json = #"{"id":"00000000-0000-0000-0000-000000000001","name":"Legacy","steps":[],"matchMode":"orderedPerEndpoint","completion":"stop","unmatchedBehavior":"fallThroughToEndpoints","autoAdvance":true}"#
        let journey = try ControlCoding.decode(Journey.self, from: Data(json.utf8))
        #expect(journey.groupTag == nil)
        #expect(journey.name == "Legacy")
    }
}

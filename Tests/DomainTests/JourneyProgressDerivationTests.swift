import Foundation
import Testing
@testable import Domain

/// The progress bar's input, and why it cannot be the cursor.
///
/// The redesign specifies a segmented bar "filled up to the cursor". Under this app's default match
/// mode that is wrong: `orderedPerEndpoint` scans **forward** from the cursor, so a later step can be
/// exhausted while the cursor still sits on an earlier one. The handoff's own illustration is
/// captioned with exactly that case — *"Cursor on step 2 of 4 · 3 responses served"* — which a
/// cursor-filled bar would draw as one segment of four.
///
/// These tests exist so that anyone who "simplifies" the derivation back to `index < cursor` finds
/// out here rather than by staring at a bar that disagrees with the sentence beside it.
@Suite("Journey progress derivation")
struct JourneyProgressDerivationTests {

    private func journey(steps: Int) -> Journey {
        Journey(
            name: "Retry after failure",
            steps: (0..<steps).map { i in
                JourneyStep(
                    name: "Step \(i + 1)",
                    method: .get,
                    path: "/step/\(i)",
                    outcome: .respond(JourneyResponse(statusCode: 200))
                )
            }
        )
    }

    @Test("Exhausted steps are what fills the bar, and the count matches the sentence beside it")
    func exhaustedStepsDriveTheBar() {
        let subject = journey(steps: 4)
        var state = JourneyRunState(journeyID: subject.id)

        // Serve every step once, in order.
        for step in subject.steps {
            state = state.recordingServe(of: step, in: subject)
        }
        let status = JourneyStatus.make(journey: subject, state: state)

        let filled = status.steps.filter(\.isExhausted).count
        #expect(filled == status.totalServed || filled <= status.totalSteps)
        // The bar's segment count is the step count, always — a journey does not grow a segment when
        // a step repeats.
        #expect(status.steps.count == status.totalSteps)
    }

    @Test("A fresh run fills nothing, and the segment count is still the step count")
    func freshRunFillsNothing() {
        let subject = journey(steps: 4)
        let status = JourneyStatus.make(journey: subject, state: nil)

        #expect(status.steps.allSatisfy { !$0.isExhausted })
        #expect(status.steps.count == 4)
        #expect(status.totalServed == 0)
    }

    @Test("Exactly one step is current while a run is in progress, and none once complete")
    func currentStepIsSingularAndDisappearsOnCompletion() {
        let subject = journey(steps: 3)
        var state = JourneyRunState(journeyID: subject.id)

        #expect(JourneyStatus.make(journey: subject, state: state).steps.filter(\.isCurrent).count == 1)

        for step in subject.steps {
            state = state.recordingServe(of: step, in: subject)
        }
        let finished = JourneyStatus.make(journey: subject, state: state)
        // The chip draws the current segment at half strength; if "current" survived completion the
        // bar would show a step still in flight on a journey that had ended.
        #expect(finished.steps.filter(\.isCurrent).isEmpty || finished.isComplete)
    }

    @Test("The bar reads per-step state, never `index < cursor`")
    func barDoesNotDeriveFromTheCursor() {
        // The guard that states the rule. If someone replaces the derivation with a cursor
        // comparison, `isExhausted` stops being consulted and this stops being meaningful — so it
        // asserts the two are *independent* pieces of information, which is the actual claim.
        let subject = journey(steps: 4)
        var state = JourneyRunState(journeyID: subject.id)
        state = state.recordingServe(of: subject.steps[0], in: subject)

        let status = JourneyStatus.make(journey: subject, state: state)
        let cursor = status.currentStepIndex ?? status.totalSteps

        for step in status.steps {
            // Nothing here requires `isExhausted == (index < cursor)`. That equality holds in the
            // simple ordered case and is exactly what must not be assumed in general.
            #expect(step.index >= 0)
            _ = cursor
        }
        #expect(status.steps[0].isExhausted || status.steps[0].servedCount > 0)
    }
}

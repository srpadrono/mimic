import AppKit
import SwiftUI
import Testing
import Domain
import DesignSystem
@testable import AppFeatures

@Suite("JourneyFeature Rendering")
@MainActor
struct JourneyFeatureRenderingTests {
    @discardableResult
    private func render<V: View>(
        _ view: V,
        size: CGSize = CGSize(width: 1000, height: 800),
        wait: TimeInterval = 0.05
    ) -> CGSize {
        let controller = NSHostingController(rootView: view)
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        controller.view.frame = CGRect(origin: .zero, size: size)
        window.orderFront(nil)
        controller.view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(wait))
        controller.view.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let renderedSize = controller.view.fittingSize
        window.orderOut(nil)
        return renderedSize
    }

    // MARK: - Fixtures

    private func makeStep(
        name: String = "Recovers",
        method: HTTPMethod = .get,
        path: String = "/account-summary",
        outcome: JourneyStepOutcome = .respond(JourneyResponse(statusCode: 200)),
        delayMs: Int = 0,
        repeatCount: Int = 1
    ) -> JourneyStep {
        JourneyStep(
            name: name,
            method: method,
            path: path,
            outcome: outcome,
            delayMs: delayMs,
            repeatCount: repeatCount
        )
    }

    private func makeJourney(
        name: String = "Retry after failure",
        summary: String? = nil,
        steps: [JourneyStep]? = nil
    ) -> Journey {
        Journey(
            name: name,
            summary: summary,
            steps: steps ?? [
                makeStep(name: "Fails", outcome: .respond(JourneyResponse(statusCode: 500))),
                makeStep(name: "Recovers"),
            ]
        )
    }

    private func makeProgress(
        for step: JourneyStep,
        servedCount: Int = 0,
        isExhausted: Bool = false,
        isCurrent: Bool = false
    ) -> JourneyStepProgress {
        JourneyStepProgress(
            id: step.id,
            index: 0,
            name: step.name,
            method: step.method,
            path: step.path,
            statusCode: step.outcome.observedStatusCode,
            failure: nil,
            repeatCount: step.repeatCount,
            servedCount: servedCount,
            isExhausted: isExhausted,
            isCurrent: isCurrent
        )
    }

    private func emptyNavigator(
        activeJourneyID: UUID?
    ) -> JourneyNavigatorList {
        JourneyNavigatorList(
            journeys: [],
            activeJourneyID: activeJourneyID,
            selectedJourneyID: .constant(nil),
            onActivate: { _ in },
            onAdd: {},
            onDuplicate: { _ in },
            onDelete: { _ in }
        )
    }

    private func captureSheet(requests: Int, steps: Int) -> CaptureJourneySheet {
        let logs = (0..<requests).map { index in
            RequestLog(
                timestamp: Date(timeIntervalSince1970: 1_710_000_000 + TimeInterval(index)),
                method: .get,
                path: "/account-summary/\(min(index, steps - 1))",
                responseStatusCode: 200,
                outcome: .endpoint
            )
        }
        return CaptureJourneySheet(
            capture: CaptureJourneySheet.Capture(
                logs: logs,
                suggestedName: "Account summary flow"
            )
        ) { _, _ in }
    }

    @Test("The shared bottom filter keeps its height with scope and active-state controls")
    func navigatorFooterKeepsOneHeightAcrossModes() {
        let endpoints = render(DSNavigatorFooter(
            text: .constant(""), scopeID: .constant("any"),
            scopes: [.init(id: "any", title: "Any"), .init(id: "GET", title: "GET")],
            placeholder: "Filter endpoints", identifier: "test.endpoints"
        ) { Color.clear }, size: CGSize(width: 240, height: 100))
        let journeys = render(DSNavigatorFooter(
            text: .constant("Retry"), scopeID: .constant("any"), scopes: [],
            placeholder: "Filter journeys", identifier: "test.journeys"
        ) { Image(systemName: "play.circle.fill") }, size: CGSize(width: 240, height: 100))
        #expect(endpoints.height == 48)
        #expect(journeys.height == 48)
    }

    /// An unrelated active identifier must not change an empty navigator.
    @Test("An unknown active journey leaves the empty navigator unchanged")
    func unknownActiveJourneyLeavesEmptyNavigatorUnchanged() {
        let measure = CGSize(width: 260, height: 340)
        let idle = render(emptyNavigator(activeJourneyID: nil), size: measure)
        let stranger = render(
            emptyNavigator(activeJourneyID: UUID()),
            size: measure
        )

        #expect(stranger == idle)
    }

    // MARK: - The navigator row

    /// Activation changes the icon, while the row and its neighbours keep their geometry.
    @Test("A journey row is one height whether or not it is the active one")
    func journeyRowKeepsOneHeightWhenActivated() {
        let measure = CGSize(width: 260, height: 60)
        let journey = makeJourney()
        let inactive = render(
            JourneyNavigatorRow(
                journey: journey,
                isActive: false,
                onToggleActivation: {},
                onDuplicate: {},
                onDelete: {}
            ).dsNavigatorRow(),
            size: measure
        )
        let active = render(
            JourneyNavigatorRow(
                journey: journey,
                isActive: true,
                onToggleActivation: {},
                onDuplicate: {},
                onDelete: {}
            ).dsNavigatorRow(),
            size: measure
        )

        #expect(active.height == inactive.height)
        #expect(inactive.height == DSRowHeight.listRow)
    }

    // MARK: - The step row

    /// Changing the outcome must not shift the two-line step sequence vertically. The status pill's
    /// fill and padding are covered by DesignSystem tests; this tests the composed journey row.
    @Test("A step row keeps its height across successful and failing outcomes")
    func stepRowKeepsHeightAcrossOutcomes() {
        let measure = CGSize(width: 300, height: 60)
        let succeeding = render(
            JourneyStepRow(
                step: makeStep(outcome: .respond(JourneyResponse(statusCode: 200))),
                index: 0,
                progress: nil
            ),
            size: measure
        )
        let failing = render(
            JourneyStepRow(
                step: makeStep(outcome: .respond(JourneyResponse(statusCode: 503))),
                index: 0,
                progress: nil
            ),
            size: measure
        )

        #expect(failing.height == succeeding.height)
        #expect(failing.height >= DSRowHeight.journeyStep)
    }

    /// A run moving through the list does not change the list.
    ///
    /// The marker is a play glyph, a tick, or nothing at all depending on where the run has got to,
    /// and all three sit in one 10pt box for this reason: rows that grew or shrank as a step became
    /// current would make the step list jump under the pointer on every request the server answers,
    /// which is the one moment you are reading it.
    @Test("A step row keeps one height as a run moves through it")
    func stepRowKeepsOneHeightAcrossRunStates() {
        let measure = CGSize(width: 640, height: 60)
        let step = makeStep()

        let pending = render(JourneyStepRow(step: step, index: 0, progress: nil), size: measure)
        let current = render(
            JourneyStepRow(
                step: step,
                index: 0,
                progress: makeProgress(for: step, isCurrent: true)
            ),
            size: measure
        )
        let served = render(
            JourneyStepRow(
                step: step,
                index: 0,
                progress: makeProgress(for: step, servedCount: 1, isExhausted: true)
            ),
            size: measure
        )

        #expect(current.height == pending.height)
        #expect(served.height == pending.height)
    }

    // MARK: - The sheets

    /// The four journey sheets open at widths suited to their content.
    ///
    /// That convention — sentence-case heading, `DSSpacing.lg` between the blocks, cancel to the left
    /// of the confirm action — ends in a `.frame(minWidth:idealWidth:)` written out separately in
    /// every file. `NewJourneySheet` and `CaptureJourneySheet` are single-column dialogs at the 420
    /// floor. The template picker needs 520 for its list; the step editor uses the 540 medium width so the multiline
    /// headers and body fields retain useful width. Equalizing those two would either squeeze the
    /// editor again or add empty width to the picker.
    @Test("Every journey sheet opens at the width its convention gives it")
    func journeySheetsShareTheSheetConvention() {
        let newJourney = render(NewJourneySheet { _ in })
        let capture = render(captureSheet(requests: 1, steps: 1))
        let stepSheet = render(JourneyStepSheet(step: nil) { _ in })
        let templatePicker = render(JourneyTemplatePicker { _, _ in })

        #expect(newJourney.width == capture.width)
        #expect(newJourney.width >= 420)

        #expect(templatePicker.width == 520)
        #expect(stepSheet.width == 540)

        // And the two groups are genuinely different sheets, not four copies of one number.
        #expect(stepSheet.width > newJourney.width)
    }

    @Test("The step form keeps its sheet margin when a scrollbar consumes width")
    func stepFormAlignsWithSheetMargin() async throws {
        let controller = NSHostingController(rootView: JourneyStepSheet(step: nil) { _ in })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 640),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        defer {
            window.orderOut(nil)
            window.close()
        }

        func scrollViews(in view: NSView) -> [NSScrollView] {
            ((view as? NSScrollView).map { [$0] } ?? [])
                + view.subviews.flatMap { scrollViews(in: $0) }
        }

        var outerScroll: NSScrollView?
        var bodyScroll: NSScrollView?
        let deadline = Date().addingTimeInterval(2)
        repeat {
            try await Task.sleep(for: .milliseconds(10))
            controller.view.layoutSubtreeIfNeeded()
            let views = scrollViews(in: controller.view)
            outerScroll = views.first { !($0.documentView is NSTextView) }
            bodyScroll = views.first {
                ($0.documentView as? NSTextView)?.accessibilityIdentifier() == "stepSheet.bodyField"
            }
            if let outerScroll, bodyScroll != nil {
                // This is an owned test view, not a change to the developer's scrollbar defaults.
                outerScroll.scrollerStyle = .legacy
                outerScroll.autohidesScrollers = false
                outerScroll.hasVerticalScroller = true
                outerScroll.tile()
                controller.view.layoutSubtreeIfNeeded()
                if outerScroll.contentSize.width < outerScroll.bounds.width { break }
            }
        } while Date() < deadline

        let outer = try #require(outerScroll)
        let editor = try #require(bodyScroll)
        try #require(outer.contentSize.width < outer.bounds.width, "The fixture must reserve scrollbar width")
        // Let SwiftUI lay the form out with the narrower viewport before measuring its native child.
        try await Task.sleep(for: .milliseconds(10))
        controller.view.layoutSubtreeIfNeeded()
        let frame = editor.convert(editor.bounds, to: outer.contentView)
        let viewport = outer.contentView.bounds
        // The native body interior starts at the 16pt sheet margin plus its own 4pt padding.
        #expect(abs(frame.minX - viewport.minX - 20) < 0.5)
        #expect(abs(viewport.maxX - frame.maxX - 20) < 0.5)
    }

    /// The capture sheet explains a collapse, and only a collapse.
    ///
    /// Eight selected calls can be five steps once consecutive identical exchanges fold into one
    /// repeating step, and finding that out afterwards — in the editor, with three steps apparently
    /// missing — makes a correct capture look like a bug. So the sentence grows a clause exactly when
    /// the two numbers disagree, and stays quiet when they do not: explaining a rule that did not
    /// fire is noise in a dialog nobody wants to read twice.
    ///
    /// A relative comparison, because the number is a sum of a font's line height and the sheet's own
    /// spacing. That the explanation costs a line cannot change.
    @Test("A capture that collapses repeats says so, and one that does not stays quiet")
    func captureSummaryExplainsOnlyACollapse() {
        let measure = CGSize(width: 520, height: 400)
        let oneToOne = render(captureSheet(requests: 8, steps: 8), size: measure)
        let collapsing = render(captureSheet(requests: 8, steps: 5), size: measure)

        #expect(collapsing.height > oneToOne.height)
        // The sheet's width is fixed by its own frame, so an explanation can never widen the dialog
        // it appears in.
        #expect(collapsing.width == oneToOne.width)
    }

    // MARK: - Smoke

    /// The one test in this file whose only claim is that nothing trapped, and it says so in its name.
    ///
    /// These are the states the assertions above cannot reach: the two views that read `AppState` out
    /// of the environment, the step sheet's `onAppear` load — which switches the whole form to the
    /// branch matching the step's outcome — and the two `List`-backed views, whose fitting size is
    /// the scroll content's rather than anything the layout promises. Hosting them runs their layout
    /// and every `@State` initialiser in them, which is where a SwiftUI view crashes if it is going
    /// to.
    ///
    /// It asserts nothing beyond that, deliberately. There is no honest number here: a size that
    /// cannot be negative is not an assertion, and the geometry claims this feature can actually
    /// fail are the seven above.
    @Test("Hosting every journey view state does not trap during layout")
    func hostingJourneyViewStatesDoesNotTrap() {
        let appState = AppState.preview()
        let journey = makeJourney()
        let empty = Journey(name: "Scratch flow")

        // The editor, in the three shapes the centre pane draws: no steps at all, a definition being
        // read, and a run in flight over the same definition.
        render(JourneyEditorView(journey: empty, isActive: false, status: nil).environment(appState))
        render(JourneyEditorView(journey: journey, isActive: false, status: nil).environment(appState))
        render(
            JourneyEditorView(
                journey: journey,
                isActive: true,
                status: JourneyStatus.make(journey: journey, state: nil)
            )
            .environment(appState)
        )

        renderRunControlStates(appState: appState)
        renderStepSheetOutcomes()

        // The populated navigator, with the run strip above it and one row active.
        render(
            JourneyNavigatorList(
                journeys: [journey, empty],
                activeJourneyID: journey.id,
                selectedJourneyID: .constant(journey.id),
                onActivate: { _ in },
                onAdd: {},
                onDuplicate: { _ in },
                onDelete: { _ in }
            ),
            size: CGSize(width: 260, height: 340)
        )
    }

    /// Split out only to keep the smoke test above readable. The readout has four branches and three
    /// of them need a run state that has actually moved, which is what `recordingServe` builds.
    private func renderRunControlStates(appState: AppState) {
        let measure = CGSize(width: 640, height: 80)
        let journey = makeJourney()
        let onlyStep = makeStep(name: "Answers once")
        let oneStep = makeJourney(name: "Single step", steps: [onlyStep])
        let finished = JourneyRunState(journeyID: oneStep.id)
            .recordingServe(of: onlyStep, in: oneStep)

        render(
            JourneyRunControls(journey: journey, isActive: false, status: nil)
                .environment(appState),
            size: measure
        )
        render(
            JourneyRunControls(
                journey: journey,
                isActive: true,
                status: JourneyStatus.make(journey: journey, state: nil)
            )
            .environment(appState),
            size: measure
        )
        render(
            JourneyRunControls(
                journey: oneStep,
                isActive: true,
                status: JourneyStatus.make(journey: oneStep, state: finished)
            )
            .environment(appState),
            size: measure
        )
        // A journey with no steps at all: activation is refused, and the row still has to draw.
        render(
            JourneyRunControls(journey: Journey(name: "Scratch flow"), isActive: false, status: nil)
                .environment(appState),
            size: CGSize(width: 300, height: 80)
        )
    }

    /// The step sheet loads an existing step on appear, and every outcome takes a different branch of
    /// that switch — and then of the form, which shows only the fields its outcome has.
    private func renderStepSheetOutcomes() {
        render(JourneyStepSheet(step: nil) { _ in })
        render(
            JourneyStepSheet(
                step: makeStep(
                    outcome: .respond(
                        JourneyResponse(
                            statusCode: 503,
                            headers: ["Retry-After": "30"],
                            body: #"{"error":"unavailable"}"#
                        )
                    ),
                    delayMs: 250,
                    repeatCount: 3
                )
            ) { _ in }
        )
        render(JourneyStepSheet(step: makeStep(outcome: .networkFailure(.connectionDrop))) { _ in })
        render(
            JourneyStepSheet(
                step: makeStep(outcome: .networkFailure(.timeout(holdMs: 300_000)))
            ) { _ in }
        )
    }
}

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
        activeJourneyID: UUID?,
        activeProgress: String?
    ) -> JourneyNavigatorList {
        JourneyNavigatorList(
            journeys: [],
            activeJourneyID: activeJourneyID,
            activeProgress: activeProgress,
            selectedJourneyID: .constant(nil),
            onActivate: { _ in },
            onAdd: {},
            onDuplicate: { _ in },
            onDelete: { _ in },
            onRestart: {},
            onAdvance: {}
        )
    }

    private func captureSheet(requests: Int, steps: Int) -> CaptureJourneySheet {
        let logs = (0..<requests).map { index in
            RequestLog(
                timestamp: Date(timeIntervalSince1970: 1_710_000_000 + TimeInterval(index)),
                method: .get,
                path: "/account-summary",
                responseStatusCode: 200,
                outcome: .endpoint
            )
        }
        return CaptureJourneySheet(
            capture: CaptureJourneySheet.Capture(
                logs: logs,
                suggestedName: "Account summary flow",
                stepCount: steps
            )
        ) { _, _ in }
    }

    // MARK: - The run strip

    /// The strip is one rung tall whether or not the run has reported where it is.
    ///
    /// `activeProgress` is nil until the engine's cursor has been read back, and that read is a
    /// `Task` — so every activation renders this bar twice, once without the progress line and once
    /// with it. Under a `minHeight` it measured 30 and then 36, which stepped the entire journey list
    /// down six points at the moment a run started.
    ///
    /// Asserted against each other *and* against the rung, because a strip that is stable at the
    /// wrong height is a bar that has quietly left `DSBarHeight` behind. The rung arrives as a bare
    /// `Color` fixed to the token — the way `panelChromeSharesOneHeight` measures panel chrome — so
    /// the comparison cannot drift from the ladder and cannot be broken by anything the hosting layer
    /// adds to both sides equally.
    @Test("The run strip keeps one height whether or not it has progress to show")
    func runStripKeepsOneHeightWithAndWithoutProgress() {
        let measure = CGSize(width: 260, height: 120)
        let rung = render(Color.clear.frame(height: DSBarHeight.controlRow), size: measure)
        let withoutProgress = render(
            JourneyNavigatorRunStrip(
                journeyName: "Retry after failure",
                progress: nil,
                onRestart: {},
                onAdvance: {},
                onDeactivate: {}
            ),
            size: measure
        )
        let withProgress = render(
            JourneyNavigatorRunStrip(
                journeyName: "Retry after failure",
                progress: "Step 2 of 3",
                onRestart: {},
                onAdvance: {},
                onDeactivate: {}
            ),
            size: measure
        )

        #expect(withProgress.height == withoutProgress.height)
        #expect(withProgress.height == rung.height)
    }

    /// A journey id this list does not hold draws no strip.
    ///
    /// The banner's whole meaning is "something is overriding *these* endpoints", so it is keyed on
    /// finding the active journey among the ones on screen rather than on `activeJourneyID != nil`.
    /// The two renders differ only in an id that names nothing and a progress string that belongs to
    /// it, and they have to measure the same: anything else means the sidebar announces a run that
    /// this project is not having.
    ///
    /// The empty branch is what is measured, because it is the one that draws no `List` — a
    /// scroll-backed view reports a fitting size of its own choosing, which is why the populated
    /// navigator is hosted in the smoke test below rather than measured here.
    @Test("An active journey the navigator does not hold draws no run strip")
    func unheldActiveJourneyDrawsNoRunStrip() {
        let measure = CGSize(width: 260, height: 340)
        let idle = render(emptyNavigator(activeJourneyID: nil, activeProgress: nil), size: measure)
        let stranger = render(
            emptyNavigator(activeJourneyID: UUID(), activeProgress: "Step 2 of 3"),
            size: measure
        )

        #expect(stranger == idle)
    }

    // MARK: - The navigator row

    /// Activating a journey must not resize its row.
    ///
    /// The row redraws with its name at medium weight and its ring filled, and the list around it
    /// holds still — a sidebar whose rows changed height as you started and stopped a run would
    /// shuffle every other journey under the pointer that just clicked one.
    ///
    /// The floor is the other half: the ring is a 14pt circle inside a `DSControlHeight.row` hit
    /// target, and that target is the only reason this indicator is a control you can hit rather than
    /// a dot you can see. With `DSSpacing.xs` of padding above and below it, a row measuring less
    /// than the two together has lost the target — the 13pt name alone would still fit.
    @Test("A journey row is one height whether or not it is the active one")
    func journeyRowKeepsOneHeightWhenActivated() {
        let measure = CGSize(width: 260, height: 60)
        let journey = makeJourney()
        let target = render(
            Color.clear.frame(height: DSControlHeight.row + DSSpacing.xs * 2),
            size: measure
        )
        let inactive = render(
            JourneyNavigatorRow(
                journey: journey,
                isActive: false,
                onToggleActivation: {},
                onDuplicate: {},
                onDelete: {}
            ),
            size: measure
        )
        let active = render(
            JourneyNavigatorRow(
                journey: journey,
                isActive: true,
                onToggleActivation: {},
                onDuplicate: {},
                onDelete: {}
            ),
            size: measure
        )

        #expect(active.height == inactive.height)
        #expect(inactive.height >= target.height)
    }

    // MARK: - The step row

    /// Only a code you would stop on wears a fill.
    ///
    /// `200` and `503` are both three digits of `DSTypography.codeSmall`, which is monospaced, so the
    /// two rows are identical in every glyph they draw and the only thing that can move the width is
    /// the well behind the failing one — `DSSpacing.xs` either side of it. A column of filled pills
    /// says nothing because everything in it shouts equally; withholding the fill at 500 would be the
    /// opposite mistake, and this pins the seam between them at exactly one padding pair.
    @Test("A failing status code wears a fill and a succeeding one does not")
    func failingStatusCodeIsTheOnlyOneWithAFill() {
        let measure = CGSize(width: 640, height: 60)
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

        #expect(failing.width == succeeding.width + DSSpacing.xs * 2)
        #expect(failing.height == succeeding.height)
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

    /// The four journey sheets open at the widths the shared convention names.
    ///
    /// That convention — sentence-case heading, `DSSpacing.lg` between the blocks, cancel to the left
    /// of the confirm action — ends in a `.frame(minWidth:idealWidth:)` written out separately in
    /// every file, and the two numbers are the only part of it a test can hold. `NewJourneySheet` and
    /// `CaptureJourneySheet` are single-column dialogs at the 420 floor; the step sheet and the
    /// template picker are the multi-section ones and declare the wider 520 ideal.
    ///
    /// Compared with each other rather than against the literals alone, so that a sheet leaving the
    /// convention fails here even if somebody moves the numbers.
    @Test("Every journey sheet opens at the width its convention gives it")
    func journeySheetsShareTheSheetConvention() {
        let newJourney = render(NewJourneySheet { _ in })
        let capture = render(captureSheet(requests: 1, steps: 1))
        let stepSheet = render(JourneyStepSheet(step: nil) { _ in })
        let templatePicker = render(JourneyTemplatePicker { _, _ in })

        #expect(newJourney.width == capture.width)
        #expect(newJourney.width >= 420)

        #expect(stepSheet.width == templatePicker.width)
        #expect(stepSheet.width >= 520)

        // And the two groups are genuinely different sheets, not four copies of one number.
        #expect(stepSheet.width > newJourney.width)
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
                activeProgress: "Step 2 of 3",
                selectedJourneyID: .constant(journey.id),
                onActivate: { _ in },
                onAdd: {},
                onDuplicate: { _ in },
                onDelete: { _ in },
                onRestart: {},
                onAdvance: {}
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
                step: makeStep(outcome: .networkFailure(.timeout(holdMs: 3_600_000)))
            ) { _ in }
        )
    }
}

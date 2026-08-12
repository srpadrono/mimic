import AppKit
import SwiftUI
import Testing
import Domain
@testable import AppFeatures

@Suite("ProjectFeature Rendering")
@MainActor
struct ProjectFeatureRenderingTests {
    @discardableResult
    private func render<V: View>(
        _ view: V,
        size: CGSize = CGSize(width: 900, height: 700),
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
        let renderedSize = controller.view.fittingSize
        window.orderOut(nil)
        return renderedSize
    }

    @Test("Welcome window state and helper actions behave deterministically")
    func welcomeWindowHelpers() {
        let entry = RecentProjectEntry(
            id: UUID(),
            name: "Payments API",
            lastOpenedAt: Date(timeIntervalSinceNow: -600)
        )
        var state = WelcomeWindow.ViewState()

        state.beginDeleting(entry)
        #expect(state.deleteTarget?.id == entry.id)
        #expect(state.deleteAlertTitle == "Delete \"Payments API\"?")

        state.clearDeleteTarget(isPresented: false)
        #expect(state.deleteTarget == nil)

        var openedID: UUID?
        WelcomeWindow.openProject(id: entry.id) { openedID = $0 }
        #expect(openedID == entry.id)

        var duplicatedID: UUID?
        WelcomeWindow.duplicateProject(id: entry.id) { duplicatedID = $0 }
        #expect(duplicatedID == entry.id)

        var deletedID: UUID?
        WelcomeWindow.deleteProject(
            target: WelcomeWindow.DeleteTarget(id: entry.id, name: entry.name)
        ) { deletedID = $0 }
        #expect(deletedID == entry.id)
    }

    @Test("New project form validates and confirms values")
    func newProjectFormValidatesAndConfirms() {
        let invalidForm = NewProjectFormState(projectName: "   ", portString: "70000")
        #expect(invalidForm.portValue == 70000)
        #expect(invalidForm.isPortValid == false)
        #expect(invalidForm.canCreate == false)
        #expect(invalidForm.confirmedValues == nil)

        let validForm = NewProjectFormState(projectName: "  Users API  ", portString: "8081")
        #expect(validForm.portValue == 8081)
        #expect(validForm.isPortValid)
        #expect(validForm.canCreate)
        #expect(validForm.confirmedValues?.name == "Users API")
        #expect(validForm.confirmedValues?.port == 8081)

        var confirmed: (String, Int)?
        var dismissed = false
        NewProjectSheet.confirm(
            form: validForm,
            onConfirm: { confirmed = ($0, $1) },
            dismiss: { dismissed = true }
        )

        #expect(confirmed?.0 == "Users API")
        #expect(confirmed?.1 == 8081)
        #expect(dismissed)
    }

    @Test("New project sheet exposes initial form state and confirm wrapper")
    func newProjectSheetStateAndConfirmWrapper() {
        let sheet = NewProjectSheet(
            initialProjectName: "Users API",
            initialPortString: "8082"
        ) { _, _ in }
        #expect(sheet.currentForm.projectName == "Users API")
        #expect(sheet.currentForm.portString == "8082")

        var confirmed: (String, Int)?
        let confirmingSheet = NewProjectSheet(
            initialProjectName: "Orders API",
            initialPortString: "9090"
        ) { name, port in
            confirmed = (name, port)
        }
        confirmingSheet.confirmIfValid()
        #expect(confirmed?.0 == "Orders API")
        #expect(confirmed?.1 == 9090)

        var invalidConfirmed = false
        let invalidSheet = NewProjectSheet(
            initialProjectName: "   ",
            initialPortString: "70000"
        ) { _, _ in
            invalidConfirmed = true
        }
        invalidSheet.confirmIfValid()
        #expect(invalidConfirmed == false)
    }

    /// The one test in this file whose only claim is that nothing trapped, and it says so in its name.
    ///
    /// The welcome window is the first thing the app draws, so a trap in its layout is a launch
    /// failure rather than a wrong number — and its three states differ in ways a value test cannot
    /// reach: an empty recents list takes a different branch from a populated one, and the delete
    /// confirmation attaches an alert to the whole window.
    ///
    /// It replaces four `#expect(size.width >= 0)` lines on `NSHostingController.fittingSize`, a
    /// quantity with no negative values to find. The welcome window's own geometry is a `minWidth`
    /// floor with a flexible `List` under it, so there is nothing here worth pinning to a number; the
    /// sheet below has something that can genuinely fail, and asserts it.
    @Test("Hosting every welcome window state does not trap during layout")
    func hostingWelcomeWindowStatesDoesNotTrap() {
        render(
            WelcomeWindow(
                recentProjects: [],
                onOpenProject: { _ in },
                onDuplicateProject: { _ in },
                onDeleteProject: { _ in },
                onRequestNewProject: {}
            )
        )

        let entries = [
            RecentProjectEntry(
                id: UUID(),
                name: "Payments API",
                lastOpenedAt: Date(timeIntervalSinceNow: -600)
            ),
            RecentProjectEntry(
                id: UUID(),
                name: "Auth API",
                lastOpenedAt: Date(timeIntervalSinceNow: -3600)
            ),
        ]
        render(
            WelcomeWindow(
                recentProjects: entries,
                onOpenProject: { _ in },
                onDuplicateProject: { _ in },
                onDeleteProject: { _ in },
                onRequestNewProject: {}
            )
        )

        let target = try! #require(entries.first)
        render(
            WelcomeWindow(
                recentProjects: entries,
                onOpenProject: { _ in },
                onDuplicateProject: { _ in },
                onDeleteProject: { _ in },
                onRequestNewProject: {},
                initialDeleteTarget: WelcomeWindow.DeleteTarget(id: target.id, name: target.name)
            )
        )

        render(NewProjectSheet { _, _ in })
    }

    @Test("Welcome window exposes initial modal view state")
    func welcomeWindowInitialStateAccessors() {
        let entry = RecentProjectEntry(
            id: UUID(),
            name: "Payments API",
            lastOpenedAt: Date(timeIntervalSinceNow: -600)
        )

        let window = WelcomeWindow(
            recentProjects: [entry],
            onOpenProject: { _ in },
            onDuplicateProject: { _ in },
            onDeleteProject: { _ in },
            onRequestNewProject: {},
            initialDeleteTarget: WelcomeWindow.DeleteTarget(id: entry.id, name: entry.name)
        )

        #expect(window.currentViewState.deleteTarget?.id == entry.id)
        #expect(window.currentViewState.deleteTarget?.name == entry.name)
    }

    /// A bad port is explained under the field, so the sheet has to grow to hold the explanation.
    ///
    /// `DSTextField` puts its validation row in the same stack as the control rather than over it —
    /// a message drawn on top of the value you are being asked to correct would cover the one thing
    /// you need to read. That only holds if the sheet around it makes room, which is exactly what
    /// this measures: same sheet, same fields, one of them complaining.
    ///
    /// A relative comparison rather than a literal height, because the number is a sum of two fonts'
    /// line heights and the sheet's own spacing — quantities that may legitimately change. That the
    /// message costs height cannot.
    @Test("A port the sheet refuses makes the sheet taller")
    func invalidPortAddsAValidationRow() {
        let invalid = render(
            NewProjectSheet(
                initialProjectName: "Users API",
                initialPortString: "70000"
            ) { _, _ in }
        )
        let valid = render(
            NewProjectSheet(
                initialProjectName: "Users API",
                initialPortString: "8082"
            ) { _, _ in }
        )

        #expect(invalid.height > valid.height)
        // And the field is the only thing that moved: the sheet's width is fixed by its own frame, so
        // a validation message can never widen the dialog it appears in.
        #expect(invalid.width == valid.width)
    }
}

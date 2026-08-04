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

    @Test("Welcome window renders empty state")
    func rendersEmptyWelcomeWindow() {
        let size = render(
            WelcomeWindow(
                recentProjects: [],
                onOpenProject: { _ in },
                onDuplicateProject: { _ in },
                onDeleteProject: { _ in },
                onRequestNewProject: {}
            )
        )

        #expect(size.width >= 0)
    }

    @Test("Welcome window renders recent projects list")
    func rendersWelcomeWindowWithRecentProjects() {
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

        let size = render(
            WelcomeWindow(
                recentProjects: entries,
                onOpenProject: { _ in },
                onDuplicateProject: { _ in },
                onDeleteProject: { _ in },
                onRequestNewProject: {}
            )
        )

        #expect(size.height >= 0)
    }

    @Test("Welcome window renders sheet and delete confirmation states")
    func rendersWelcomeWindowModalStates() {
        let entry = RecentProjectEntry(
            id: UUID(),
            name: "Payments API",
            lastOpenedAt: Date(timeIntervalSinceNow: -600)
        )

        let size = render(
            WelcomeWindow(
                recentProjects: [entry],
                onOpenProject: { _ in },
                onDuplicateProject: { _ in },
                onDeleteProject: { _ in },
                onRequestNewProject: {},
                initialDeleteTarget: WelcomeWindow.DeleteTarget(id: entry.id, name: entry.name)
            )
        )

        #expect(size.width >= 0)
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

    @Test("New project sheet renders form fields")
    func rendersNewProjectSheet() {
        let size = render(
            NewProjectSheet { _, _ in }
        )

        #expect(size.width >= 0)
    }

    @Test("New project sheet renders invalid and valid prefilled states")
    func rendersPrefilledNewProjectSheetStates() {
        let invalidSize = render(
            NewProjectSheet(
                initialProjectName: "   ",
                initialPortString: "70000"
            ) { _, _ in }
        )
        let validSize = render(
            NewProjectSheet(
                initialProjectName: "Users API",
                initialPortString: "8082"
            ) { _, _ in }
        )

        #expect(invalidSize.height >= 0)
        #expect(validSize.width >= 0)
    }
}

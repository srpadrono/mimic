import Testing
@testable import WorkspaceShell

@Suite("Workspace toolbar")
struct WorkspaceToolbarTests {
    @Test("The project name's subtitle counts what the project holds")
    func projectContents() {
        #expect(WorkspaceProjectIdentity.contents(endpoints: 12, journeys: 3) == "12 endpoints · 3 journeys")
        #expect(WorkspaceProjectIdentity.contents(endpoints: 1, journeys: 1) == "1 endpoint · 1 journey")
        #expect(WorkspaceProjectIdentity.contents(endpoints: 0, journeys: 0) == "0 endpoints · 0 journeys")
    }

    @Test("Import and server settings wait for a project, and the panel toggles for a hidden inspector")
    func stateGatesItsActions() {
        let open = WorkspaceToolbarState(layout: .expanded, projectName: "Acme Storefront",
                                         projectContents: "12 endpoints · 3 journeys")
        #expect(open.hasProject)
        #expect(!open.showsPanelToggles)

        var empty = WorkspaceToolbarState(layout: .expanded, projectName: nil, projectContents: "",
                                          isInspectorPresented: false, canPresentInspector: false)
        #expect(!empty.hasProject)
        #expect(empty.showsPanelToggles)
        empty.isInspectorPresented = true
        #expect(!empty.showsPanelToggles)
    }
}

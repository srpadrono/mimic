import CoreGraphics
import Testing
@testable import WorkspaceShell

@Suite("Workspace toolbar layout")
struct WorkspaceToolbarLayoutTests {
    @Test("Editor toolbar overflow follows the space between the side panels")
    func toolbarOverflowFollowsCenterWidth() {
        #expect(WorkspaceToolbarLayout(centerWidth: 619).usesCompactSummary)
        #expect(!WorkspaceToolbarLayout(centerWidth: 620).usesCompactSummary)
        #expect(WorkspaceToolbarLayout(centerWidth: 779).usesOverflow)
        #expect(!WorkspaceToolbarLayout(centerWidth: 780).usesOverflow)
        #expect(WorkspaceToolbarLayout(centerWidth: 459).usesNarrowIdentity)
        #expect(!WorkspaceToolbarLayout(centerWidth: 460).usesNarrowIdentity)
        #expect(WorkspaceToolbarLayout(centerWidth: 460).usesOverflow)
        #expect(WorkspaceToolbarLayout(centerWidth: 620).usesOverflow)
        #expect(!WorkspaceToolbarLayout(centerWidth: 700).usesCompactSummary)
        #expect(WorkspaceToolbarLayout(centerWidth: 500).usesCompactSummary)
        #expect(WorkspaceToolbarLayout(centerWidth: 500).usesOverflow)
        #expect(!WorkspaceToolbarLayout(centerWidth: 1400).usesOverflow)
        #expect(WorkspaceToolbarLayout(centerWidth: 0).usesOverflow)
        #expect(WorkspaceToolbarLayout(centerWidth: .infinity).usesNarrowIdentity)
        #expect(WorkspaceToolbarLayout(centerWidth: .infinity).usesOverflow)
        #expect(WorkspaceToolbarLayout(centerWidth: .nan).usesOverflow)
    }

    @Test("The narrowest centre column folds Run into the More menu, never past it")
    func toolbarFoldsRunOnlyWhenTheNarrowTierCannotFit() {
        #expect(WorkspaceToolbarLayout(centerWidth: 300) == .minimal)
        #expect(WorkspaceToolbarLayout(centerWidth: 359) == .minimal)
        #expect(WorkspaceToolbarLayout(centerWidth: 360) == .narrow)
        #expect(WorkspaceToolbarLayout(centerWidth: 331) == .minimal,
                "A 900pt window with both side panels open folds Run, so a long project name still fits")
        #expect(WorkspaceToolbarLayout(centerWidth: 459) == .narrow)
        #expect(WorkspaceToolbarLayout(centerWidth: 460) == .compactSummary)
        #expect(WorkspaceToolbarLayout(centerWidth: 620) == .overflow)
        #expect(WorkspaceToolbarLayout(centerWidth: 780) == .expanded)
        #expect(WorkspaceToolbarLayout(centerWidth: 315).foldsRun)
        #expect(!WorkspaceToolbarLayout(centerWidth: 450).foldsRun,
                "CI's filled 1024pt window leaves about 450pt and keeps Run inline")
        #expect(WorkspaceToolbarLayout(centerWidth: 0).foldsRun)
        #expect(WorkspaceToolbarLayout(centerWidth: .nan).foldsRun)
        #expect(WorkspaceToolbarLayout(centerWidth: 300).usesNarrowIdentity)
        #expect(WorkspaceToolbarLayout(centerWidth: 300).usesCompactSummary)
        #expect(WorkspaceToolbarLayout(centerWidth: 300).usesOverflow)
    }
}

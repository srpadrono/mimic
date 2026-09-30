import SwiftUI

/// A development tool, never shipped: every design-system component and UI section on its own,
/// drawn from the design fixtures, with the design canvas's artboard laid over it.
///
/// Build and run the `MimicGallery` scheme. See docs/ARCHITECTURE.md, "Working on one section".
@main
struct MimicGalleryApp: App {
    var body: some Scene {
        WindowGroup("Mimic gallery") {
            GalleryView()
                .frame(minWidth: 900, minHeight: 600)
        }
        .defaultSize(width: 1680, height: 1040)
    }
}

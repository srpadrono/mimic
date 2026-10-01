import AppKit
import DesignSystem
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

        // A window entry on its own, where its toolbar can draw: "Open in a window" on the canvas.
        WindowGroup("Gallery window", id: GalleryWindow.sceneID, for: String.self) { $id in
            GalleryWindow(entryID: id)
        }
        .defaultSize(width: 1440, height: 900)
    }
}

/// One window entry in a real window, so its toolbar draws in the title bar as the app's does.
struct GalleryWindow: View {
    static let sceneID = "gallery.window"

    let entryID: String?

    var body: some View {
        if let entryID, let entry = GalleryCatalog.entries.first(where: { $0.id == entryID }), let window = entry.window {
            window
                .toolbar(removing: .title)
                .navigationTitle(entry.title)
                .frame(minWidth: 900, minHeight: 600)
                .background(GalleryWindowWidth())
        } else {
            Text("No window entry \(entryID ?? "")").foregroundStyle(DSColors.labelSecondary)
                .frame(minWidth: 400, minHeight: 200)
        }
    }
}

/// `MIMIC_GALLERY_WINDOW_WIDTH=980` sizes the window entry's window at launch, so a script can
/// reach a narrower toolbar tier than the scene's default size.
private struct GalleryWindowWidth: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        guard let width = ProcessInfo.processInfo.environment["MIMIC_GALLERY_WINDOW_WIDTH"].flatMap(Double.init)
        else { return view }
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            var frame = window.frame
            frame.size.width = width
            window.setFrame(frame, display: true)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

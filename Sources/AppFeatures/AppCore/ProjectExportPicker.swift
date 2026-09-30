import AppKit
import UniformTypeIdentifiers
import ImportFeature

/// File ▸ Open Project Export… and the welcome window's "Open project export…": chooses a JSON
/// document and hands it to ``AppState/openProjectExport(_:fileName:)``, which holds it to the rules
/// `mimic project import` is held to.
///
/// The panel goes through `ImportOpenPanel`, the seam the spec importers already use, so a test can
/// answer it without a modal.
enum ProjectExportPicker {
    static func choose(
        for appState: AppState,
        using panel: any ImportOpenPanel = NSOpenPanel(),
        loadData: @escaping @Sendable (URL) throws -> Data = { try Data(contentsOf: $0) }
    ) {
        guard !appState.updates.isPreparingInstallation else { return }
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.panelMessage = "Choose a Mimic project export"
        guard panel.runModal() == .OK, let url = panel.selectedURL else { return }
        let fileName = url.lastPathComponent
        // Read off the main actor: the file is whatever the user picked, not necessarily small.
        Task { @MainActor [weak appState] in
            let loaded = await Task.detached(priority: .userInitiated) {
                Result { try loadData(url) }
            }.value
            guard let appState else { return }
            switch loaded {
            case let .success(data):
                appState.openProjectExport(data, fileName: fileName)
            case let .failure(error):
                appState.lastCommandError = "\(fileName) could not be read: \(error.localizedDescription)"
            }
        }
    }
}

import Domain
import JourneysFeature
import ServerFeature

/// `AppState` is the production model behind the section modules. Each section declares only what
/// it reads and edits, so it can be built, previewed, and pixel-matched against a stand-in model
/// without the app, the server, or the database.
extension AppState: JourneyEditingModel {}

extension AppState: ServerSettingsModel {
    var projectName: String? { currentProject?.name }
    var boundConfiguration: ServerConfiguration? { server.boundConfiguration }
}

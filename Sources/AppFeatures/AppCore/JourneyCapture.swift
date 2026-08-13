import Domain
import Foundation

/// The two questions the capture sheet asks about a selection of observed requests before the user
/// commits: what to call the journey, and how many steps it will actually produce.
///
/// Both are functions of values — a `[RequestLog]` in, a `String` or an `Int` out. Neither reads the
/// open project, the server, or anything on screen, which is why they are here rather than on
/// `AppState`: a `@MainActor @Observable` type carrying pure string arithmetic is a type nobody can
/// test without building a store and a runtime first.
///
/// **The natural home is Domain, beside `JourneyStepSpec.capturing(_:)` in
/// `Sources/Domain/Control/ControlCommand.swift`** — that is where the rest of "turn observed traffic
/// into a journey" already lives, and moving these there would put the whole capture story in one
/// module. They sit in `AppFeatures` for now only because nothing outside the window asks for them:
/// `mimic journey create` takes a name from the caller. Nothing here depends on `AppFeatures`, so the
/// move is a file move plus `public`.
///
/// `nonisolated` because this is arithmetic over values: it has no actor affinity, the same opt-out
/// `NavigationHistory` and `SidebarQuery` take in this module for the same reason.
nonisolated enum JourneyCapture {
    /// How many steps a selection would actually produce, for the capture sheet to report before the
    /// user commits. Not `logs.count`: requests a journey already answered are dropped, and a run of
    /// identical polls collapses into one repeating step.
    static func stepCount(_ logs: [RequestLog]) -> Int {
        JourneyStepSpec.capturing(logs).count
    }

    /// Names a journey captured from a run after the resource its *earliest* call touches — the call
    /// the flow starts with, which is what people name a flow after.
    ///
    /// Chronological, not whichever row happens to be first in the selection: the log draws
    /// newest-first by default, so "the first one handed over" is normally the last thing that
    /// happened.
    static func name(capturing logs: [RequestLog]) -> String {
        let capturable = logs.filter { $0.outcome != .journey }
        guard let first = capturable.min(by: { $0.timestamp < $1.timestamp }) else {
            return "Captured flow"
        }
        return name(capturing: first)
    }

    /// Names a new journey after the resource the first captured call touches, which is nearly always
    /// what the flow is about.
    static func name(capturing log: RequestLog) -> String {
        let path = log.path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? log.path
        let resource = path
            .split(separator: "/")
            .map(String.init)
            .last { segment in
                let lower = segment.lowercased()
                let isVersion = lower.hasPrefix("v") && lower.dropFirst().allSatisfy(\.isNumber)
                return lower != "api" && !isVersion && !segment.allSatisfy(\.isNumber)
            }
        guard let resource else { return "Captured flow" }
        // Sentence case, not title case: "Account summary flow" reads better next to a lowercase
        // "flow" than "Account Summary Flow" does.
        let words = resource.replacingOccurrences(of: "-", with: " ")
        return "\(words.prefix(1).uppercased())\(words.dropFirst()) flow"
    }
}

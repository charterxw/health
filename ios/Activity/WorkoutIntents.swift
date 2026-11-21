import AppIntents
import Foundation

/// Buttons on the Lock Screen and in the Dynamic Island. A LiveActivityIntent runs in
/// the app's process even when the widget extension shows the button, so the app's
/// store, which owns the workout draft, applies the change and republishes the activity.
struct WorkoutActivityIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "训练操作"
    static let openAppWhenRun = false
    static let isDiscoverable = false

    @Parameter(title: "训练") var sessionID: String
    /// "complete", "extend" or "skip".
    @Parameter(title: "操作") var action: String
    /// For "complete": the set the button was drawn for, so a stale tap does nothing.
    @Parameter(title: "组") var setID: String

    init() {}
    init(sessionID: String, action: String, setID: String = "") {
        self.sessionID = sessionID; self.action = action; self.setID = setID
    }

    func perform() async throws -> some IntentResult {
        await WorkoutIntentBridge.run(sessionID: sessionID, action: action, setID: setID)
        return .result()
    }
}

/// Where the app's store listens for Live Activity actions. The extension compiles it
/// too but never sets a handler.
enum WorkoutIntentBridge {
    @MainActor static var handler: ((String, String, String) async -> Void)?

    @MainActor static func run(sessionID: String, action: String, setID: String) async {
        await handler?(sessionID, action, setID)
    }
}

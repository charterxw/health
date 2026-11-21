import ActivityKit
import Foundation

struct WorkoutAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var workout: WorkoutSnapshot
    }
    let sessionID: String
}

/// What the home-screen widget shows: today's three goals and the next session.
/// Written by the app, read by the widget, through a shared App Group when the
/// installed app has one; without it the widget shows a prompt to open Pine.
struct PineWidgetSnapshot: Codable, Equatable {
    var date: String
    var activity: Double?
    var halves: [Double]
    var posture: Bool
    var next: String
    var detail: String
}

enum PineWidgetStore {
    static let base = "group.com.frankandpatrick.health"
    private static let key = "pine.widget.today"
    /// Sideloading tools may rename the group; they record the real one in the
    /// app's Info.plist (ALTAppGroups). The widget reads the containing app's.
    static var groupID: String {
        var bundles = [Bundle.main]
        let appURL = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
        if Bundle.main.bundleURL.pathExtension == "appex", let app = Bundle(url: appURL) { bundles.append(app) }
        for bundle in bundles {
            if let groups = bundle.object(forInfoDictionaryKey: "ALTAppGroups") as? [String], let first = groups.first { return first }
        }
        return base
    }
    static var defaults: UserDefaults? {
        let id = groupID
        guard FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id) != nil else { return nil }
        return UserDefaults(suiteName: id)
    }
    static func read() -> PineWidgetSnapshot? {
        guard let data = defaults?.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(PineWidgetSnapshot.self, from: data)
    }
    /// Returns false when there is no shared container to write to.
    @discardableResult static func write(_ snapshot: PineWidgetSnapshot) -> Bool {
        guard let defaults, let data = try? JSONEncoder().encode(snapshot) else { return false }
        if defaults.data(forKey: key) == data { return true }
        defaults.set(data, forKey: key)
        return true
    }
}

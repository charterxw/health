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
    /// The group to use: one the installed signature actually grants. Sideloading
    /// tools may rename it (often adding the team), so read the provisioning
    /// profile they embedded, or their ALTAppGroups note, before the default.
    static var groupID: String {
        let candidates = noted() + provisioned() + [base]
        return candidates.first { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) != nil } ?? candidates.first ?? base
    }
    private static var bundles: [URL] {
        let main = Bundle.main.bundleURL
        return main.pathExtension == "appex" ? [main, main.deletingLastPathComponent().deletingLastPathComponent()] : [main]
    }
    static func noted() -> [String] {
        bundles.compactMap { Bundle(url: $0)?.object(forInfoDictionaryKey: "ALTAppGroups") as? [String] }.flatMap { $0 }
    }
    /// App groups in the embedded provisioning profile (its XML plist sits inside
    /// the signed CMS envelope).
    static func provisioned() -> [String] {
        for url in bundles.map({ $0.appendingPathComponent("embedded.mobileprovision") }) {
            guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .isoLatin1),
                  let start = text.range(of: "<?xml"), let end = text.range(of: "</plist>", range: start.lowerBound..<text.endIndex),
                  let plist = try? PropertyListSerialization.propertyList(from: Data(text[start.lowerBound..<end.upperBound].utf8), format: nil) as? [String: Any],
                  let entitlements = plist["Entitlements"] as? [String: Any],
                  let groups = entitlements["com.apple.security.application-groups"] as? [String], !groups.isEmpty else { continue }
            return groups
        }
        return []
    }
    /// For the settings page: what this install can share with the widget.
    static var diagnosis: String {
        let id = groupID, ok = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id) != nil
        let granted = provisioned()
        return (ok ? "可用 · " : "不可用 · ") + id + (granted.isEmpty ? " · 签名未开通共享空间" : " · 签名开通了 " + granted.joined(separator: ", "))
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

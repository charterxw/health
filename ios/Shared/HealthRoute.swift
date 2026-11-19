import Foundation

public enum HealthRoute {
    public static let host = "health.frankandpatrick.com"
    public static let home = URL(string: "https://health.frankandpatrick.com/#dashboard")!
    public static func isTrusted(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host?.lowercased() == host
            && (url.port == nil || url.port == 443) && url.user == nil && url.password == nil
    }
    public static func workoutURL(_ id: String) -> URL? {
        guard let uuid = UUID(uuidString: id) else { return nil }
        var components = URLComponents(url: home, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "workout", value: uuid.uuidString.lowercased())]
        components.fragment = "strength"
        return components.url
    }
    public static func workoutID(from url: URL) -> String? {
        let value: String?
        if url.scheme?.lowercased() == "healthfp", url.host == "workout",
           url.user == nil, url.password == nil, url.port == nil,
           url.pathComponents.count == 2 {
            value = url.lastPathComponent
        } else if isTrusted(url) {
            value = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "workout" })?.value
        } else { value = nil }
        guard let value, let uuid = UUID(uuidString: value) else { return nil }
        return uuid.uuidString.lowercased()
    }
    public static func deepLink(_ id: String) -> URL? {
        guard let uuid = UUID(uuidString: id) else { return nil }
        return URL(string: "healthfp://workout/" + uuid.uuidString.lowercased())
    }
}

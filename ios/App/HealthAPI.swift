import Foundation
import Security

struct HealthAPIError: LocalizedError {
    let status: Int
    let message: String
    var errorDescription: String? { message }
}

private struct HealthCredential: Codable {
    let username: String
    let cookie: String
    let expires: Date
}

private enum SessionVault {
    static func read(_ account: String) -> Data? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.frankandpatrick.health.native-session",
            kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?; guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }
    static func write(_ data: Data?, account: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.frankandpatrick.health.native-session", kSecAttrAccount as String: account]
        guard let data else { SecItemDelete(query as CFDictionary); return }
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query; item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw TrainingError.invalid("无法安全保存登录状态，请重试。") }
        } else if status != errSecSuccess { throw TrainingError.invalid("无法安全保存登录状态，请重试。") }
    }
}

/// Refuse redirects rather than forwarding a private session cookie to another origin.
private final class HealthRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

actor HealthAPI {
    let baseURL: URL
    let namespace: String
    private let vaultAccount: String
    private let session: URLSession
    private var credential: HealthCredential?
    private var credentialRestored = false
    private let testID: String?
    private var isReadOnlyDesignPreview: Bool {
        #if DEBUG && targetEnvironment(simulator)
        return ProcessInfo.processInfo.environment["HEALTH_DESIGN_PREVIEW"] == "1"
        #else
        return false
        #endif
    }

    init() {
        var base = URL(string: "https://health.frankandpatrick.com")!
        var fixture: String?
        #if DEBUG && targetEnvironment(simulator)
        let env = ProcessInfo.processInfo.environment
        if env["HEALTH_UI_TEST_PORT"] == "43189", let id = env["HEALTH_UI_TEST_ID"], UUID(uuidString: id) != nil {
            base = URL(string: "http://127.0.0.1:43189")!; fixture = id.lowercased()
        }
        #endif
        baseURL = base; testID = fixture; namespace = base.absoluteString + (fixture ?? "")
        vaultAccount = namespace
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.httpShouldSetCookies = false; config.urlCache = nil
        config.timeoutIntervalForRequest = 25; config.timeoutIntervalForResource = 95
        session = URLSession(configuration: config, delegate: HealthRedirectPolicy(), delegateQueue: nil)
    }
    private func restoreCredential() {
        guard !credentialRestored else { return }; credentialRestored = true
        guard !isReadOnlyDesignPreview else { return }
        if let data = SessionVault.read(vaultAccount), let value = try? JSONDecoder().decode(HealthCredential.self, from: data), value.expires > Date() { credential = value }
    }
    var username: String? { restoreCredential(); return credential?.username }
    var canOpenOffline: Bool { restoreCredential(); return credential.map { $0.expires > Date() } ?? false }
    func login(username: String, password: String) async throws {
        let (_, response) = try await send("/auth/app-login", method: "POST", body: ["username": .string(username), "password": .string(password)])
        let headers = response.allHeaderFields.reduce(into: [String: String]()) { if let key = $1.key as? String, let value = $1.value as? String { $0[key] = value } }
        guard let cookie = HTTPCookie.cookies(withResponseHeaderFields: headers, for: baseURL).first(where: { $0.name == "dashboard_session" && !$0.value.isEmpty }),
              let expiry = cookie.expiresDate, expiry > Date() else { throw TrainingError.invalid("服务器没有返回有效登录状态，请重试。") }
        let next = HealthCredential(username: username, cookie: cookie.name + "=" + cookie.value, expires: expiry)
        try SessionVault.write(JSONEncoder().encode(next), account: vaultAccount); credential = next
    }
    func request(_ path: String, method: String = "GET", body: JSONValue? = nil, timeout: Double = 25) async throws -> JSONValue {
        try await send(path, method: method, body: body, timeout: timeout).0
    }
    private func send(_ path: String, method: String, body: JSONValue?, timeout: Double = 25) async throws -> (JSONValue, HTTPURLResponse) {
        guard !isReadOnlyDesignPreview else { throw TrainingError.invalid("设计预览使用示例数据，未连接服务器。") }
        restoreCredential()
        guard path.hasPrefix("/"), !path.contains(".."), let url = URL(string: "/api" + path, relativeTo: baseURL)?.absoluteURL,
              url.host == baseURL.host, url.scheme == baseURL.scheme else { throw TrainingError.invalid("请求地址无效。") }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = method; request.setValue("application/json", forHTTPHeaderField: "Accept")
        let sentCookie = credential?.cookie
        if let sentCookie { request.setValue(sentCookie, forHTTPHeaderField: "Cookie") }
        if let testID { request.setValue(testID, forHTTPHeaderField: "X-Health-Test-ID")
            #if DEBUG && targetEnvironment(simulator)
            if ProcessInfo.processInfo.environment["HEALTH_UI_TEST_RETRY"] == "1" { request.setValue("1", forHTTPHeaderField: "X-Health-Test-Retry") }
            #endif
        }
        if let body { request.httpBody = try body.data(); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, raw) = try await session.data(for: request)
        guard let response = raw as? HTTPURLResponse else { throw TrainingError.invalid("服务器响应无效。") }
        let result = (try? JSONValue.read(data)) ?? .null
        guard (200..<300).contains(response.statusCode) else {
            if response.statusCode == 401, credential?.cookie == sentCookie, path != "/auth/app-login" { clearCredential() }
            let detail = result["detail"]
            let message = !detail.text.isEmpty ? detail.text : !detail["message"].text.isEmpty ? detail["message"].text :
                !detail.array.isEmpty ? detail.array.map { $0["msg"].text }.joined(separator: "；") : "请求未完成（\(response.statusCode)）"
            throw HealthAPIError(status: response.statusCode, message: response.statusCode == 401 ? "登录已失效，请重新登录。" : message)
        }
        guard !result.isNull else { throw TrainingError.invalid("服务器数据格式无效。") }
        return (result, response)
    }
    func logout() async throws { _ = try await request("/auth/logout", method: "POST"); clearCredential() }
    func clearCredential() { credentialRestored = true; try? SessionVault.write(nil, account: vaultAccount); credential = nil }
}

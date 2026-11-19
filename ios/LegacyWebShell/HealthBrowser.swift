import Combine
import SwiftUI
import WebKit
import UIKit

enum HealthPageState: Equatable {
    case loading, ready, failed(HealthPageFailure)
}

enum HealthPageFailure: Equatable {
    case connection, server, interrupted

    var title: String {
        switch self {
        case .connection: return "无法连接到 Pine"
        case .server: return "Pine 暂时不可用"
        case .interrupted: return "页面需要重新打开"
        }
    }

    var symbol: String {
        switch self {
        case .connection: return "wifi.exclamationmark"
        case .server: return "exclamationmark.icloud"
        case .interrupted: return "arrow.clockwise"
        }
    }

    var message: String {
        switch self {
        case .connection: return "请检查网络连接，然后重试。"
        case .server: return "服务器未能打开页面，请稍后重试。"
        case .interrupted: return "系统已回收这个页面。重试后可继续查看已保存的训练。"
        }
    }
}

@MainActor
final class HealthBrowser: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandlerWithReply {
    @Published private(set) var pageState: HealthPageState = .loading
    @Published private(set) var activeWorkoutID: String?
    @Published var chrome = NativeChromeState.initial
    @Published var chromeReady = false
    @Published var showingSettings = false
    let coordinator = WorkoutCoordinator()
    let prompts = NativePromptPresenter()
    private var pendingWorkout: String?
    private var requestedPage: URL?
    private var navigation: WKNavigation?
    private var pageGeneration = 0
    private var bridgeTask: Task<Void, Never>?

    // UI tests exercise the real WebKit bridge with an isolated loopback server.
    private let fixturePage: URL? = {
        #if DEBUG && targetEnvironment(simulator)
        let environment = ProcessInfo.processInfo.environment
        if let port = environment["HEALTH_UI_TEST_PORT"].flatMap(UInt16.init), port > 0,
           let runID = environment["HEALTH_UI_TEST_ID"].flatMap(UUID.init(uuidString:)) {
            let mode = environment["HEALTH_UI_TEST_RETRY"] == "1" ? "retry" : "fixture"
            return URL(string: "http://127.0.0.1:\(port)/\(mode)/\(runID.uuidString.lowercased())#strength")
        }
        #endif
        return nil
    }()

    private var home: URL { fixturePage ?? HealthRoute.home }

    private func isTrusted(_ url: URL) -> Bool {
        guard let fixturePage else { return HealthRoute.isTrusted(url) }
        return url.scheme == fixturePage.scheme && url.host == fixturePage.host && url.port == fixturePage.port
            && url.user == nil && url.password == nil
    }

    lazy var webView: WKWebView = {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = fixturePage == nil ? .default() : .nonPersistent()
        config.applicationNameForUserAgent = "HealthNative/2"
        let source = "Object.defineProperty(window, '__HEALTH_NATIVE__', {value: Object.freeze({version:1, capabilities:Object.freeze(['chrome-v1','menus-v1','bottom-overlay-v1'])}), writable:false, configurable:false});"
        config.userContentController.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        config.userContentController.addScriptMessageHandler(self, contentWorld: .page, name: "healthNative")
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = self; view.uiDelegate = self
        view.isOpaque = false
        view.backgroundColor = .healthPageBackground
        view.underPageBackgroundColor = .healthPageBackground
        view.scrollView.backgroundColor = .healthPageBackground
        view.scrollView.contentInsetAdjustmentBehavior = .never
        view.scrollView.keyboardDismissMode = .interactive
        view.scrollView.bounces = false
        view.allowsBackForwardNavigationGestures = false
        return view
    }()

    func load() {
        guard requestedPage == nil else { return }
        navigate(to: pendingWorkout.flatMap(workoutPage) ?? home)
    }

    func reload() {
        let currentPage = pageState == .ready ? webView.url : nil
        let destination = pendingWorkout.flatMap(workoutPage) ?? currentPage ?? requestedPage ?? home
        navigate(to: destination, retry: true)
    }

    private func navigate(to url: URL, retry: Bool = false) {
        requestedPage = url
        prepareForLoad()
        let policy: URLRequest.CachePolicy = retry ? .reloadIgnoringLocalCacheData : .useProtocolCachePolicy
        navigation = webView.load(URLRequest(url: url, cachePolicy: policy, timeoutInterval: 20))
        if navigation == nil { showFailure(.connection) }
    }

    private func workoutPage(_ id: String) -> URL? {
        guard let fixturePage else { return HealthRoute.workoutURL(id) }
        var components = URLComponents(url: fixturePage, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "workout", value: id)]
        return components?.url
    }

    func sendAction(_ type: String, values: [String: String] = [:]) {
        guard pageState == .ready, chromeReady, chrome.authenticated,
              let url = webView.url, isTrusted(url) else { return }
        var value = values; value["type"] = type
        guard let data = try? JSONSerialization.data(withJSONObject: value),
              let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.dispatchEvent(new CustomEvent('health-native-action',{detail:\(json)}));", completionHandler: nil)
    }
    func sendWorkoutAction(_ type: String, values: [String: String] = [:]) {
        guard let id = chrome.workoutID else { return }
        var payload = values; payload["sessionID"] = id
        sendAction(type, values: payload)
    }
    func renameWorkout() {
        guard chrome.screen == .workout, let id = chrome.workoutID else { return }
        try? prompts.rename(title: chrome.title) { [weak self] title in
            guard let self, self.chrome.workoutID == id else { return }
            self.sendWorkoutAction("renameWorkout", values: ["title": title])
        }
    }
    // Native settings share the same mutation queue as webpage workout updates.
    func changePreference(_ operation: @escaping @MainActor () async throws -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let previous = bridgeTask
            bridgeTask = Task { @MainActor in
                await previous?.value
                do { try await operation(); continuation.resume() }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
    func resume() {
        guard pageState == .ready, let url = webView.url, isTrusted(url) else { return }
        webView.evaluateJavaScript("window.dispatchEvent(new Event('health-native-resume'))", completionHandler: nil)
    }
    func setTabBarInset(_ inset: Int) {
        guard pageState == .ready, let url = webView.url, isTrusted(url) else { return }
        webView.evaluateJavaScript("document.documentElement.style.setProperty('--native-tab-inset', '\(inset)px')", completionHandler: nil)
    }
    func openActiveWorkout() {
        guard chrome.authenticated, let id = activeWorkoutID, let url = HealthRoute.deepLink(id) else { return }
        open(url)
    }

    func open(_ url: URL) {
        guard let id = HealthRoute.workoutID(from: url) else { return }
        if pageState == .ready, let current = webView.url, isTrusted(current) {
            // UUID validation makes the interpolated value data, never script.
            let script = "const destination=new URL(window.location.href);destination.searchParams.set('workout','\(id)');destination.hash='strength';window.history.replaceState(null,'',destination);window.dispatchEvent(new Event('hashchange'));window.dispatchEvent(new CustomEvent('health-native-open-workout',{detail:'\(id)'}));"
            webView.evaluateJavaScript("(()=>{\(script)})()", completionHandler: nil)
        } else {
            pendingWorkout = id
            if let destination = workoutPage(id) { navigate(to: destination) }
        }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage, replyHandler: @escaping (Any?, String?) -> Void) {
        guard message.frameInfo.isMainFrame,
              let url = message.frameInfo.request.url, isTrusted(url),
              let body = message.body as? [String: Any], body["version"] as? Int == 1,
              let type = body["type"] as? String
        else { replyHandler(nil, "无法识别消息来源。"); return }
        // UI presentations and navigation must not wait behind a permission prompt.
        do {
            switch type {
            case "syncChrome":
                let state = try decode(NativeChromeState.self, from: body["chrome"]).validated()
                if chrome != state { chrome = state }
                if !chromeReady { chromeReady = true }
                if !state.authenticated {
                    activeWorkoutID = nil
                    showingSettings = false
                    prompts.cancel()
                }
                replyHandler(["nativeChromeVersion": 1], nil)
                return
            case "presentMenu":
                guard chrome.authenticated else { throw BridgeFailure.invalidMessage }
                let menu = try decode(NativeMenuRequest.self, from: body["menu"])
                try prompts.menu(menu) { replyHandler($0, nil) }
                return
            case "presentConfirmation":
                guard chrome.authenticated else { throw BridgeFailure.invalidMessage }
                let request = try decode(NativeConfirmationRequest.self, from: body["confirmation"])
                try prompts.confirmation(request) { replyHandler($0, nil) }
                return
            case "openSettings":
                guard chrome.authenticated else { throw BridgeFailure.invalidMessage }
                showingSettings = true; replyHandler(["opened": true], nil)
                return
            default: break
            }
        } catch { replyHandler(nil, error.localizedDescription); return }
        let previous = bridgeTask
        let generation = pageGeneration
        bridgeTask = Task { @MainActor in
            await previous?.value
            guard pageGeneration == generation else { replyHandler(nil, "页面已重新打开。"); return }
            do {
                switch type {
                case "status": break
                case "syncWorkout":
                    let next: WorkoutSnapshot?
                    if body["workout"] is NSNull { next = nil }
                    else if let snapshot = body["workout"] as? [String: Any] {
                        let data = try JSONSerialization.data(withJSONObject: snapshot)
                        guard data.count <= 4096 else { throw BridgeFailure.invalidMessage }
                        next = try WorkoutSnapshot.decode(data)
                    } else { throw BridgeFailure.invalidMessage }
                    if activeWorkoutID != next?.sessionID { activeWorkoutID = next?.sessionID }
                    try await coordinator.sync(next)
                    replyHandler(["synced": true], nil)
                    return
                case "enableRestReminders": try await coordinator.enableRestReminders()
                case "disableRestReminders": coordinator.disableRestReminders()
                case "setLiveActivities":
                    guard let enabled = body["enabled"] as? Bool else { throw BridgeFailure.invalidMessage }
                    await coordinator.setLiveActivities(enabled)
                default: throw BridgeFailure.invalidMessage
                }
                replyHandler(await coordinator.status().bridgeValues, nil)
            } catch { replyHandler(nil, error.localizedDescription) }
        }
    }

    private func decode<Value: Decodable>(_ type: Value.Type, from object: Any?) throws -> Value {
        guard let object, JSONSerialization.isValidJSONObject(object) else { throw BridgeFailure.invalidMessage }
        let data = try JSONSerialization.data(withJSONObject: object)
        guard data.count <= 16384 else { throw BridgeFailure.invalidMessage }
        return try JSONDecoder().decode(type, from: data)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        if isTrusted(url), url.path != "/api/auth/login" {
            if navigationAction.targetFrame?.isMainFrame == true { requestedPage = url }
            decisionHandler(.allow)
            return
        }
        decisionHandler(.cancel)
        guard navigationAction.targetFrame?.isMainFrame != false else { return }
        // OAuth starts in the system browser so Google never sees an embedded login.
        if url.scheme == "https" || (navigationAction.navigationType == .linkActivated && ["fitbit", "googlehealth", "mailto", "tel"].contains(url.scheme?.lowercased() ?? "")) {
            UIApplication.shared.open(url)
        }
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard navigationAction.targetFrame == nil, let url = navigationAction.request.url else { return nil }
        if isTrusted(url), url.path != "/api/auth/login" { webView.load(navigationAction.request) }
        else if url.scheme == "https" { UIApplication.shared.open(url) }
        return nil
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if response.isForMainFrame, let http = response.response as? HTTPURLResponse, http.statusCode >= 400 {
            showFailure(.server)
            decisionHandler(.cancel)
        } else { decisionHandler(.allow) }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        if self.navigation !== navigation { prepareForLoad() }
        self.navigation = navigation
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard self.navigation === navigation else { return }
        pageState = .ready
        if let id = pendingWorkout, let url = HealthRoute.deepLink(id) {
            pendingWorkout = nil
            // The initial URL already carries the ID, including through dashboard login.
            let query = webView.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems }
            if query?.contains(where: { $0.name == "workout" && $0.value == id }) != true { open(url) }
        }
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { navigationFailed(navigation, error: error) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { navigationFailed(navigation, error: error) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        if let url = webView.url, isTrusted(url) { requestedPage = url }
        showFailure(.interrupted)
    }
    private func prepareForLoad() {
        resetPage()
        pageState = .loading
    }
    private func resetPage() {
        pageGeneration += 1
        chromeReady = false
        activeWorkoutID = nil
        showingSettings = false
        prompts.cancel()
    }
    private func navigationFailed(_ navigation: WKNavigation?, error: Error) {
        let error = error as NSError
        guard let navigation, self.navigation === navigation,
              !(error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled) else { return }
        showFailure(.connection)
    }
    private func showFailure(_ failure: HealthPageFailure) {
        navigation = nil
        resetPage()
        pageState = .failed(failure)
    }
}


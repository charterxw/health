import SwiftUI
import UserNotifications
import UIKit

@main
@MainActor
struct HealthApp: App {
    @UIApplicationDelegateAdaptor(HealthAppDelegate.self) private var delegate
    @State private var store = NativeStore()
    var body: some Scene {
        WindowGroup {
            NativeAppContent(delegate: delegate)
                .environment(store).tint(pine).environment(\.locale, Locale(identifier: "zh_CN"))
        }
    }
}

/// A View owns observation and startup tasks; the App owns the store's lifetime.
private struct NativeAppContent: View {
    @Environment(NativeStore.self) private var store
    @Environment(\.scenePhase) private var phase
    let delegate: HealthAppDelegate
    var body: some View {
        Group {
            switch store.phase {
            case .loading: ProgressView("正在打开 Pine").frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(uiColor: .systemGroupedBackground))
            case .login: NativeLoginView()
            case .ready: NativeRootView()
            case .failed(let message):
                ContentUnavailableView { Label("Pine 暂时不可用", systemImage: "wifi.exclamationmark") } description: { Text(message) } actions: {
                    Button("重试", systemImage: "arrow.clockwise") { Task { await store.connect() } }.buttonStyle(.borderedProminent)
                }
            }
        }
        .task { await store.boot(); openPending() }
        .task(id: phase) {
            guard phase == .active, !store.isDesignPreview else { return }; openPending()
            if store.phase == .ready { await store.foreground() }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
                await store.synchronize()
            }
        }
        .onOpenURL { store.open($0) }
        .onReceive(NotificationCenter.default.publisher(for: .healthOpenWorkout)) { event in
            if let id = event.object as? String, let url = HealthRoute.deepLink(id) { store.open(url) }; delegate.pendingWorkoutID = nil
        }
    }
    private func openPending() {
        if let id = delegate.pendingWorkoutID, let url = HealthRoute.deepLink(id) { store.open(url); delegate.pendingWorkoutID = nil }
    }
}

enum NativeOverviewRoute: Hashable { case recovery, sleep }
struct NativeRootView: View {
    @Environment(NativeStore.self) var store
    @State private var overviewPath: [NativeOverviewRoute] = {
        #if DEBUG && targetEnvironment(simulator)
        let env = ProcessInfo.processInfo.environment
        if env["HEALTH_DESIGN_PREVIEW"] == "1", env["HEALTH_DESIGN_SCREEN"] == "sleep" { return [.recovery, .sleep] }
        #endif
        return []
    }()
    var body: some View {
        @Bindable var store = store
        TabView(selection: $store.selectedTab) {
            NavigationStack(path: $overviewPath) { NativeDashboardView().nativeToolbar().navigationDestination(for: NativeOverviewRoute.self) { route in switch route { case .recovery: NativeRecoveryContent(); case .sleep: NativeSleepView() } } }.tabItem { Label("总览", systemImage: "square.grid.2x2.fill") }.tag(0)
            NavigationStack { NativeTrainingView().nativeToolbar() }.tabItem { Label("训练", systemImage: "dumbbell.fill") }.tag(1)
            NavigationStack { NativeHistoryView().nativeToolbar() }.tabItem { Label("运动记录", systemImage: "list.bullet.clipboard.fill") }.tag(2)
        }
        .overlay(alignment: .bottomLeading) { if store.isDesignPreview { Text("设计预览 · 示例数据").font(.caption2).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.vertical, 4).background(.regularMaterial, in: Capsule()).padding(.leading, 24).padding(.bottom, 100).allowsHitTesting(false) } }
        .transformEnvironment(\.pinePreviewReduceMotion) { value in
            #if DEBUG && targetEnvironment(simulator)
            if store.isDesignPreview, ProcessInfo.processInfo.environment["HEALTH_DESIGN_REDUCE_MOTION"] == "1" { value = true }
            #endif
        }
        .task { if store.designPreviewScreen == "sleep", overviewPath.isEmpty { overviewPath = [.recovery, .sleep] } }
        .sheet(isPresented: $store.showingSettings) { NavigationStack { NativeSettingsView() }.presentationDragIndicator(.visible) }
        .fullScreenCover(isPresented: $store.workoutPresented, onDismiss: store.workoutDidDismiss) { NativeWorkoutView() }
        .sheet(item: Binding(get: { store.reportID.map(ReportSelection.init) }, set: { store.reportID = $0?.id }), onDismiss: store.reportDidDismiss) { item in
            NavigationStack { NativeReportView(id: item.id).toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { store.reportID = nil } } } }
        }
    }
}
struct ReportSelection: Identifiable { let id: String }
struct NativeToolbar: ViewModifier {
    @Environment(NativeStore.self) var store
    func body(content: Content) -> some View {
        content.toolbar {
            if store.active != nil { ToolbarItem(placement: .topBarLeading) { Button("继续训练", systemImage: "play.fill") { store.workoutPresented = true } } }
            ToolbarItem(placement: .topBarTrailing) { Button("设置", systemImage: "gearshape") { store.showingSettings = true }.labelStyle(.iconOnly) }
        }
    }
}
extension View { func nativeToolbar() -> some View { modifier(NativeToolbar()) } }

extension Notification.Name { static let healthOpenWorkout = Notification.Name("healthOpenWorkout") }
final class HealthAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    var pendingWorkoutID: String?
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self; return true
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler(notification.request.identifier == WorkoutCoordinator.reminderID ? [.banner] : [.banner, .sound])
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        if let id = response.notification.request.content.userInfo["workout"] as? String, UUID(uuidString: id) != nil {
            DispatchQueue.main.async { [weak self] in self?.pendingWorkoutID = id; NotificationCenter.default.post(name: .healthOpenWorkout, object: id) }
        }; completionHandler()
    }
}

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
            // Network work runs in store-owned tasks: this view task is cancelled on
            // every scene-phase change, which would otherwise abort in-flight requests.
            if phase == .background { store.enteredBackground(); return }
            guard phase == .active, !store.isDesignPreview else { return }; openPending()
            store.becameActive()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
                store.periodicSync()
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
        // Goal celebrations: when a goal closes in the app it plays right away;
        // when it closed elsewhere (the band) it plays the next time the app is
        // looked at. Never over a workout or a report.
        .overlay(alignment: .top) {
            if let event = store.celebration, !event.big {
                PineCelebrationView(event: event) { store.celebration = nil }.transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .overlay {
            if let event = store.celebration, event.big {
                PineCelebrationView(event: event) { store.celebration = nil }.transition(.opacity)
            }
        }
        .task(id: celebrationKey) {
            do { try await Task.sleep(for: .seconds(0.9)) } catch { return }
            checkCelebrations()
        }
        .sheet(isPresented: $store.showingSettings) { NavigationStack { NativeSettingsView() }.presentationDragIndicator(.visible) }
        .fullScreenCover(isPresented: $store.workoutPresented, onDismiss: store.workoutDidDismiss) { NativeWorkoutView() }
        .sheet(item: Binding(get: { store.reportID.map(ReportSelection.init) }, set: { store.reportID = $0?.id }), onDismiss: store.reportDidDismiss) { item in
            NavigationStack { NativeReportView(id: item.id).toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { store.reportID = nil } } } }
        }
    }
}
extension NativeRootView {
    private var todayRow: JSONValue { store.home["days"].array.first { $0["date"] == store.home["date"] } ?? .null }
    var celebrationKey: String {
        [store.home["date"].text, displayNumber(todayRow["activity"], digits: 0), String(todayRow["posture"].flag), String(store.records.count), String(store.historyRevision),
         String(store.workoutPresented), store.reportID ?? "", String(store.celebration == nil), String(store.active == nil)].joined(separator: "|")
    }
    /// Today's goals that closed and have not been celebrated yet; all three at
    /// once is the big moment, otherwise one goal at a time.
    func checkCelebrations() {
        guard store.phase == .ready, !store.isDesignPreview, store.celebration == nil, !store.workoutPresented, store.reportID == nil, store.active == nil else { return }
        let home = store.home, date = home["date"].text, row = todayRow
        guard !date.isEmpty, !row.isNull else { return }
        let zone = home["timezone"].text.isEmpty ? TimeZone.current.identifier : home["timezone"].text
        let sessions = NativeDays.sessions(records: store.records, timezone: zone)[date] ?? []
        let weekend = NativeDays.isWeekend(date)
        let halves = NativeDays.halves(sessions, weekend: weekend)
        let goal = row["goals"]["dailyActivity"].number ?? 0
        let activity = goal > 0 ? row["activity"].number.map { $0 / goal } : nil
        let strength = weekend ? (halves.first ?? 0) >= 1 : halves.count >= 2 && halves.prefix(2).allSatisfy { $0 >= 1 }
        let posture = row["posture"].flag || NativeDays.postureDone(sessions)
        let met: [PineCelebration.Kind: Bool] = [.activity: (activity ?? 0) >= 1, .strength: strength, .posture: posture]
        let defaults = UserDefaults.standard
        // A finished round earns a medal once; it outranks today's goals.
        let plan = home["plan"], schedule = plan["schedule"].array
        if plan["version"].integer == 2, plan["next"].isNull, !schedule.isEmpty, schedule.allSatisfy({ $0["completed"].flag }) {
            let roundKey = "pine.medal.round.\(plan["id"].integer)"
            if !defaults.bool(forKey: roundKey) {
                defaults.set(true, forKey: roundKey)
                var medals = defaults.array(forKey: NativeMedals.key) as? [[String: Any]] ?? []
                medals.append(["round": medals.count + 1, "date": date, "sets": plan["done"].integer])
                defaults.set(medals, forKey: NativeMedals.key)
                withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) {
                    store.celebration = PineCelebration(kind: .round, activity: nil, halves: [], posture: false, round: medals.count, sets: plan["done"].integer)
                }
                return
            }
        }
        func key(_ kind: PineCelebration.Kind) -> String { "pine.celebrated." + date + "." + kind.rawValue }
        let fresh = [PineCelebration.Kind.activity, .strength, .posture].filter { met[$0] == true && !defaults.bool(forKey: key($0)) }
        guard let first = fresh.first else { return }
        let kind: PineCelebration.Kind
        if met.values.allSatisfy({ $0 }) && !defaults.bool(forKey: key(.all)) {
            kind = .all
            for each in [PineCelebration.Kind.activity, .strength, .posture, .all] { defaults.set(true, forKey: key(each)) }
        } else {
            kind = first
            defaults.set(true, forKey: key(kind))
        }
        withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) {
            store.celebration = PineCelebration(kind: kind, activity: activity, halves: halves, posture: posture)
        }
    }
}
struct ReportSelection: Identifiable { let id: String }
/// Medals for finished rounds, kept on this phone.
enum NativeMedals {
    static let key = "pine.medals"
    static var all: [(round: Int, date: String, sets: Int)] {
        (UserDefaults.standard.array(forKey: key) as? [[String: Any]] ?? []).map { ($0["round"] as? Int ?? 0, $0["date"] as? String ?? "", $0["sets"] as? Int ?? 0) }
    }
}
/// Tab roots draw their own PineTabHeader; pushed pages keep the system bar.
struct NativeToolbar: ViewModifier {
    func body(content: Content) -> some View { content.toolbar(.hidden, for: .navigationBar) }
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

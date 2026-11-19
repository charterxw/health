import ActivityKit
import AVFoundation
import Foundation
import UIKit
import UserNotifications

@MainActor
final class WorkoutCoordinator: NSObject, AVAudioPlayerDelegate {
    nonisolated static let reminderID = "health.rest"
    private let notifications = UNUserNotificationCenter.current()
    private let preferences = UserDefaults.standard
    private var workout: WorkoutSnapshot?
    private var reminderKey: String?
    private var clockKey: String?
    private var restClock: Task<Void, Never>?
    private var player: AVAudioPlayer?
    private var activityError: String?
    private var snapshotError: String?
    private var activityChain: Task<Void, Never>?
    private var reminderError: String?
    private var syncing = false
    private var hasSynchronized = false

    private var liveEnabled: Bool { preferences.object(forKey: "liveActivitiesEnabled") as? Bool ?? true }
    private var remindersEnabled: Bool { preferences.bool(forKey: "restRemindersEnabled") }
    private var chimeEnabled: Bool { preferences.object(forKey: "restChimeEnabled") as? Bool ?? true }

    func status() async -> WorkoutSettingsStatus {
        let settings = await notifications.notificationSettings()
        let permission: WorkoutSettingsStatus.NotificationPermission
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: permission = .authorized
        case .denied: permission = .denied
        default: permission = .notDetermined
        }
        return WorkoutSettingsStatus(activitiesAllowed: ActivityAuthorizationInfo().areActivitiesEnabled,
                                     liveActivitiesEnabled: liveEnabled,
                                     restChimeEnabled: chimeEnabled,
                                     restRemindersEnabled: remindersEnabled && permission == .authorized,
                                     notificationSoundEnabled: settings.soundSetting == .enabled,
                                     notificationPermission: permission,
                                     activityError: activityError ?? snapshotError, reminderError: reminderError)
    }

    func setLiveActivities(_ enabled: Bool) async {
        preferences.set(enabled, forKey: "liveActivitiesEnabled")
        await updateActivity()
    }

    func enableRestReminders() async throws {
        let granted = try await notifications.requestAuthorization(options: [.alert, .sound])
        preferences.set(granted, forKey: "restRemindersEnabled")
        try await updateReminder()
        reminderError = nil
    }

    func disableRestReminders() {
        preferences.set(false, forKey: "restRemindersEnabled")
        cancelReminder(clearDelivered: true)
        reminderError = nil
    }

    func setRestChime(_ enabled: Bool) {
        preferences.set(enabled, forKey: "restChimeEnabled")
    }

    func sync(_ next: WorkoutSnapshot?, force: Bool = false) async throws {
        // Weight/repetition keystrokes do not change the Live Activity payload.
        guard force || !hasSynchronized || workout != next || activityError != nil || snapshotError != nil || reminderError != nil else { return }
        // The native publisher serializes calls. Reject overlapping settings work.
        guard !syncing else { throw BridgeFailure.busy }
        syncing = true
        defer { syncing = false }
        // An invalid snapshot must not leave the previous workout state on the Lock Screen.
        if let next {
            do { workout = try next.validated(); snapshotError = nil }
            catch { workout = nil; snapshotError = "训练实况数据异常，已暂停显示。重新打开训练后会再次尝试。" }
        } else { workout = nil; snapshotError = nil }
        hasSynchronized = true
        updateRestClock()
        // Schedule the local reminder before awaiting ActivityKit.
        do { try await updateReminder(); reminderError = nil }
        catch {
            cancelReminder()
            reminderError = "休息提醒暂未安排成功，请检查系统通知设置。"
        }
        await updateActivity()
    }

    /// Serializes ActivityKit work so settings changes and workout updates cannot
    /// both see "no activity" and request two Live Activities.
    private func updateActivity() async {
        let previous = activityChain
        let next = Task { await previous?.value; await performActivityUpdate() }
        activityChain = next
        await next.value
    }

    private func performActivityUpdate() async {
        activityError = nil
        let current = workout
        for activity in Activity<WorkoutAttributes>.activities {
            if !liveEnabled || current == nil || activity.attributes.sessionID != current?.sessionID {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
        guard liveEnabled, let current, ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let content = ActivityContent(state: WorkoutAttributes.ContentState(workout: current),
                                      staleDate: current.activityStaleDate())
        if let activity = Activity<WorkoutAttributes>.activities.first(where: { $0.attributes.sessionID == current.sessionID }) {
            await activity.update(content)
        } else {
            do {
                _ = try Activity.request(attributes: WorkoutAttributes(sessionID: current.sessionID), content: content, pushType: nil)
            } catch {
                activityError = "暂时无法显示训练实况，请检查系统设置后重新打开训练。"
            }
        }
    }

    private func cancelReminder(clearDelivered: Bool = false) {
        notifications.removePendingNotificationRequests(withIdentifiers: [Self.reminderID])
        if clearDelivered { notifications.removeDeliveredNotifications(withIdentifiers: [Self.reminderID]) }
        reminderKey = nil
    }

    private func updateReminder() async throws {
        guard remindersEnabled, let workout, let date = workout.reminderDate() else {
            cancelReminder(clearDelivered: workout == nil)
            return
        }
        let key = workout.sessionID + ":" + String(date.timeIntervalSince1970)
        guard key != reminderKey else { return }
        let content = UNMutableNotificationContent()
        content.title = "休息结束"
        content.body = "准备好后，开始下一组。"
        content.sound = UNNotificationSound(named: UNNotificationSoundName("RestComplete.wav"))
        content.userInfo = ["workout": workout.sessionID]
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, date.timeIntervalSinceNow), repeats: false)
        try await notifications.add(UNNotificationRequest(identifier: Self.reminderID, content: content, trigger: trigger))
        reminderKey = key
    }

    private func updateRestClock() {
        let date = workout?.reminderDate()
        let key = date.flatMap { date in workout.map { "\($0.sessionID):\(date.timeIntervalSince1970)" } }
        guard key != clockKey else { return }
        restClock?.cancel()
        clockKey = key
        guard let date, let key else { return }
        restClock = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(max(0, date.timeIntervalSinceNow))) }
            catch { return }
            guard let self, self.clockKey == key, UIApplication.shared.applicationState == .active else { return }
            if self.chimeEnabled && Date().timeIntervalSince(date) < 2 { self.playChime() }
            if !self.syncing { await self.updateActivity() }
        }
    }

    func playChime() {
        guard let sound = Bundle.main.url(forResource: "RestComplete", withExtension: "wav") else { return }
        let session = AVAudioSession.sharedInstance()
        do {
            let next = try AVAudioPlayer(contentsOf: sound)
            try session.setCategory(.playback, options: .mixWithOthers)
            try session.setActive(true)
            next.delegate = self
            player?.stop()
            player = next
            if !next.play() { releaseAudio(next) }
        } catch {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in releaseAudio(player) }
    }

    private func releaseAudio(_ finished: AVAudioPlayer) {
        guard player === finished else { return }
        player = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

struct WorkoutSettingsStatus {
    enum NotificationPermission: String { case authorized, denied, notDetermined }

    let activitiesAllowed: Bool
    let liveActivitiesEnabled: Bool
    let restChimeEnabled: Bool
    let restRemindersEnabled: Bool
    let notificationSoundEnabled: Bool
    let notificationPermission: NotificationPermission
    let activityError: String?
    let reminderError: String?

    var bridgeValues: [String: Any] {
        ["version": 1,
         "activitiesAllowed": activitiesAllowed,
         "liveActivitiesEnabled": liveActivitiesEnabled,
         "restRemindersEnabled": restRemindersEnabled,
         "notificationPermission": notificationPermission.rawValue,
         "activityError": activityError ?? "",
         "reminderError": reminderError ?? ""]
    }
}

enum BridgeFailure: LocalizedError {
    case invalidMessage, busy
    var errorDescription: String? {
        switch self {
        case .invalidMessage: return "无法识别训练数据，请刷新页面。"
        case .busy: return "正在更新训练，请稍后重试。"
        }
    }
}

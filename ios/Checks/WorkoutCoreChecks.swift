import Foundation
import HealthCore

struct CheckFailure: Error, CustomStringConvertible {
    let description: String
}
func expect(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !value() { throw CheckFailure(description: message) }
}
func expectFailure(_ operation: () throws -> Void) throws {
    do { try operation() }
    catch { return }
    throw CheckFailure(description: "Expected validation failure")
}

@main
struct WorkoutCoreChecks {
    static let id = "11111111-2222-4333-8444-555555555555"
    static func snapshot(_ changes: [String: Any] = [:]) throws -> WorkoutSnapshot {
        var payload: [String: Any] = [
            "protocolVersion": 1, "sessionID": id, "title": "背部训练", "startedAt": 1000,
            "pausedAt": NSNull(), "pausedSeconds": 60, "restUntil": 1690,
            "movementName": "单手下拉", "movementIndex": 1, "movementCount": 5,
            "completedSets": 1, "plannedSets": 15, "currentSet": 2, "movementSetCount": 3
        ]
        payload.merge(changes, uniquingKeysWith: { _, new in new })
        return try WorkoutSnapshot.decode(JSONSerialization.data(withJSONObject: payload))
    }
    static func pauseAndResume() throws {
        let paused = try snapshot(["pausedAt": 1600])
        try expect(paused.elapsed(at: Date(timeIntervalSince1970: 2000)) == 540, "Paused elapsed clock changed in background")
        try expect(paused.restRemaining(at: Date(timeIntervalSince1970: 2000)) == 90, "Paused rest clock changed")
        try expect(paused.reminderDate(at: Date(timeIntervalSince1970: 1600)) == nil, "Paused rest scheduled a notification")
        let resumed = try snapshot(["pausedSeconds": 460, "restUntil": 2090])
        try expect(resumed.elapsed(at: Date(timeIntervalSince1970: 2000)) == 540, "Resume included paused time")
        try expect(resumed.restRemaining(at: Date(timeIntervalSince1970: 2000)) == 90, "Resume lost remaining rest")
        try expect(resumed.reminderDate(at: Date(timeIntervalSince1970: 2000)) == Date(timeIntervalSince1970: 2090), "Resume did not restore reminder")
    }
    static func expiredAndSkippedRest() throws {
        try expect(try snapshot().reminderDate(at: Date(timeIntervalSince1970: 1700)) == nil, "Expired rest rescheduled")
        try expect(try snapshot(["restUntil": NSNull()]).reminderDate(at: Date(timeIntervalSince1970: 1600)) == nil, "Skipped rest rescheduled")
    }
    static func activityClockSwitches() throws {
        let rest = try snapshot()
        let duringRest = Date(timeIntervalSince1970: 1600)
        let deadline = Date(timeIntervalSince1970: 1690)
        try expect(rest.activityPhase(at: duringRest) == .resting, "Rest must take the primary clock")
        try expect(rest.activityStaleDate(at: duringRest) == deadline, "Live Activity should refresh at rest expiry")
        try expect(rest.activityPhase(at: deadline, stale: true) == .restFinished, "Expired rest must show the next set state")
        let paused = try snapshot(["pausedAt": 1600])
        try expect(paused.activityPhase(at: deadline.addingTimeInterval(600)) == .pausedRest, "Paused rest must stay frozen")
        let skipped = try snapshot(["restUntil": NSNull()])
        try expect(skipped.activityPhase(at: duringRest) == .training, "Skipped rest must restore the workout clock")
    }
    static func untrustedMessages() throws {
        let now = Date(timeIntervalSince1970: 1600)
        _ = try snapshot().validated(at: now)
        let cases: [[String: Any]] = [
            ["sessionID": "injected-url"], ["protocolVersion": 2], ["title": " "],
            ["plannedSets": -1], ["completedSets": 16], ["movementCount": 41],
            ["movementIndex": 6], ["currentSet": 4], ["pausedSeconds": -1],
            ["pausedSeconds": 2000], ["startedAt": 2000], ["restUntil": 2300],
            ["pausedAt": 999], ["title": String(repeating: "x", count: 101)]
        ]
        for changes in cases { try expectFailure { _ = try snapshot(changes).validated(at: now) } }
    }
    static func freeWorkout() throws {
        _ = try snapshot(["movementCount": 0, "movementIndex": 0, "plannedSets": 0,
                           "completedSets": 0, "movementSetCount": 0, "currentSet": 0]).validated(at: Date(timeIntervalSince1970: 1600))
    }
    static func epochAndClock() throws {
        let value = try snapshot()
        try expect(value.startedAt.timeIntervalSince1970 == 1000, "JavaScript/Swift epoch mismatch")
        try expect(value.effectiveStartedAt.timeIntervalSince1970 == 1060, "Timer anchor excludes wrong duration")
        try expect(WorkoutSnapshot.clock(90) == "01:30", "Rest clock formatting")
        try expect(WorkoutSnapshot.clock(3661) == "61:01", "Long workout formatting")
        try expect(WorkoutSnapshot.clock(-1) == "00:00", "Negative clock formatting")
    }
    static func navigation() throws {
        try expect(HealthRoute.isTrusted(HealthRoute.home), "Own origin rejected")
        for text in ["http://health.frankandpatrick.com", "https://health.frankandpatrick.com.evil.test/",
                     "https://evil.test/?workout=\(id)", "https://health.frankandpatrick.com:444/",
                     "https://user@health.frankandpatrick.com/", "file:///tmp/health.html"] {
            try expect(!HealthRoute.isTrusted(URL(string: text)!), "Untrusted origin accepted")
            try expect(HealthRoute.workoutID(from: URL(string: text)!) == nil, "Untrusted deep link accepted")
        }
        try expect(HealthRoute.workoutID(from: HealthRoute.deepLink(id)!) == id, "Custom link failed")
        try expect(HealthRoute.workoutID(from: HealthRoute.workoutURL(id)!) == id, "Report link failed")
        try expect(HealthRoute.home.fragment == "dashboard" && HealthRoute.workoutURL(id)?.fragment == "strength", "Cold launch and report must open different tabs")
        try expect(HealthRoute.workoutID(from: URL(string: "healthfp://workout/not-a-uuid")!) == nil, "Invalid ID accepted")
        try expect(HealthRoute.workoutID(from: URL(string: "healthfp://workout/\(id)/extra")!) == nil, "Extra path accepted")
        try expect(HealthRoute.deepLink("javascript:alert(1)") == nil, "Script accepted as link")
    }
    static func chrome(_ changes: [String: Any] = [:]) throws -> NativeChromeState {
        var value: [String: Any] = ["protocolVersion": 1, "authenticated": true, "tab": "strength", "screen": "home",
            "title": "训练", "workoutID": NSNull(), "googleConnected": true, "webDialogOpen": false]
        value.merge(changes, uniquingKeysWith: { _, new in new })
        return try JSONDecoder().decode(NativeChromeState.self, from: JSONSerialization.data(withJSONObject: value)).validated()
    }
    static func chromeLifecycle() throws {
        try expect(try chrome().showsTabs, "Home navigation unavailable")
        let workout = try chrome(["screen": "workout", "workoutID": id])
        try expect(workout.showsNavigation && !workout.showsTabs, "Workout should keep its toolbar and hide tabs")
        let report = try chrome(["screen": "report", "workoutID": id])
        try expect(report.showsTabs, "Report lost tab navigation")
        let modal = try chrome(["screen": "workout", "workoutID": id, "webDialogOpen": true])
        try expect(!modal.showsNavigation && !modal.showsTabs, "Web form has duplicate native controls")
        let signedOut = try chrome(["authenticated": false])
        try expect(!signedOut.showsNavigation && !signedOut.showsTabs, "Signed-out page still has native controls")
    }
    static func chromeValidation() throws {
        let cases: [[String: Any]] = [["protocolVersion": 2], ["tab": "unknown"], ["title": " "],
            ["screen": "workout"], ["screen": "home", "workoutID": id],
            ["screen": "report", "workoutID": id, "tab": "sleep"],
            ["authenticated": false, "screen": "workout", "workoutID": id]]
        for value in cases { try expectFailure { _ = try chrome(value) } }
    }
    static func menuValidation() throws {
        func menu(_ value: [String: Any]) throws {
            _ = try JSONDecoder().decode(NativeMenuRequest.self, from: JSONSerialization.data(withJSONObject: value)).validated()
        }
        try menu(["title": "切换动作", "actions": [["id": id, "title": "1. 下拉 · 0/4 组"]]])
        try expectFailure { try menu(["title": "动作", "actions": []]) }
        try expectFailure { try menu(["title": "动作", "actions": [["id": id, "title": "一"], ["id": id, "title": "二"]]]) }
        try expectFailure { try menu(["title": "动作", "actions": [["id": "", "title": "一"]]]) }
        let value: [String: Any] = ["title": "结束训练？", "message": "已完成 1 组", "confirmLabel": "完成并保存", "destructive": false]
        let confirmation = try JSONDecoder().decode(NativeConfirmationRequest.self, from: JSONSerialization.data(withJSONObject: value)).validated()
        try expect(!confirmation.destructive, "Finish confirmation became destructive")
    }
    static func main() throws {
        let checks: [(String, () throws -> Void)] = [
            ("Pause/resume clocks and reminders", pauseAndResume), ("Expired/skipped rest", expiredAndSkippedRest),
            ("Live Activity rest clock transitions", activityClockSwitches),
            ("Malformed and implausible messages", untrustedMessages), ("Free workout", freeWorkout),
            ("JavaScript epoch and clock formatting", epochAndClock), ("Trusted origin and deep links", navigation),
            ("Native navigation lifecycle", chromeLifecycle), ("Native navigation payloads", chromeValidation),
            ("Native menus and confirmations", menuValidation)
        ]
        for (name, check) in checks { try check(); print("PASS: \(name)") }
        print("\(checks.count) Swift core checks passed. This does not compile or run ActivityKit/UIKit.")
    }
}

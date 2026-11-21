import Foundation
import HealthCore

extension NativeCoreChecks {
    static func cacheJournalRecovery() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("account.json")
        var original = NativeCacheState()
        let session = try make()
        original.records[session.id] = NativeRecord(session: session, version: 3, dirty: true)
        original.home = ["date": "2026-11-18"]
        // The old cache format remains readable without a checkpoint revision.
        try JSONEncoder().encode(original).write(to: url)
        var first = original
        first.records[session.id]?.session["notes"] = "Saved before UI acknowledgement"
        first.records[session.id]?.alternative = ["id":"retained", "notes":"conflict copy"]
        let one = NativeCacheDelta(previous: original, next: first, revision: 1)
        try NativeCacheDisk.append(one, at: url)
        try check(try NativeCacheDisk.load(at: url).state == first, "A draft or alternative was lost before checkpointing")
        var second = first
        second.records.removeValue(forKey: session.id); second.deleted.insert(session.id); second.home = .null
        try NativeCacheDisk.append(NativeCacheDelta(previous: first, next: second, revision: 2), at: url)
        // A concurrent newer edit must survive a checkpoint of an older snapshot.
        try NativeCacheDisk.checkpoint(first, revision: 1, at: url)
        let recovered = try NativeCacheDisk.load(at: url)
        try check(recovered.state == second && recovered.revision == 2, "Checkpointing lost a newer edit, deletion or explicit null")
        try NativeCacheDisk.checkpoint(second, revision: 2, at: url)
        try NativeCacheDisk.checkpoint(first, revision: 1, at: url)
        try check(try NativeCacheDisk.load(at: url).state == second, "An old checkpoint overwrote a newer one")
        let noChange = NativeCacheDelta(previous: second, next: second, revision: 3)
        try check(noChange.isEmpty, "No-op synchronization produced a disk transaction")
        try NativeCacheDisk.append(noChange, at: url)
        try Data("unfinished write".utf8).write(to: NativeCacheDisk.journalURL(for: url).appendingPathComponent("00000000000000000003.tmp"))
        try check(try NativeCacheDisk.load(at: url).state == second, "An unfinished atomic write was replayed")
        try Data("corrupt committed transaction".utf8).write(to: NativeCacheDisk.journalURL(for: url).appendingPathComponent("00000000000000000003.json"))
        try rejects { _ = try NativeCacheDisk.load(at: url) }
    }
    static func cacheWriteFailure() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let blocker = folder.appendingPathComponent("not-a-directory")
        try Data().write(to: blocker)
        var next = NativeCacheState(); let session = try make(); next.records[session.id] = NativeRecord(session: session, dirty: true)
        let delta = NativeCacheDelta(previous: NativeCacheState(), next: next, revision: 1)
        try rejects { try NativeCacheDisk.append(delta, at: blocker.appendingPathComponent("account.json")) }
        try check(try Data(contentsOf: blocker).isEmpty, "A failed append damaged unrelated storage")
    }
    static func cachedDateSemantics() throws {
        let fractional = NativeDate.parse("2026-11-18T14:30:12.123Z")!
        let whole = NativeDate.parse("2026-11-18T14:30:12Z")!
        try check(abs(fractional.timeIntervalSince(whole) - 0.123) < 0.001, "Cached parsing dropped subsecond precision")
        try check(NativeDate.day(whole, timezone: "America/New_York") == "2026-11-18", "Day formatting changed timezone semantics")
        try check(NativeDate.label(whole, format: "HH:mm", timezone: "America/New_York") == "09:30", "Clock formatting used the wrong zone")
        try check(NativeDate.label(whole, format: "HH:mm", timezone: "Asia/Tokyo") == "23:30", "Cached formatters leaked timezone settings")
        try check(NativeDate.dayLabel("2026-11-18", format: "M月d日 EEEE") == "11月18日 星期三", "Calendar-only dates shifted during formatting")
        let expected = NativeDate.stamp(whole)
        final class Results: @unchecked Sendable { let lock = NSLock(); var failed = false; func fail() { lock.lock(); failed = true; lock.unlock() } }
        let result = Results()
        DispatchQueue.concurrentPerform(iterations: 400) { _ in
            if NativeDate.parse(expected) != whole || NativeDate.label(whole, format: "HH:mm", timezone: "America/New_York") != "09:30" { result.fail() }
        }
        try check(!result.failed, "Concurrent formatting corrupted a timestamp or timezone")
    }
    static func livePayloadIdentity() throws {
        var session = try make(); let before = NativeTraining.snapshot(session, movement: 0)
        session["exercises"][0]["sets"][0]["weight"] = 50
        session["exercises"][0]["sets"][0]["reps"] = 10
        session["notes"] = "Editing must not publish ActivityKit again"
        try check(before == NativeTraining.snapshot(session, movement: 0), "A numeric edit unnecessarily changed the Live Activity payload")
        try check(before?.openSetID == session["exercises"][0]["sets"][0].id, "The Lock Screen button does not name the open set")
        session = try NativeTraining.toggle(session, movement: 0, set: 0)
        try check(before != NativeTraining.snapshot(session, movement: 0), "Set completion would be suppressed by Live Activity deduplication")
        try check(NativeTraining.snapshot(session, movement: 0)?.openSetID == session["exercises"][0]["sets"][1].id, "The Lock Screen button did not move to the next set")
        try check(NativeTraining.snapshot(NativeTraining.pause(session), movement: 0)?.openSetID == nil, "A paused workout still offers the Lock Screen button")
    }
    static func measurePerformance(_ output: String) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var state = NativeCacheState()
        let prototype = try make()
        for index in 0..<1000 {
            var session = prototype; session["id"] = .string("history-\(index)"); session["status"] = "completed"
            session["exercises"] = .array(Array(repeating: prototype["exercises"][0], count: 6))
            state.records[session.id] = NativeRecord(session: session, version: 1)
        }
        let fullURL = folder.appendingPathComponent("legacy.json"), journalURL = folder.appendingPathComponent("native.json")
        var full: [Double] = [], incremental: [Double] = [], journalBytes = 0, snapshotBytes = 0
        func clock(_ work: () throws -> Void) rethrows -> Double { let start = ProcessInfo.processInfo.systemUptime; try work(); return (ProcessInfo.processInfo.systemUptime - start) * 1000 }
        for index in 1...7 {
            var next = state; next.records["history-0"]?.session["notes"] = .string("edit-\(index)")
            full.append(try clock { let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]; let data = try e.encode(next); snapshotBytes = data.count; try data.write(to: fullURL, options: .atomic) })
            incremental.append(try clock { let delta = NativeCacheDelta(previous: state, next: next, revision: UInt64(index)); journalBytes = try JSONEncoder().encode(delta).count; try NativeCacheDisk.append(delta, at: journalURL) })
        }
        let stamp = "2026-11-18T14:30:12.123Z"
        let oldDates = clock { for _ in 0..<1000 { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; _ = f.date(from: stamp) } }
        _ = NativeDate.parse(stamp)
        let newDates = clock { for _ in 0..<1000 { _ = NativeDate.parse(stamp) } }
        let result: [String: Any] = ["scope":"macOS algorithm and disk microbenchmark; not iPhone frame-rate measurement", "synthetic_records":1000, "full_cache_bytes_per_edit":snapshotBytes, "journal_bytes_per_edit":journalBytes, "legacy_edit_ms":full, "incremental_edit_ms":incremental, "legacy_median_ms":full.sorted()[3], "incremental_median_ms":incremental.sorted()[3], "legacy_1000_timestamp_parses_ms":oldDates, "cached_1000_timestamp_parses_ms":newDates]
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: output))
        print("Performance sample: full-cache median \(full.sorted()[3]) ms; delta median \(incremental.sorted()[3]) ms; bytes \(snapshotBytes) → \(journalBytes)")
    }
}

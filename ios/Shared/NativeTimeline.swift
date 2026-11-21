import Foundation

public struct NativeTimelineItem: Identifiable, Sendable {
    public let id: String
    public let date: String
    public let time: String
    public let title: String
    public let kind: String
    public let detail: String
    public let search: String
    public let source: String
    public let pending: Bool
    public let document: JSONValue
}
public enum NativeTimeline {
    public static func items(records: [NativeRecord], archive: JSONValue, imported: [JSONValue] = []) -> [NativeTimelineItem] {
        var rows: [NativeTimelineItem] = []
        for record in records where record.session["status"].text == "completed" {
            let s = record.session
            let ms = s["exercises"].array
            let posture = !ms.isEmpty && ms.allSatisfy { NativeTraining.mobility($0) }
            let p = NativeTraining.progress(s)
            let start = NativeDate.parse(s["started_at"]), end = NativeDate.parse(s["ended_at"])
            let zone = s["timezone"].text.isEmpty ? "America/New_York" : s["timezone"].text
            let date = start.map { NativeDate.day($0, timezone: zone) } ?? String(s["started_at"].text.prefix(10))
            let duration: String
            if let start, let end { duration = "\(max(1, Int((max(0, end.timeIntervalSince(start) - (s["paused_seconds"].number ?? 0)) / 60).rounded()))) 分钟" }
            else { duration = "时长未记录" }
            let detail = duration + " · \(p.done)/\(p.planned) \(posture ? "练习组" : "工作组")" + (p.warmup > 0 ? " · 热身 \(p.warmup) 组" : "")
            rows.append(NativeTimelineItem(id: s.id, date: date, time: clock(start, timezone: zone), title: s["title"].text, kind: posture ? "posture" : "strength", detail: detail, search: ms.map { $0["name"].text }.joined(separator: " "), source: "app", pending: record.dirty || record.blocked != nil, document: s))
        }
        var seen = Set(rows.map(\.id))
        let old = archive["training"].isNull ? imported : archive["training"].array
        for (index, value) in old.enumerated() where value["source"].text != "local" {
            let id = "archive:" + value["datestr"].text + ":" + (value["localid"].text.isEmpty ? String(index) : value["localid"].text)
            guard seen.insert(id).inserted else { continue }
            let duration = value["duration_minutes"].number.map { "\(Int($0.rounded())) 分钟" } ?? "时长未记录"
            rows.append(NativeTimelineItem(id: id, date: value["datestr"].text, time: value["time"].text, title: value["title"].text.isEmpty ? "力量训练" : value["title"].text, kind: "strength", detail: duration + " · \(value["movements"].array.count) 动作", search: value["movements"].array.map { $0["name"].text }.joined(separator: " "), source: "archive", pending: false, document: value))
        }
        for (index, value) in archive["exercises"].array.enumerated() {
            let rawName = value["name"].text
            let names = ["Walk":"散步", "WALKING":"散步", "Strength":"力量训练", "STRENGTH_TRAINING":"力量训练", "Run":"跑步", "RUNNING":"跑步", "Cycling":"骑行", "CYCLING":"骑行", "BIKING":"骑行", "Swimming":"游泳", "SWIMMING":"游泳", "Yoga":"瑜伽", "YOGA":"瑜伽", "HIKING":"徒步", "WORKOUT":"运动"]
            let machineName = rawName.range(of: "^[A-Z0-9_]+$", options: .regularExpression) != nil
            let name = names[rawName] ?? (rawName.isEmpty || machineName ? "运动" : rawName)
            let walk = ["walk", "步行", "散步"].contains { rawName.lowercased().contains($0) }
            let duration = value["duration_minutes"].number.map { "\(Int($0.rounded())) 分钟" } ?? "时长未记录"
            let energy = value["calories"].number.flatMap { $0 > 0 ? " · \(Int($0.rounded())) 千卡" : nil } ?? ""
            rows.append(NativeTimelineItem(id: "activity:\(index):" + value["date"].text, date: value["date"].text, time: value["time"].text, title: name, kind: walk ? "walk" : "other", detail: duration + energy, search: rawName, source: "google", pending: false, document: value))
        }
        return rows.sorted { $0.date == $1.date ? ($0.time == $1.time ? $0.id < $1.id : $0.time > $1.time) : $0.date > $1.date }
    }
    public static func filter(_ rows: [NativeTimelineItem], kind: String = "all", query: String = "", month: String = "") -> [NativeTimelineItem] {
        let terms = query.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init)
        return rows.filter { row in (kind == "all" || row.kind == kind) && (month.isEmpty || row.date.hasPrefix(month)) && terms.allSatisfy { (row.title + " " + row.search).lowercased().contains($0) } }
    }
    private static func clock(_ value: Date?, timezone: String) -> String {
        guard let value else { return "" }; return NativeDate.label(value, format: "HH:mm", timezone: timezone)
    }
}

/// One recorded session placed on its local calendar day, for the day glyph.
public struct NativeDaySession: Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let start: Date?
    public let end: Date?
    /// Completed share of planned work sets (posture: practice sets), 0...1.
    public let ratio: Double
    public let posture: Bool
    public init(id: String, title: String, start: Date?, end: Date?, ratio: Double, posture: Bool) {
        self.id = id; self.title = title; self.start = start; self.end = end; self.ratio = ratio; self.posture = posture
    }
}

public enum NativeDays {
    /// Groups this app's completed and active sessions by local day, oldest first.
    /// Strength sessions fill the glyph's middle halves in order; a day with any
    /// completed posture practice fills the centre dot.
    public static func sessions(records: [NativeRecord], timezone: String) -> [String: [NativeDaySession]] {
        var days: [String: [NativeDaySession]] = [:]
        for record in records {
            let s = record.session, status = s["status"].text
            guard status == "completed" || status == "active", let start = NativeDate.parse(s["started_at"]) else { continue }
            let movements = s["exercises"].array
            guard !movements.isEmpty else { continue }
            let posture = movements.allSatisfy(NativeTraining.mobility)
            let counted = posture ? movements : movements.filter { !NativeTraining.mobility($0) }
            let planned = counted.reduce(0) { $0 + $1["sets"].array.filter { !$0["warmup"].flag }.count }
            let done = counted.reduce(0) { $0 + NativeTraining.done($1).filter { !$0["warmup"].flag }.count }
            guard done > 0 || status == "active" else { continue }
            let zone = s["timezone"].text.isEmpty ? timezone : s["timezone"].text
            let ratio = planned > 0 ? min(1, Double(done) / Double(planned)) : 0
            days[NativeDate.day(start, timezone: zone), default: []].append(NativeDaySession(
                id: s.id, title: s["title"].text, start: start, end: NativeDate.parse(s["ended_at"]),
                ratio: posture && status == "completed" ? 1 : ratio, posture: posture))
        }
        for key in days.keys { days[key]?.sort { ($0.start ?? .distantPast) < ($1.start ?? .distantPast) } }
        return days
    }
    /// Strength halves for the glyph: the first two strength sessions' completion.
    /// Weekends have one home session only, so it fills the whole middle ring.
    /// A company-only or home-only session ("全练") is the whole day, so it also
    /// fills both halves.
    public static func halves(_ sessions: [NativeDaySession], weekend: Bool = false) -> [Double] {
        let strength = sessions.filter { !$0.posture }
        if weekend { return strength.first.map { [$0.ratio, $0.ratio] } ?? [] }
        if let whole = strength.first(where: { $0.title.contains("全练") }) {
            let halves = strength.filter { $0.id != whole.id }.prefix(2).map(\.ratio)
            return [max(whole.ratio, halves.first ?? 0), max(whole.ratio, halves.dropFirst().first ?? 0)]
        }
        return Array(strength.prefix(2).map(\.ratio))
    }
    /// Saturday or Sunday for a "yyyy-MM-dd" day key.
    public static func isWeekend(_ key: String) -> Bool { [1, 7].contains(weekday(key)) }
    /// Gregorian weekday (1 = Sunday … 7 = Saturday) of a "yyyy-MM-dd" key, 0 when invalid.
    public static func weekday(_ key: String) -> Int {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return 0 }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "UTC")!
        guard let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) else { return 0 }
        return calendar.component(.weekday, from: date)
    }
    /// One-character focus for a day: the rotation group of the day's session
    /// (A/C shoulders, B/D back, E core), else the server's planned tag;
    /// Saturday is optional and Sunday rest.
    public static func focus(dayKey: String, sessions: [NativeDaySession], serverTag: String) -> String {
        if isWeekend(dayKey) { return weekday(dayKey) == 7 ? "选" : sessions.contains { !$0.posture } ? "练" : "休" }
        if let title = sessions.first(where: { !$0.posture })?.title, let letter = title.trimmingCharacters(in: .whitespaces).first {
            switch letter { case "A", "C": return "肩"; case "B", "D": return "背"; case "E": return "腹"; default: break }
        }
        switch serverTag { case "上": return "肩"; case "家": return "家"; case "休": return "休"; default: return serverTag.isEmpty ? "休" : serverTag }
    }
    /// Training volume (load × reps of completed external-load work sets) in
    /// pounds, for sets completed in [from, to).
    public static func volume(records: [NativeRecord], from: Date, to: Date) -> Double {
        var total = 0.0
        for record in records where ["completed", "active"].contains(record.session["status"].text) {
            for movement in record.session["exercises"].array where movement["load_mode"].text == "external" && !NativeTraining.timed(movement) && !NativeTraining.mobility(movement) {
                let factor = movement["unit"].text == "kg" ? 2.2046226 : 1
                for set in NativeTraining.done(movement) where !set["warmup"].flag {
                    guard let done = NativeDate.parse(set["completed_at"]), done >= from, done < to,
                          let weight = set["weight"].number, let reps = set["reps"].number else { continue }
                    total += weight * factor * reps
                }
            }
        }
        return total
    }
    /// Best-set performance of one lift: estimated 1RM (Epley) for external load,
    /// reps for bodyweight, and less assistance scoring higher for assisted lifts.
    public static func liftScore(_ movement: JSONValue, _ set: JSONValue) -> Double? {
        guard !set["warmup"].flag, let reps = set["reps"].number, reps > 0 else { return nil }
        let factor = movement["unit"].text == "kg" ? 2.2046226 : 1
        let epley = 1 + min(reps, 20) / 30
        switch movement["load_mode"].text {
        case "bodyweight": return reps
        case "assistance":
            guard let weight = set["weight"].number, weight > 0 else { return nil }
            return epley / (weight * factor)
        default:
            guard let weight = set["weight"].number, weight > 0 else { return nil }
            return weight * factor * epley
        }
    }
    /// Each lift's best set in [from, to) against its own best over the `baselineDays`
    /// before; the week's index is the median change, so swapping or skipping a lift
    /// does not move it.
    public static func strength(sessions: [JSONValue], from: Date, to: Date, baselineDays: Int = 28) -> NativeStrengthWeek {
        let baselineStart = from.addingTimeInterval(-Double(baselineDays) * 86400)
        var current: [String: (name: String, score: Double)] = [:], baseline: [String: Double] = [:]
        for session in sessions where ["completed", "active"].contains(session["status"].text) {
            let started = NativeDate.parse(session["started_at"])
            for movement in session["exercises"].array where !NativeTraining.timed(movement) && !NativeTraining.mobility(movement) {
                let key = movement["exercise_id"].text + "|" + movement["load_mode"].text
                for set in movement["sets"].array where !set["completed_at"].isNull {
                    guard let at = NativeDate.parse(set["completed_at"]) ?? started, let score = liftScore(movement, set) else { continue }
                    if at >= from && at < to { if score > (current[key]?.score ?? 0) { current[key] = (movement["name"].text, score) } }
                    else if at >= baselineStart && at < from { baseline[key] = max(baseline[key] ?? 0, score) }
                }
            }
        }
        let lifts = current.compactMap { key, value -> NativeLiftProgress? in
            guard let best = baseline[key], best > 0 else { return nil }
            return NativeLiftProgress(id: key, name: value.name, current: value.score, best: best)
        }.sorted { $0.change > $1.change }
        let changes = lifts.map(\.change).sorted()
        let median: Double? = changes.isEmpty ? nil : changes.count % 2 == 1 ? changes[changes.count / 2] : (changes[changes.count / 2 - 1] + changes[changes.count / 2]) / 2
        return NativeStrengthWeek(change: median, lifts: lifts, newCount: current.count - lifts.count)
    }
    /// Lean-gain pace from daily weigh-ins: a least-squares line through the last
    /// `days` days, as percent of body weight per 30 days. Nil with fewer than six
    /// weigh-ins or less than two weeks between the first and last.
    public static func weightRate(_ weights: [(date: String, kg: Double)], today: String, days: Int = 28) -> (percentPerMonth: Double, kgPerMonth: Double, average: Double)? {
        func day(_ key: String) -> Double? { NativeDate.parse(key + "T12:00:00Z").map { $0.timeIntervalSince1970 / 86400 } }
        guard let end = day(today) else { return nil }
        let points = weights.compactMap { row -> (Double, Double)? in
            guard let x = day(row.date), x <= end, x > end - Double(days), row.kg > 20 else { return nil }
            return (x, row.kg)
        }
        guard points.count >= 6, let first = points.map(\.0).min(), let last = points.map(\.0).max(), last - first >= 14 else { return nil }
        let mx = points.map(\.0).reduce(0, +) / Double(points.count), my = points.map(\.1).reduce(0, +) / Double(points.count)
        let sxx = points.reduce(0) { $0 + ($1.0 - mx) * ($1.0 - mx) }
        guard sxx > 0 else { return nil }
        let slope = points.reduce(0) { $0 + ($1.0 - mx) * ($1.1 - my) } / sxx
        let recent = points.filter { $0.0 > end - 7 }.map(\.1)
        let average = recent.isEmpty ? my : recent.reduce(0, +) / Double(recent.count)
        return (slope * 30 / average * 100, slope * 30, average)
    }
    /// Sessions in a row, most recent last, since this lift last made progress:
    /// more load (less assistance), or the same load for more total reps. Zero
    /// while the lifter is rebuilding below their best load after a reset.
    public static func stallCount(exerciseID: String, loadMode: String, history: [JSONValue], before: Date, weeks: Int = 8) -> Int {
        let from = before.addingTimeInterval(-Double(weeks) * 7 * 86400)
        typealias Mark = (weight: Double, reps: Double)
        var marks: [(String, Mark)] = []
        for session in history where session["status"].text == "completed" {
            guard let start = NativeDate.parse(session["started_at"]), start >= from, start < before else { continue }
            for movement in session["exercises"].array where movement["exercise_id"].text == exerciseID && movement["load_mode"].text == loadMode {
                let factor = movement["unit"].text == "kg" ? 2.2046226 : 1
                let work = movement["sets"].array.filter { !$0["warmup"].flag && !$0["completed_at"].isNull && ($0["reps"].number ?? 0) > 0 }
                guard !work.isEmpty else { continue }
                if loadMode == "bodyweight" { marks.append((session["started_at"].text, (0, work.reduce(0) { $0 + ($1["reps"].number ?? 0) }))); continue }
                let weights = work.compactMap { $0["weight"].number }.map { $0 * factor }
                guard let top = loadMode == "assistance" ? weights.min() : weights.max() else { continue }
                let reps = work.filter { abs(($0["weight"].number ?? -1) * factor - top) < 0.05 }.reduce(0) { $0 + ($1["reps"].number ?? 0) }
                marks.append((session["started_at"].text, (top, reps)))
            }
        }
        marks.sort { $0.0 < $1.0 }
        guard var best = marks.first?.1 else { return 0 }
        func heavier(_ a: Double, _ b: Double) -> Bool { loadMode == "assistance" ? a < b - 0.05 : a > b + 0.05 }
        var count = 0
        for (_, mark) in marks.dropFirst() {
            if heavier(mark.weight, best.weight) || (abs(mark.weight - best.weight) < 0.05 && mark.reps > best.reps) { best = mark; count = 0 }
            else { count += 1 }
        }
        if let last = marks.last?.1, heavier(best.weight, last.weight) { return 0 }
        return count
    }
    public static let sleepTargetHours = 8.0
    /// Suggested bedtime in minutes after midnight: the median wake time of the
    /// last 14 main sleeps, minus the sleep need and the median awake time in bed,
    /// rounded to five minutes. Nil with fewer than five nights.
    public static func bedtime(sleeps: [JSONValue], needHours: Double, timezone: String) -> Int? {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: timezone) ?? .current
        let nights = sleeps.filter { !$0["is_nap"].flag && ($0["minutes_asleep"].number ?? 0) >= 180 }
            .sorted { $0["date"].text > $1["date"].text }.prefix(14)
        let wakes = nights.compactMap { NativeDate.parse($0["end_time"]) }.map { calendar.component(.hour, from: $0) * 60 + calendar.component(.minute, from: $0) }.sorted()
        guard wakes.count >= 5 else { return nil }
        let awake = nights.compactMap { n -> Double? in
            guard let bed = n["minutes_in_bed"].number, let asleep = n["minutes_asleep"].number, bed >= asleep else { return nil }
            return bed - asleep
        }.sorted()
        let awakeMedian = awake.isEmpty ? 15 : awake[awake.count / 2]
        let start = Double(wakes[wakes.count / 2]) - needHours * 60 - awakeMedian
        let rounded = Int((start / 5).rounded()) * 5
        return ((rounded % 1440) + 1440) % 1440
    }
    public static func postureDone(_ sessions: [NativeDaySession]) -> Bool {
        sessions.contains { $0.posture && $0.ratio > 0 }
    }
    /// Posture practice streak ending today: every practised day counts, a missed
    /// planned day (Gregorian weekdays in `planned`, 1 = Sunday) ends it, a missed
    /// unplanned day is skipped, and today does not break it before it is done.
    /// Returns the count and the streak's first day ("" when zero).
    public static func postureStreak(done: Set<String>, today: String, planned: Set<Int> = [1, 2, 3, 5], limit: Int = 90) -> (count: Int, start: String) {
        let parts = today.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return (0, "") }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "UTC")!
        guard let end = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) else { return (0, "") }
        let format = DateFormatter(); format.calendar = calendar; format.timeZone = calendar.timeZone
        format.locale = Locale(identifier: "en_US_POSIX"); format.dateFormat = "yyyy-MM-dd"
        var count = 0, start = ""
        for offset in 0..<limit {
            guard let date = calendar.date(byAdding: .day, value: -offset, to: end) else { break }
            let key = format.string(from: date)
            if done.contains(key) { count += 1; start = key }
            else if offset > 0 && planned.contains(calendar.component(.weekday, from: date)) { break }
        }
        return (count, start)
    }
}

public struct NativeLiftProgress: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let current: Double
    public let best: Double
    public var change: Double { current / best - 1 }
}
public struct NativeStrengthWeek: Equatable, Sendable {
    /// Median change against each lift's own recent best; nil without comparable lifts.
    public let change: Double?
    public let lifts: [NativeLiftProgress]
    /// Lifts done this week with no history in the baseline window.
    public let newCount: Int
    public var records: Int { lifts.filter { $0.change > 0.005 }.count }
}

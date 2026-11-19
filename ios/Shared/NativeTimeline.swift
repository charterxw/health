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
    public static func halves(_ sessions: [NativeDaySession]) -> [Double] {
        Array(sessions.filter { !$0.posture }.prefix(2).map(\.ratio))
    }
    public static func postureDone(_ sessions: [NativeDaySession]) -> Bool {
        sessions.contains { $0.posture && $0.ratio > 0 }
    }
}

import SwiftUI

// The weekly strength index and its per-lift detail page.
/// Week boundaries for the strength index, in the home timezone.
@MainActor enum NativeStrengthWeeks {
    static func calendar(_ timezone: String) -> Calendar {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: timezone) ?? .current; c.firstWeekday = 2; return c
    }
    static func sessions(_ store: NativeStore) -> [JSONValue] { store.history + (store.active.map { [$0.session] } ?? []) }
    static func current(store: NativeStore, timezone: String) -> NativeStrengthWeek {
        let now = Date(), start = calendar(timezone).dateInterval(of: .weekOfYear, for: now)?.start ?? now
        return NativeDays.strength(sessions: sessions(store), from: start, to: now.addingTimeInterval(60))
    }
    static func percent(_ change: Double) -> String {
        let value = (change * 1000).rounded() / 10
        return (value > 0 ? "+" : "") + String(format: "%.1f%%", value)
    }
}

struct NativeStrengthProgressView: View {
    @Environment(NativeStore.self) var store
    @Environment(\.dismiss) private var dismiss
    @PineReducedMotion private var reduceMotion
    /// Numbers roll up from zero and the rows arrive one after another.
    @State private var shown = false
    private var timezone: String { store.home["timezone"].text.isEmpty ? TimeZone.current.identifier : store.home["timezone"].text }
    var body: some View {
        let sessions = NativeStrengthWeeks.sessions(store)
        let calendar = NativeStrengthWeeks.calendar(timezone)
        let now = Date(), start = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? now
        let week = NativeDays.strength(sessions: sessions, from: start, to: now.addingTimeInterval(60))
        let past: [(Date, Double?)] = (1...8).map { offset -> (Date, Double?) in
            let from = calendar.date(byAdding: .day, value: -7 * offset, to: start) ?? start
            let to = calendar.date(byAdding: .day, value: 7, to: from) ?? start
            return (from, NativeDays.strength(sessions: sessions, from: from, to: to).change)
        }
        PinePage {
            VStack(spacing: 4) {
                Text(week.change.map { NativeStrengthWeeks.percent(shown ? $0 : 0) } ?? "—").font(.system(size: 56, weight: .semibold, design: .rounded)).monospacedDigit()
                    .foregroundStyle((week.change ?? 0) > 0.005 ? pine : Color.primary)
                    .contentTransition(.numericText(value: shown ? week.change ?? 0 : 0))
                Text(week.records > 0 ? "本周 \(week.records) 个动作超过近 4 周最好成绩" : "本周力量指数").font(.subheadline).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity).padding(.top, 8)
            Text("每个动作取本周最好的一组，按“重量 ×（1 + 次数 ÷ 30）”估算最大力量，和这个动作前 4 周的最好成绩比；所有动作取中位数。换动作或少练一个动作不会拉低它。自重动作比次数，辅助动作辅助越少越好。").font(.footnote).foregroundStyle(.secondary)
            if week.lifts.isEmpty {
                PineEmpty(title: "还没有可比较的动作", symbol: "chart.line.uptrend.xyaxis", detail: "本周练过、且前 4 周也练过的动作会出现在这里。")
            } else {
                PineSectionHeader(title: "本周动作")
                VStack(spacing: 0) {
                    ForEach(Array(week.lifts.enumerated()), id: \.element.id) { index, lift in
                        if index > 0 { Divider() }
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(lift.name).font(.subheadline.weight(.semibold))
                                Text(detail(lift)).font(.footnote).foregroundStyle(.secondary).monospacedDigit()
                            }
                            Spacer(minLength: 8)
                            Text(NativeStrengthWeeks.percent(shown ? lift.change : 0)).font(.subheadline.weight(.semibold)).monospacedDigit()
                                .foregroundStyle(lift.change > 0.005 ? pine : lift.change < -0.005 ? Color.secondary : Color.primary)
                                .contentTransition(.numericText(value: shown ? lift.change : 0))
                        }.padding(.vertical, 10)
                            .opacity(shown ? 1 : 0).offset(y: shown ? 0 : 10)
                            .animation(reduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.85).delay(0.15 + Double(index) * 0.06), value: shown)
                    }
                }.pineCard()
            }
            if week.newCount > 0 { Text("另有 \(week.newCount) 个动作前 4 周没练过，下周起参与比较。").font(.footnote).foregroundStyle(.secondary) }
            PineSectionHeader(title: "之前几周")
            VStack(spacing: 0) {
                ForEach(Array(past.enumerated()), id: \.offset) { index, item in
                    if index > 0 { Divider() }
                    HStack {
                        Text(NativeDate.label(item.0, format: "M月d日起", timezone: timezone)).font(.subheadline)
                        Spacer()
                        Text(item.1.map(NativeStrengthWeeks.percent) ?? "—").font(.subheadline.weight(.semibold)).monospacedDigit()
                            .foregroundStyle((item.1 ?? 0) > 0.005 ? pine : Color.secondary)
                    }.padding(.vertical, 10)
                }
            }.pineCard()
            volumeRow(sessions: sessions, calendar: calendar, start: start, now: now)
        }
        .navigationTitle("力量指数").navigationBarTitleDisplayMode(.inline)
        .onAppear {
            guard !shown else { return }
            if reduceMotion { shown = true } else { withAnimation(.smooth(duration: 0.9).delay(0.1)) { shown = true } }
        }
    }
    private func detail(_ lift: NativeLiftProgress) -> String {
        if lift.id.hasSuffix("|bodyweight") { return "最多 \(Int(lift.current)) 次 · 之前 \(Int(lift.best)) 次" }
        if lift.id.hasSuffix("|assistance") { return "辅助动作 · 按辅助重量和次数比较" }
        return "估算 " + displayNumber(.number(lift.current), digits: 0) + " 磅 · 之前 " + displayNumber(.number(lift.best), digits: 0) + " 磅"
    }
    /// Volume load stays available here as the amount of work, not progress.
    private func volumeRow(sessions: [JSONValue], calendar: Calendar, start: Date, now: Date) -> some View {
        let lastStart = calendar.date(byAdding: .day, value: -7, to: start) ?? start
        let lastNow = calendar.date(byAdding: .day, value: -7, to: now) ?? now
        let current = NativeDays.volume(records: store.records, from: start, to: now)
        let previous = NativeDays.volume(records: store.records, from: lastStart, to: lastNow)
        return VStack(spacing: 12) {
            PineRow(label: "本周容量（重量 × 次数）", value: displayNumber(.number(current), digits: 0) + " 磅")
            PineRow(label: "上周同期", value: displayNumber(.number(previous), digits: 0) + " 磅")
        }.pineCard()
    }
}

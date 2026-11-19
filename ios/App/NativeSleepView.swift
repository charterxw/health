import SwiftUI
import Charts

struct NativeSleepView: View {
    @Environment(NativeStore.self) var store
    private var nights: [JSONValue] { store.home["sleeps"].array.sorted { $0["date"].text > $1["date"].text } }
    var body: some View {
        PinePage {
            if let latest = nights.first(where: { !$0["is_nap"].flag }) ?? nights.first {
                NativeSleepNightContent(sleep: latest, timezone: store.home["timezone"].text)
                let main = Array(nights.filter { !$0["is_nap"].flag && $0["minutes_asleep"].number != nil }.prefix(7))
                if main.count > 1 {
                    HStack { Label("最近 \(main.count) 晚", systemImage: "moon").foregroundStyle(.secondary); Spacer(); Text("平均 " + sleepDuration(.number(main.reduce(0) { $0 + ($1["minutes_asleep"].number ?? 0) } / Double(main.count)))).fontWeight(.semibold) }.font(.subheadline).pineCard()
                }
                if nights.count > 1 {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("较早记录").font(.headline).padding(.bottom, 8)
                        ForEach(Array(nights.filter { $0 != latest }.enumerated()), id: \.offset) { i, sleep in
                            if i > 0 { Divider() }
                            NavigationLink { NativeSleepNightDetail(sleep: sleep) } label: {
                                HStack(spacing: 12) { VStack(alignment: .leading, spacing: 5) { Text(dayTitle(sleep["date"].text, format: "M月d日 EEE") + (sleep["is_nap"].flag ? " · 小睡" : "")).font(.subheadline.weight(.semibold)).foregroundStyle(.primary); Text(sleepWindow(sleep, timezone: store.home["timezone"].text)).font(.caption).foregroundStyle(.secondary) }; Spacer(minLength: 4); Text(sleepDuration(sleep["minutes_asleep"])).font(.subheadline).foregroundStyle(.primary); Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary) }.frame(minHeight: 64).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                    }.pineCard()
                }
            } else { PineEmpty(title: "暂无详细睡眠记录", symbol: "moon", detail: "下拉刷新，读取已同步的睡眠数据。") }
        }.navigationTitle("睡眠与作息").navigationBarTitleDisplayMode(.inline).refreshable { await store.refreshHealth() }
    }
}
struct NativeSleepNightDetail: View {
    @Environment(NativeStore.self) var store
    let sleep: JSONValue
    var body: some View { PinePage { NativeSleepNightContent(sleep: sleep, timezone: store.home["timezone"].text) }.navigationTitle("睡眠详情").navigationBarTitleDisplayMode(.inline) }
}
private struct NativeSleepNightContent: View {
    let sleep: JSONValue
    let timezone: String
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .largeTitle) private var numberSize: CGFloat = 34
    private var asleep: JSONValue {
        if !sleep["minutes_asleep"].isNull { return sleep["minutes_asleep"] }
        let values = ["total_rem_mins", "total_light_mins", "total_deep_mins"].compactMap { sleep[$0].number }
        return values.count == 3 ? .number(values.reduce(0, +)) : .null
    }
    private var inBed: JSONValue {
        if !sleep["minutes_in_bed"].isNull { return sleep["minutes_in_bed"] }
        let values = ["total_awake_mins", "total_rem_mins", "total_light_mins", "total_deep_mins"].compactMap { sleep[$0].number }
        return values.count == 4 ? .number(values.reduce(0, +)) : .null
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                HStack { Text(dayTitle(sleep["date"].text, format: "M月d日 EEE")).font(.subheadline.weight(.medium)); Spacer(); if sleep["is_nap"].flag { Text("小睡").font(.caption).padding(5).background(Color(uiColor: .tertiarySystemFill), in: Capsule()) } }.foregroundStyle(.secondary)
                Text(sleepWindow(sleep, timezone: timezone)).font(.subheadline).foregroundStyle(.secondary)
                if let value = asleep.number {
                    let minutes = Int(value.rounded())
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("\(minutes / 60)").font(.system(size: numberSize, weight: .bold, design: .rounded)).monospacedDigit()
                        Text("小时").font(.subheadline).foregroundStyle(.secondary)
                        Text("\(minutes % 60)").font(.system(size: numberSize, weight: .bold, design: .rounded)).monospacedDigit()
                        Text("分").font(.subheadline).foregroundStyle(.secondary)
                    }.accessibilityElement(children: .ignore).accessibilityLabel("实际睡眠 " + sleepDuration(asleep))
                } else { Text("睡眠时长未记录").font(.title2.bold()) }
                Text("卧床 " + sleepDuration(inBed)).font(.subheadline).foregroundStyle(.secondary)
            }
            NativeSleepStageChart(stages: sleep["stages"].array, timezone: timezone)
            LazyVGrid(columns: typeSize.isAccessibilitySize ? [GridItem(.flexible())] : [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 12) {
                stageLegend("清醒", key: "total_awake_mins", color: .pink)
                stageLegend("快速眼动", key: "total_rem_mins", color: .cyan)
                stageLegend("浅睡", key: "total_light_mins", color: .blue)
                stageLegend("深睡", key: "total_deep_mins", color: .indigo)
            }
        }.pineCard()
        if !sleep["is_nap"].flag {
            VStack(alignment: .leading, spacing: 14) {
                NativeSectionTitle(title: "恢复指标", detail: "与个人基线对比")
                LazyVGrid(columns: typeSize.isAccessibilitySize ? [GridItem(.flexible())] : [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 10) {
                    recovery("睡眠效率", value: displayNumber(sleep["sleep_efficiency_percent"]) + (sleep["sleep_efficiency_percent"].isNull ? "" : "%"), detail: "睡眠时间 ÷ 卧床时间")
                    recovery("平均血氧", value: displayNumber(sleep["spo2_average"]) + (sleep["spo2_average"].isNull ? "" : "%"), detail: sleep["spo2_lower_bound"].isNull || sleep["spo2_upper_bound"].isNull ? "暂无区间记录" : displayNumber(sleep["spo2_lower_bound"]) + "–" + displayNumber(sleep["spo2_upper_bound"]) + "% 区间")
                    recovery("呼吸频率", value: displayNumber(sleep["respiratory_rate"]), detail: "次/分钟")
                    recovery("腕部皮温", value: temperature, detail: "相对个人基线")
                    recovery("入睡用时", value: displayNumber(sleep["sleep_latency_minutes"], digits: 0) + (sleep["sleep_latency_minutes"].isNull ? "" : " 分钟"), detail: "自动识别的记录可能为 0")
                    recovery("清醒次数", value: displayNumber(sleep["awake_periods"], digits: 0), detail: sleep["short_awakenings"].isNull ? "清醒阶段次数" : "\(sleep["short_awakenings"].integer) 次短暂清醒")
                }
                Text("血氧、呼吸和腕部皮温用于了解健康趋势，不能作为诊断依据。").font(.caption).foregroundStyle(.secondary)
            }.pineCard()
        }
    }
    private var temperature: String { guard let n = sleep["skin_temperature_delta_c"].number else { return "—" }; return (n > 0 ? "+" : "") + displayNumber(.number(n), digits: 2) + "°C" }
    private func stageLegend(_ title: String, key: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 6) { Circle().fill(color).frame(width: 7, height: 7).padding(.top, 5); VStack(alignment: .leading, spacing: 3) { Text(title).font(.caption).foregroundStyle(.secondary); Text(sleepDuration(sleep[key])).font(.subheadline.weight(.medium)) } }.accessibilityElement(children: .combine)
    }
    private func recovery(_ title: String, value: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 8) { Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary); Text(value).font(.title2.bold()).monospacedDigit().fixedSize(horizontal: false, vertical: true); Text(detail).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }.padding(12).frame(maxWidth: .infinity, minHeight: 106, alignment: .topLeading).background(Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14)).accessibilityElement(children: .combine)
    }
}
struct NativeSleepStageChart: View {
    let stages: [JSONValue]
    let timezone: String
    @ScaledMetric(relativeTo: .caption) private var rowHeight: CGFloat = 26
    private let names = ["清醒", "快速眼动", "浅睡", "深睡"]
    private let keys = ["AWAKE", "REM", "LIGHT", "DEEP"]
    private let colors: [Color] = [.pink, .cyan, .blue, .indigo]
    var body: some View {
        let intervals = stages.compactMap { stage -> (start: Date, end: Date, row: Int)? in
            guard let start = NativeDate.parse(stage["startTime"]), let end = NativeDate.parse(stage["endTime"]), end > start, let row = keys.firstIndex(of: stage["stage"].text) else { return nil }
            return (start, end, row)
        }
        if let first = intervals.map(\.start).min(), let last = intervals.map(\.end).max(), last > first {
            VStack(spacing: 8) {
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(names, id: \.self) { Text($0).font(.caption2).foregroundStyle(.secondary).frame(height: rowHeight) }
                    }
                    Canvas { context, size in
                        let duration = last.timeIntervalSince(first)
                        let height = size.height / 4
                        for row in 0..<4 {
                            let track = CGRect(x: 0, y: (CGFloat(row) + 0.5) * height - 4, width: size.width, height: 8)
                            context.fill(Path(roundedRect: track, cornerRadius: 4), with: .color(Color(uiColor: .tertiarySystemFill)))
                        }
                        for item in intervals {
                            let x = item.start.timeIntervalSince(first) / duration * size.width
                            let end = item.end.timeIntervalSince(first) / duration * size.width
                            let rect = CGRect(x: x, y: (CGFloat(item.row) + 0.5) * height - 4, width: max(1, end - x), height: 8)
                            context.fill(Path(roundedRect: rect, cornerRadius: 4), with: .color(colors[item.row]))
                        }
                    }.frame(height: rowHeight * 4)
                }
                HStack { Text(NativeDate.label(first, format: "HH:mm", timezone: timezone)); Spacer(); Text(NativeDate.label(last, format: "HH:mm", timezone: timezone)) }.font(.caption2).foregroundStyle(.secondary)
            }.accessibilityElement(children: .ignore).accessibilityLabel("睡眠阶段时间图，从清醒、快速眼动、浅睡到深睡，空白处没有记录。" + NativeDate.label(first, format: "HH:mm", timezone: timezone) + " 至 " + NativeDate.label(last, format: "HH:mm", timezone: timezone))
        } else { Text("这晚没有睡眠阶段明细。").font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 80) }
    }
}
private func sleepWindow(_ sleep: JSONValue, timezone: String) -> String {
    let stages = sleep["stages"].array.sorted { $0["startTime"].text < $1["startTime"].text }
    return clockLabel(stages.first?["startTime"] ?? sleep["start_time"], timezone: timezone) + "–" + clockLabel(stages.last?["endTime"] ?? sleep["end_time"], timezone: timezone)
}

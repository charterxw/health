import SwiftUI
import Charts

struct MetricSelection: Identifiable { let id: String; let title: String; let unit: String }
struct NativeDashboardView: View {
    @Environment(NativeStore.self) var store
    @PineReducedMotion private var reduceMotion
    @AppStorage("pine.records.calendar") private var recordsCalendar = false
    @State private var selectedDay = ""
    @State private var metric: MetricSelection?
    @State private var showingGoals = false
    @State private var showingFeedback = false
    @State private var showingDay = false
    @State private var showingSync = false
    private var home: JSONValue { store.home }
    private var day: JSONValue { home["days"].array.first { $0["date"].text == selectedDay } ?? home["days"].array.first { $0["date"] == home["date"] } ?? .null }
    private var isToday: Bool { day["date"] == home["date"] }
    private var timezone: String { home["timezone"].text.isEmpty ? TimeZone.current.identifier : home["timezone"].text }
    var body: some View {
        // Computed once per render; the week shares one grouping of local records.
        let sessions = NativeDays.sessions(records: store.records, timezone: timezone)
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                syncRow
                if home.isNull { PineEmpty(title: "等待健康数据", symbol: "heart.text.square", detail: "下拉或点上方的同步状态重试。") }
                else {
                    observation.padding(.top, 8)
                    HStack(alignment: .firstTextBaseline) {
                        Text(isToday ? "今天的目标" : "这天的目标").font(.title3.weight(.semibold))
                        Spacer()
                        Text(isToday ? "今日" : dayTitle(day["date"].text, format: "M/d")).font(.subheadline).foregroundStyle(.secondary).accessibilityIdentifier("home-selected-date")
                    }.padding(.top, 22)
                    goalsCard(sessions[day["date"].text] ?? []).padding(.top, 8)
                    HStack(alignment: .firstTextBaseline) {
                        Text("本周").font(.title3.weight(.semibold))
                        Spacer()
                        Button("目标") { showingGoals = true }.font(.subheadline).frame(minWidth: 44, minHeight: 44)
                        Button("日历") { recordsCalendar = true; store.selectedTab = 2 }.font(.subheadline).frame(minWidth: 44, minHeight: 44)
                    }.padding(.top, 14)
                    weekCard(sessions).padding(.top, 2)
                    bodyList.padding(.top, 12)
                }
            }.padding(.horizontal, 20).padding(.bottom, 24)
        }
        .background(pineCanvas)
        .navigationTitle(home.isNull ? "今天" : dayTitle(home["date"].text, format: "M月d日 EEE")).navigationBarTitleDisplayMode(.large)
        .refreshable { await store.refresh(); await store.refreshHealth() }
        .sheet(item: $metric) { item in NavigationStack { NativeMetricDetail(metric: item) } }
        .sheet(isPresented: $showingGoals) { NavigationStack { NativeGoalsView() } }
        .sheet(isPresented: $showingFeedback) { NavigationStack { NativeFeedbackView() } }
        .sheet(isPresented: $showingDay) { NavigationStack { NativeDayDetail(day: day) } }
        .sheet(isPresented: $showingSync) { NavigationStack { NativeSyncDetail() } }
        .task(id: store.brief["status"].text) {
            guard !store.isDesignPreview, store.brief["status"].text == "pending" else { return }
            for _ in 0..<60 {
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
                await store.loadBrief(); if store.brief["status"].text != "pending" { return }
            }
        }
    }

    // MARK: Sync and feelings
    private var busy: Bool { store.refreshing || store.healthRefreshing }
    private var syncText: String {
        if busy { return "正在从 Google 更新" }
        if store.message != nil { return "同步需重试" }
        guard let date = NativeDate.parse(home["sources"]["metrics"]["fetched_at"]) else { return "数据与同步" }
        let sameDay = NativeDate.day(date, timezone: timezone) == home["date"].text
        return NativeDate.label(date, format: sameDay ? "HH:mm" : "M/d HH:mm", timezone: timezone) + " 从 Google 更新"
    }
    private var feelings: String { [home["feedback"]["energy"].text, home["feedback"]["fatigue"].text].filter { !$0.isEmpty }.joined(separator: " · ") }
    private var syncRow: some View {
        HStack(spacing: 8) {
            Button { showingSync = true } label: {
                HStack(spacing: 6) {
                    if busy { ProgressView().controlSize(.mini) }
                    else { Image(systemName: store.message == nil ? "arrow.clockwise" : "exclamationmark.circle").imageScale(.small) }
                    Text(syncText)
                }.font(.footnote).foregroundStyle(.secondary).frame(minHeight: 44)
            }.buttonStyle(PinePressStyle()).accessibilityLabel("数据与同步，" + syncText)
            Spacer(minLength: 8)
            Button { showingFeedback = true } label: {
                Label(feelings.isEmpty ? "记录感受" : feelings, systemImage: feelings.isEmpty ? "plus" : "face.smiling").font(.footnote.weight(.semibold)).frame(minHeight: 44)
            }.buttonStyle(PinePressStyle()).accessibilityIdentifier("home-feelings")
        }
    }

    // MARK: Observation
    private var observation: some View {
        let lines = store.brief["sentences"].array.map { $0.text.isEmpty ? $0["text"].text : $0.text }.filter { !$0.isEmpty }
        let summary = lines.isEmpty ? home["tip"].text : lines.joined(separator: " ")
        let evening = store.brief["title"].text.contains("晚") || store.brief["period"].text == "evening"
        return NavigationLink { NativeBriefDetail() } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: evening ? "moon" : "sun.max").font(.body.weight(.semibold)).foregroundStyle(pine).padding(.top, 2)
                Text(summary).font(.body).foregroundStyle(.primary).multilineTextAlignment(.leading).lineLimit(4).frame(maxWidth: .infinity, alignment: .leading)
            }.padding(16).background(pineSurface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }.buttonStyle(PinePressStyle()).accessibilityIdentifier("home-observation").accessibilityHint("点按查看完整观察")
    }

    // MARK: Goals of the selected day
    private func activityFraction(_ row: JSONValue) -> Double? {
        guard let value = row["activity"].number, let goal = row["goals"]["dailyActivity"].number, goal > 0 else { return nil }
        return value / goal
    }
    private func strengthPlanned(_ row: JSONValue) -> Bool { row["strength_planned"].flag || row["strength_optional"].flag || row["target"].integer > 0 }
    private func halves(_ row: JSONValue, _ sessions: [NativeDaySession]) -> [Double] {
        let done = NativeDays.halves(sessions)
        return strengthPlanned(row) ? done + Array(repeating: 0, count: max(0, 2 - done.count)) : done
    }
    private func postureDone(_ row: JSONValue, _ sessions: [NativeDaySession]) -> Bool { row["posture"].flag || NativeDays.postureDone(sessions) }
    private func goalsCard(_ sessions: [NativeDaySession]) -> some View {
        let future = day["date"].text > home["date"].text
        let fraction = activityFraction(day)
        let target = day["target"].integer, sets = day["sets"].integer
        let places = sessions.filter { !$0.posture }.map { $0.title.contains("公司") ? "公司" : $0.title.contains("家庭") ? "家庭" : "训练" }
        let strengthText: String = {
            guard strengthPlanned(day) else { return places.isEmpty ? "今天休息" : places.joined(separator: "、") + "已练" }
            let optional = day["strength_optional"].flag ? " · 可选" : ""
            if places.isEmpty { return (future ? "计划 " : "待练 · ") + "\(sets) / \(target) 组" + optional }
            return places.joined(separator: "、") + "已练 · \(sets) / \(target) 组" + optional
        }()
        let posture = sessions.last { $0.posture }
        let postureText: String = {
            if let posture, let start = posture.start {
                let minutes = posture.end.map { max(1, Int(($0.timeIntervalSince(start) / 60).rounded())) }
                return NativeDate.label(start, format: "HH:mm", timezone: timezone) + (minutes.map { " · \($0) 分钟" } ?? "")
            }
            if day["posture"].flag { return "已完成" }
            return day["posture_planned"].flag ? (future ? "计划练习" : "待完成") : "今天不安排"
        }()
        let activityText = displayNumber(day["activity"], digits: 0) + " / " + displayNumber(day["goals"]["dailyActivity"], digits: 0) + " 千卡"
        return Button { showingDay = true } label: {
            HStack(spacing: 16) {
                PineDayGlyph(activity: fraction, halves: halves(day, sessions), posture: postureDone(day, sessions), future: future, size: 104)
                VStack(spacing: 0) {
                    goalLine("活动 · 外圈", activityText, done: (fraction ?? 0) >= 1)
                    Divider()
                    goalLine("力量 · 中圈", strengthText, done: target > 0 && sets >= target)
                    Divider()
                    goalLine("体态 · 圆点", postureText, done: postureDone(day, sessions))
                }
            }.padding(16).frame(maxWidth: .infinity).background(pineSurface, in: RoundedRectangle(cornerRadius: 20, style: .continuous)).contentShape(Rectangle())
        }.buttonStyle(PinePressStyle()).accessibilityElement(children: .combine).accessibilityHint("点按查看这天的详细记录")
    }
    private func goalLine(_ title: String, _ detail: String, done: Bool) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                Text(detail).font(.footnote).foregroundStyle(.secondary).monospacedDigit()
            }.frame(maxWidth: .infinity, alignment: .leading)
            if done { Image(systemName: "checkmark").font(.subheadline.weight(.semibold)).foregroundStyle(pine).accessibilityLabel("已完成") }
        }.frame(minHeight: 46)
    }

    // MARK: Week
    private func weekCard(_ sessions: [String: [NativeDaySession]]) -> some View {
        let days = home["days"].array
        let past = days.filter { $0["date"].text <= home["date"].text }
        let energy = past.compactMap { $0["activity"].number }
        return VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(Array(days.enumerated()), id: \.element["date"].text) { index, row in
                    let date = row["date"].text, list = sessions[date] ?? []
                    let selected = date == day["date"].text, future = date > home["date"].text
                    Button {
                        guard date != day["date"].text else { return }
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { selectedDay = date }
                    } label: {
                        VStack(spacing: 4) {
                            Text(["一","二","三","四","五","六","日"][min(index, 6)]).font(.caption.weight(selected ? .bold : .regular)).foregroundStyle(selected ? pine : Color.secondary)
                            PineDayGlyph(activity: activityFraction(row), halves: halves(row, list), posture: postureDone(row, list), future: future, size: 36)
                            Text(planLabel(row["short"].text)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }.frame(maxWidth: .infinity, minHeight: 76).padding(.vertical, 4)
                            .background(selected ? pineTint : .clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .contentShape(Rectangle())
                    }.buttonStyle(PinePressStyle(scale: 0.97))
                        .accessibilityLabel(weekAccessibility(row, list))
                        .accessibilityIdentifier("home-day-" + date)
                        .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            Divider().padding(.top, 10)
            HStack(alignment: .top) {
                weekTotal("活动", energy.isEmpty ? "—" : displayNumber(.number(energy.reduce(0, +)), digits: 0), "/ " + displayNumber(home["goals"]["weeklyActivity"], digits: 0))
                weekTotal("力量", "\(past.filter { $0["sets"].integer > 0 }.count)", "/ \(home["goals"]["weeklyStrength"].integer) 天")
                weekTotal("体态", "\(past.filter { $0["posture"].flag }.count)", "/ \(home["goals"]["weeklyPosture"].integer) 天")
            }.padding(.top, 10)
        }.padding(12).background(pineSurface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
    private func weekTotal(_ title: String, _ value: String, _ target: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 3) { Text(value).font(.headline).monospacedDigit(); Text(target).font(.caption).foregroundStyle(.secondary) }
        }.frame(maxWidth: .infinity, alignment: .leading).accessibilityElement(children: .combine)
    }
    private func weekAccessibility(_ row: JSONValue, _ sessions: [NativeDaySession]) -> String {
        let title = dayTitle(row["date"].text) + "，" + planLabel(row["short"].text)
        if row["date"].text > home["date"].text { return title + "，未来日期" }
        return title + "，日常活动 " + displayNumber(row["activity"], digits: 0) + " 千卡，力量 \(row["sets"].integer)/\(row["target"].integer) 组，体态" + (postureDone(row, sessions) ? "已完成" : row["posture_planned"].flag ? "待完成" : "未安排")
    }

    // MARK: Body
    private var bodyList: some View {
        let steps = home["today"]["steps"].number, goal = home["step_goal"]["target"].number
        let stepsDetail: String = {
            guard let steps, let goal, goal > 0 else { return "" }
            return steps >= goal ? "超出 " + displayNumber(.number(steps - goal), digits: 0) : "还差 " + displayNumber(.number(goal - steps), digits: 0)
        }()
        return VStack(spacing: 0) {
            NavigationLink(value: NativeOverviewRoute.recovery) {
                listRow("恢复", home["recovery"]["score"], home["recovery"]["label"].text.isEmpty ? "待更新" : home["recovery"]["label"].text)
            }.buttonStyle(PinePressStyle()).accessibilityIdentifier("recovery-score")
            Divider().padding(.leading, 16)
            Button { metric = MetricSelection(id: "steps", title: "今日步数", unit: "步") } label: {
                listRow("步数", home["today"]["steps"], stepsDetail)
            }.buttonStyle(PinePressStyle()).accessibilityIdentifier("metric-steps")
        }.background(pineSurface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
    private func listRow(_ title: String, _ value: JSONValue, _ detail: String) -> some View {
        HStack(spacing: 8) {
            Text(title).foregroundStyle(.primary)
            Spacer(minLength: 8)
            Text(displayNumber(value, digits: 0)).fontWeight(.semibold).monospacedDigit().foregroundStyle(.primary)
                .contentTransition(reduceMotion ? .identity : .numericText(value: value.number ?? 0))
                .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: value.number)
            if !detail.isEmpty { Text(detail).font(.subheadline).foregroundStyle(.secondary) }
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
        }.padding(.horizontal, 16).frame(minHeight: 50).contentShape(Rectangle())
    }
}
private struct NativeHomeBrief: View {
    let brief: JSONValue
    let tip: String
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        let lines = brief["sentences"].array.map { $0.text.isEmpty ? $0["text"].text : $0.text }.filter { !$0.isEmpty }
        let summary = lines.isEmpty ? tip : lines.joined(separator: " ")
        let compactHeight: CGFloat = lines.count > 1 || summary.count > 48 ? 120 : 104
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) { Circle().fill(postureColor).frame(width: 6, height: 6); Text(brief["title"].text.isEmpty ? "今日观察" : brief["title"].text).font(.caption.weight(.medium)).foregroundStyle(.secondary); Spacer(); Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary) }
            Text(summary).font(.subheadline).foregroundStyle(.primary).lineSpacing(2)
                .lineLimit(typeSize > .large ? nil : 4)
                .frame(maxWidth: .infinity, alignment: .leading)
        }.padding(12).frame(maxWidth: .infinity, minHeight: typeSize > .large ? nil : compactHeight, maxHeight: typeSize > .large ? nil : compactHeight, alignment: .leading)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
            .accessibilityHint("点按查看完整观察")
    }
}
private struct NativeHomeMetric: View {
    let title: String
    let value: JSONValue
    var unit = ""
    let detail: String
    var progress: Double?
    @Environment(\.dynamicTypeSize) private var typeSize
    @PineReducedMotion private var reduceMotion
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack { Text(title).font(.caption).foregroundStyle(.secondary); Spacer(minLength: 0); Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary) }
            NativeMetricNumber(value: value, unit: unit)
            Text(detail).font(.caption).foregroundStyle(.secondary)
            if let progress {
                ProgressView(value: progress).tint(postureColor).accessibilityLabel("每日步数进度")
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.20), value: progress)
            }
        }.padding(12).frame(maxWidth: .infinity, minHeight: 112, maxHeight: typeSize > .large ? nil : 112, alignment: .topLeading).background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
    }
}
struct SmallDotLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View { HStack(spacing: 5) { configuration.icon.font(.system(size: 5)); configuration.title } }
}
struct NativeWeekDay: View {
    let day: JSONValue
    let name: String
    let today: Bool
    let selected: Bool
    var compact = false
    @ScaledMetric(relativeTo: .caption) private var daySize: CGFloat = 25
    var body: some View {
        VStack(spacing: compact ? 4 : 8) {
            Text(today ? "今" : name).font(.caption.weight(selected ? .semibold : .regular)).foregroundStyle(today ? Color(uiColor: .systemBackground) : selected ? pine : .secondary).frame(width: daySize, height: daySize).background(today ? Color.primary : selected ? pine.opacity(0.1) : .clear, in: Circle())
            ZStack {
                PineRing(fraction: activityRatio, color: activityColor, width: 3)
                PineRing(fraction: day["target"].integer > 0 ? Double(day["sets"].integer) / Double(day["target"].integer) : nil, color: strengthColor, width: 3).padding(5)
                PineRing(fraction: day["posture_planned"].flag || day["posture"].flag ? day["posture"].flag ? 1 : 0 : nil, color: postureColor, width: 3).padding(10)
            }.frame(width: 32, height: 32)
            Text(day["short"].text).font(.caption2).foregroundStyle(.secondary)
        }.frame(minWidth: max(44, daySize), minHeight: compact ? 72 : 88).contentShape(Rectangle()).accessibilityHidden(true)
    }
    private var activityRatio: Double? { guard let v = day["activity"].number, let goal = day["goals"]["dailyActivity"].number, goal > 0 else { return nil }; return v / goal }
}
struct NativeGoalRow: View {
    let title: String
    let color: Color
    let daily: JSONValue
    let dailyTarget: String
    let weekly: JSONValue
    let weeklyTarget: String
    let action: () -> Void
    @PineReducedMotion private var reduceMotion
    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                HStack(spacing: 7) { Circle().fill(color).frame(width: 5, height: 5); Text(title).font(.subheadline).foregroundStyle(.primary) }.frame(maxWidth: .infinity, alignment: .leading)
                number(daily, target: dailyTarget).frame(maxWidth: .infinity, alignment: .trailing)
                number(weekly, target: weeklyTarget).frame(maxWidth: .infinity, alignment: .trailing)
            }.frame(minHeight: 44).contentShape(Rectangle())
        }.buttonStyle(PinePressStyle()).accessibilityElement(children: .combine)
    }
    private func number(_ value: JSONValue, target: String) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 3) { if !value.isNull { mainNumber(value) }; Text(target).font(.caption).foregroundStyle(.secondary).fixedSize() }
            VStack(alignment: .trailing, spacing: 2) { if !value.isNull { mainNumber(value) }; Text(target).font(.caption).foregroundStyle(.secondary) }
        }
    }
    private func mainNumber(_ value: JSONValue) -> some View {
        Text(displayNumber(value, digits: 0))
            .font(.title3.weight(.semibold)).foregroundStyle(.primary).monospacedDigit()
            .contentTransition(reduceMotion ? .identity : .numericText(value: value.number ?? 0))
            .transaction { if reduceMotion { $0.animation = nil } }
    }
}
struct NativeOverviewLink: View {
    let title: String
    let value: String
    let symbol: String
    let color: Color
    var body: some View { HStack(spacing: 10) { Image(systemName: symbol).foregroundStyle(color).frame(width: 22); Text(title).font(.subheadline).foregroundStyle(.primary); Spacer(minLength: 5); Text(value).font(.caption).foregroundStyle(.secondary); Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary) }.frame(minHeight: 44).contentShape(Rectangle()) }
}
struct NativeBriefDetail: View {
    @Environment(NativeStore.self) var store
    var body: some View {
        PinePage {
            let brief = store.brief
            ForEach(Array(brief["sentences"].array.enumerated()), id: \.offset) { _, row in Text(row.text.isEmpty ? row["text"].text : row.text).font(.body).lineSpacing(6).frame(maxWidth: .infinity, alignment: .leading).pineCard() }
            if brief["sentences"].array.isEmpty { Text(store.home["tip"].text).pineCard() }
            PineRow(label: "记录日期", value: store.home["date"].text)
            if !brief["generated_at"].isNull { PineRow(label: "观察更新", value: dateLabel(brief["generated_at"])) }
            NavigationLink("查看恢复依据") { NativeRecoveryContent() }
            NavigationLink("历史观察") { NativeObservationsView() }
            Button(brief["status"].text == "pending" ? "正在分析…" : "重新分析", systemImage: "arrow.clockwise") { Task { await store.loadBrief(generate: true) } }.buttonStyle(.bordered).disabled(store.isDesignPreview || brief["status"].text == "pending")
        }.navigationTitle(store.brief["title"].text.isEmpty ? "今日观察" : store.brief["title"].text).navigationBarTitleDisplayMode(.inline)
    }
}
struct NativeSyncDetail: View {
    @Environment(NativeStore.self) var store
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        Form {
            if let message = store.message { Section { Text(message).font(.subheadline) } }
            Section("实际记录时间") {
                PineRow(label: "步数", value: dateLabel(store.home["freshness"]["records"]["steps"]["observed_at"]))
                PineRow(label: "活动热量", value: dateLabel(store.home["freshness"]["records"]["activity"]["observed_at"]))
                PineRow(label: "设备同步", value: dateLabel(store.home["freshness"]["device"]["last_sync_at"]))
            }
            Section("App 最近读取") { ForEach(store.home["sources"].object.keys.sorted(), id: \.self) { key in PineRow(label: ["metrics":"每日指标","sleep":"睡眠","weight":"体重","activity":"活动拆分","walks":"散步记录"][key] ?? key, value: dateLabel(store.home["sources"][key]["fetched_at"])) } }
            Button("重新读取数据", systemImage: "arrow.clockwise") { Task { await store.refreshHealth() } }.disabled(store.healthRefreshing || store.isDesignPreview)
        }.navigationTitle("数据与同步").toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
    }
}

struct NativeMetricDetail: View {
    @Environment(\.dismiss) private var dismiss
    let metric: MetricSelection
    var body: some View { NativeMetricContent(metric: metric).toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } } }
}
struct NativeMetricContent: View {
    @Environment(NativeStore.self) var store
    let metric: MetricSelection
    var body: some View {
        let rows = store.home["metrics"].array.sorted { $0["date"].text > $1["date"].text }
        PinePage {
            Text(displayNumber(healthValue(store.home["today"][metric.id], key: metric.id)) + " " + metric.unit).font(.largeTitle.bold())
            MetricChart(rows: Array(rows.prefix(28).reversed()), key: metric.id).pineCard()
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in PineRow(label: row["date"].text, value: displayNumber(healthValue(row[metric.id], key: metric.id)) + " " + metric.unit) }
        }.navigationTitle(metric.title).navigationBarTitleDisplayMode(.inline)
    }
}

struct NativeGoalsView: View {
    @Environment(NativeStore.self) var store
    @Environment(\.dismiss) private var dismiss
    @State private var steps = 8000
    @State private var daily = 300
    @State private var weekly = 2100
    @State private var strength = 4
    @State private var posture = 4
    @State private var error: String?
    @State private var busy = false
    var body: some View {
        Form {
            Section("日常走动") { TextField("每日步数", value: $steps, format: .number).keyboardType(.numberPad); Button("保存步数目标") { save(stepsOnly: true) }.disabled(busy || !(1000...50000).contains(steps)) }
            Section { TextField("每日活动千卡", value: $daily, format: .number).keyboardType(.numberPad); TextField("每周活动千卡", value: $weekly, format: .number).keyboardType(.numberPad); Stepper("力量训练 \(strength) 天", value: $strength, in: 1...7); Stepper("体态练习 \(posture) 天", value: $posture, in: 1...7) } header: { Text("从下周起生效") } footer: { Text("生效日期：" + store.home["next_effective"].text) }
            if let error { Text(error).foregroundStyle(.red) }
            Button("保存下周目标") { save(stepsOnly: false) }.disabled(busy || !(1...3000).contains(daily) || !(1...21000).contains(weekly))
        }.navigationTitle("调整目标").toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
            .onAppear { let g = store.home["next_goals"].or(store.home["goals"]); steps = store.home["step_goal"]["target"].integer; daily = g["dailyActivity"].integer; weekly = g["weeklyActivity"].integer; strength = max(1,g["weeklyStrength"].integer); posture = max(1,g["weeklyPosture"].integer) }
    }
    private func save(stepsOnly: Bool) {
        busy = true
        Task { do { try await store.mutateHome(stepsOnly ? "/home/step-goal" : "/home/goals", body: stepsOnly ? ["target": .number(Double(steps))] : ["dailyActivity": .number(Double(daily)), "weeklyActivity": .number(Double(weekly)), "weeklyStrength": .number(Double(strength)), "weeklyPosture": .number(Double(posture))]); dismiss() } catch { self.error = error.localizedDescription }; busy = false }
    }
}
struct NativeFeedbackView: View {
    @Environment(NativeStore.self) var store
    @Environment(\.dismiss) private var dismiss
    @State private var energy = ""
    @State private var fatigue = ""
    @State private var busy = false
    @State private var error: String?
    var body: some View {
        Form {
            Picker("精神", selection: $energy) { Text("未记录").tag(""); ForEach(["充沛","一般","困倦"], id: \.self) { Text($0).tag($0) } }
            Picker("疲劳", selection: $fatigue) { Text("未记录").tag(""); ForEach(["轻","中","重"], id: \.self) { Text($0).tag($0) } }
            if let error { Text(error).foregroundStyle(.red) }
            Button("保存今天的感受") { busy = true; Task { do { try await store.mutateHome("/home/feedback", body: ["energy": energy.isEmpty ? .null : .string(energy), "fatigue": fatigue.isEmpty ? .null : .string(fatigue)]); dismiss() } catch { self.error = error.localizedDescription }; busy = false } }.disabled(busy)
        }.navigationTitle("今天的感受").toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }.onAppear { energy = store.home["feedback"]["energy"].text; fatigue = store.home["feedback"]["fatigue"].text }
    }
}

struct NativePlanView: View {
    @Environment(NativeStore.self) var store
    @Environment(\.dismiss) private var dismiss
    @State private var session = ""
    @State private var slot = 0
    @State private var confirmNext = false
    @State private var error: String?
    @State private var busy = false
    private var plan: JSONValue { store.home["plan"] }
    var body: some View {
        List {
            Section {
                Text("\(plan["done"].integer) / \(plan["target"].integer) 工作组").font(.title2.bold())
                Text("本轮可以跨周，可选 E 不影响主训练进度。").font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(Array(plan["schedule"].array.enumerated()), id: \.offset) { _, day in
                Section("第\(day["day"].integer)天 · " + day["letter"].text + (day["optional"].flag ? " · 可选" : "")) {
                    ForEach(Array(day["slots"].array.enumerated()), id: \.offset) { _, item in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(item["name"].text).font(.headline)
                            HStack { Text("\(item["done"].integer)/\(item["target"].integer) 组").font(.subheadline).foregroundStyle(.secondary); Spacer(); if item["completed"].flag { Image(systemName: "checkmark.circle.fill").foregroundStyle(pine) } else { Button(item["done"].integer > 0 ? "继续" : "开始") { dismiss(); store.homeAction(["template_id": item["template_id"], "remaining": item["remaining"]]) }.buttonStyle(.bordered) } }
                        }.padding(.vertical, 4)
                    }
                }
            }
            if !plan.isNull {
                Section("关联补练") {
                    Picker("训练记录", selection: $session) { Text("选择已完成训练").tag(""); ForEach(store.records.filter { $0.session["status"].text == "completed" }, id: \.id) { row in Text(row.session["title"].text + " · " + dateLabel(row.session["started_at"])).tag(row.id) } }
                    Picker("归属安排", selection: $slot) { ForEach(Array(plan["slots"].array.enumerated()), id: \.offset) { i, s in Text(s["name"].text).tag(i) } }
                    Button("关联这次补练") { link(remove: false) }.disabled(session.isEmpty || busy)
                    Button("解除所选关联") { link(remove: true) }.disabled(session.isEmpty || busy)
                }
                Section { Button("结束本轮，开始下一轮", role: .destructive) { confirmNext = true }.disabled(busy) }
            }
            if let error { Text(error).foregroundStyle(.red) }
        }.navigationTitle("本轮进度").toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .confirmationDialog("结束本轮并开始下一轮？", isPresented: $confirmNext, titleVisibility: .visible) { Button("开始下一轮", role: .destructive) { mutate { try await store.mutateHome("/home/plan/next", method: "POST") } } } message: { Text("未完成部分会保留在上一轮。") }
    }
    private func link(remove: Bool) { mutate { try await store.mutateHome("/home/plan/link", body: ["session_id": .string(session), "slot": .number(Double(slot)), "remove": .bool(remove)]) } }
    private func mutate(_ action: @escaping () async throws -> Void) { busy = true; Task { do { try await action() } catch { self.error = error.localizedDescription }; busy = false } }
}

struct NativeWalksView: View {
    @Environment(NativeStore.self) var store
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        List {
            if store.home["walks"].array.isEmpty { PineEmpty(title: "暂无散步记录", symbol: "figure.walk") }
            ForEach(Array(store.home["walks"].array.enumerated()), id: \.offset) { _, walk in NavigationLink { NativeWalkEditor(walk: walk) } label: { VStack(alignment: .leading, spacing: 5) { Text(walk["date"].text); Text(dateLabel(walk["start"]) + " – " + dateLabel(walk["end"]) + (walk["ignored"].flag ? " · 已忽略" : "")).font(.caption).foregroundStyle(.secondary) } } }
        }.navigationTitle("散步记录").toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
    }
}
struct NativeWalkEditor: View {
    @Environment(NativeStore.self) var store
    @Environment(\.dismiss) private var dismiss
    let walk: JSONValue
    @State private var start = Date()
    @State private var end = Date()
    @State private var ignored = false
    @State private var error: String?
    @State private var busy = false
    var body: some View {
        Form {
            DatePicker("开始", selection: $start); DatePicker("结束", selection: $end); Toggle("忽略这条记录", isOn: $ignored)
            if let error { Text(error).foregroundStyle(.red) }
            Button("保存调整") { busy = true; Task { do { try await store.mutateHome("/home/walk", body: ["id": walk["id"], "start": NativeDate.stamp(start), "end": NativeDate.stamp(end), "ignored": .bool(ignored)]); dismiss() } catch { self.error = error.localizedDescription }; busy = false } }.disabled(busy || end <= start)
        }.navigationTitle("调整散步时间").onAppear { start = NativeDate.parse(walk["start"]) ?? Date(); end = NativeDate.parse(walk["end"]) ?? Date(); ignored = walk["ignored"].flag }
    }
}

struct NativeRecoveryView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View { NativeRecoveryContent().toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } } }
}
struct NativeRecoveryContent: View {
    @Environment(NativeStore.self) var store
    var body: some View {
        let home=store.home, score=home["recovery"]
        PinePage {
            Text(displayNumber(score["score"],digits:0) + " / 100").font(.system(size:48,weight:.bold,design:.rounded))
            Text(score["label"].text).font(.title3).foregroundStyle(pine)
            Text(score["score"].isNull ? "等待当日指标及足够的个人基线记录。" : "结合昨夜睡眠时长、HRV 和静息心率相对个人基线计算，用于观察恢复状态。指数不代表肌肉修复比例，训练仍结合今天的体感。").font(.subheadline).foregroundStyle(.secondary)
            if score["caution"].flag { PineBanner(text:"近期有几次恢复信号偏弱，留意热身和身体感受。") }
            VStack(spacing: 0) {
                NavigationLink { NativeSleepView() } label: { NativeOverviewLink(title: "睡眠与作息", value: sleepDuration(home["sleep"]["minutes_asleep"]), symbol: "moon.fill", color: .indigo) }.accessibilityIdentifier("recovery-sleep")
                Divider()
                NavigationLink { NativeMetricContent(metric: MetricSelection(id: "hrv", title: "心率变异性", unit: "毫秒")) } label: { NativeOverviewLink(title: "心率变异性", value: displayNumber(healthValue(home["today"]["hrv"], key: "hrv")) + " 毫秒", symbol: "waveform.path.ecg", color: .teal) }
                Divider()
                NavigationLink { NativeMetricContent(metric: MetricSelection(id: "resting_hr", title: "静息心率", unit: "次/分")) } label: { NativeOverviewLink(title: "静息心率", value: displayNumber(healthValue(home["today"]["resting_hr"], key: "resting_hr")) + " 次/分", symbol: "heart.fill", color: .pink) }.accessibilityIdentifier("metric-resting_hr")
                Divider()
                NavigationLink { NativeObservationsView() } label: { NativeOverviewLink(title: "观察记录", value: "早间 · 晚间 · 每周", symbol: "sparkles", color: .teal) }
            }.buttonStyle(.plain).pineCard()
            VStack(spacing: 12) {
                PineRow(label: "HRV 基线", value: displayNumber(score["hrv_baseline"]) + " 毫秒")
                PineRow(label: "静息心率基线", value: displayNumber(score["rhr_baseline"]) + " 次/分")
                PineRow(label: "今天感受", value: [home["feedback"]["energy"].text, home["feedback"]["fatigue"].text].filter { !$0.isEmpty }.joined(separator: " · "))
            }.pineCard()
        }.navigationTitle("恢复指数").navigationBarTitleDisplayMode(.inline)
    }
}
struct NativeDayDetail: View {
    @Environment(NativeStore.self) var store
    @Environment(\.dismiss) private var dismiss
    let day:JSONValue
    var body: some View {
        PinePage {
            PineHeading(title:day["date"].text)
            VStack(alignment:.leading,spacing:12) {
                Text("日常活动").font(.headline)
                PineRow(label:"全天活动热量",value:displayNumber(day["total_energy"]) + " 千卡")
                PineRow(label:"力量训练时段",value:displayNumber(day["strength_energy"]) + " 千卡")
                PineRow(label:"日常活动热量",value:displayNumber(day["activity"]) + " 千卡")
                let covered=store.home["days"].array.filter{$0["date"].text<=store.home["date"].text && $0["activity"].number != nil}
                PineRow(label:"本周累计",value:displayNumber(covered.isEmpty ? .null : .number(covered.reduce(0){$0+($1["activity"].number ?? 0)})) + " 千卡 · \(covered.count) 天覆盖")
                Text("日常活动热量按已记录的力量训练时段拆分，缺失数据保持为空。").font(.caption).foregroundStyle(.secondary)
            }.pineCard()
            VStack(alignment:.leading,spacing:12) {
                Text("力量训练").font(.headline)
                Text("\(day["sets"].integer) / \(day["target"].integer) 工作组").font(.title2.bold())
                ForEach(day["sessions"].array,id:\.id) { s in Button(s["title"].text) { dismiss();store.homeAction(["session_id":s["id"]]) } }
            }.pineCard()
            VStack(alignment:.leading,spacing:12) {
                Text("体态练习").font(.headline)
                Text(day["posture_recorded"].flag ? "已记录" : "暂无完成记录").foregroundStyle(.secondary)
                ForEach(day["posture_sessions"].array,id:\.id) { s in Button(s["title"].text) { dismiss();store.homeAction(["session_id":s["id"]]) } }
                if day["date"]==store.home["date"],!day["posture_recorded"].flag { Button("查看今天的体态练习") { dismiss();store.homeAction(["template_id":"posture-daily"]) } }
            }.pineCard()
        }.navigationTitle("每日记录").toolbar { ToolbarItem(placement:.confirmationAction) { Button("完成") { dismiss() } } }
    }
}

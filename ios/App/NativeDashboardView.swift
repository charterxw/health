import SwiftUI
import Charts

struct MetricSelection: Identifiable { let id: String; let title: String; let unit: String }
struct NativeDashboardView: View {
    @Environment(NativeStore.self) var store
    @Environment(\.dynamicTypeSize) private var typeSize
    @PineReducedMotion private var reduceMotion
    @Namespace private var daySelection
    @State private var selectedDay = ""
    @State private var metric: MetricSelection?
    @State private var showingGoals = false
    @State private var showingFeedback = false
    @State private var showingDay = false
    @State private var showingSync = false
    private var home: JSONValue { store.home }
    private var day: JSONValue { home["days"].array.first { $0["date"].text == selectedDay } ?? home["days"].array.first { $0["date"] == home["date"] } ?? .null }
    var body: some View {
        GeometryReader { geometry in
            if typeSize > .large {
                ScrollView { dashboard.padding(.vertical, 8) }.scrollBounceBehavior(.basedOnSize)
            } else {
                dashboard.padding(.vertical, 8).frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
            }
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("总览").navigationBarTitleDisplayMode(.inline)
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
    private var dashboard: some View {
        VStack(spacing: 10) {
            dateRow
            if home.isNull { PineEmpty(title: "等待健康数据", symbol: "heart.text.square", detail: "点右上角的同步状态重试。") }
            else {
                NavigationLink { NativeBriefDetail() } label: { NativeHomeBrief(brief: store.brief, tip: home["tip"].text) }.buttonStyle(PinePressStyle()).accessibilityIdentifier("home-observation")
                if typeSize.isAccessibilitySize { VStack(spacing: 10) { recoveryCard; stepsCard } }
                else { HStack(spacing: 12) { recoveryCard; stepsCard }.frame(height: typeSize > .large ? nil : 112) }
                weekCard
            }
        }.padding(.horizontal, 20)
    }
    private var dateRow: some View {
        HStack {
            Text(dayTitle(home["date"].text)).font(.subheadline).foregroundStyle(.secondary)
            Spacer(minLength: 6)
            Button { showingSync = true } label: {
                HStack(spacing: 5) {
                    if store.refreshing { ProgressView().controlSize(.mini) }
                    else { Image(systemName: store.message == nil ? "arrow.triangle.2.circlepath" : "exclamationmark.circle").imageScale(.small) }
                    Text(store.refreshing ? "正在同步" : store.message == nil ? syncTime : "同步需重试")
                }.font(.caption).foregroundStyle(.secondary).frame(minHeight: 44)
            }.buttonStyle(PinePressStyle()).accessibilityLabel("数据与同步，" + syncTime)
        }.frame(minHeight: 44)
    }
    private var syncTime: String {
        let dates = home["freshness"]["records"].object.values.compactMap { NativeDate.parse($0["observed_at"]) }.filter { $0 <= Date() }
        if let date = dates.max() { return "记录 " + NativeDate.label(date, format: "HH:mm", timezone: home["timezone"].text) }
        return "数据与同步"
    }
    private var recoveryCard: some View {
        NavigationLink(value: NativeOverviewRoute.recovery) {
            NativeHomeMetric(title: "恢复指数", value: home["recovery"]["score"], unit: "/ 100", detail: home["recovery"]["label"].text.isEmpty ? "待更新" : home["recovery"]["label"].text)
        }.buttonStyle(PinePressStyle()).accessibilityIdentifier("recovery-score")
    }
    private var stepsCard: some View {
        Button { metric = MetricSelection(id: "steps", title: "今日步数", unit: "步") } label: {
            NativeHomeMetric(title: "今日步数", value: home["today"]["steps"], detail: "/ " + displayNumber(home["step_goal"]["target"], digits: 0) + " 步", progress: stepsProgress)
        }.buttonStyle(PinePressStyle()).accessibilityIdentifier("metric-steps")
    }
    private var stepsProgress: Double? { guard let value = home["today"]["steps"].number, let goal = home["step_goal"]["target"].number, goal > 0 else { return nil }; return min(1, max(0, value / goal)) }
    private var weekCard: some View {
        VStack(spacing: 3) {
            HStack {
                Text("活动与训练").font(.headline)
                Spacer(minLength: 4)
                let days = home["days"].array
                Text(String(days.first?["date"].text.suffix(5) ?? "").replacingOccurrences(of: "-", with: "/") + "–" + String(days.last?["date"].text.suffix(5) ?? "").replacingOccurrences(of: "-", with: "/")).font(.caption2).foregroundStyle(.secondary)
                Button("调整目标", systemImage: "slider.horizontal.3") { showingGoals = true }.labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44).buttonStyle(PinePressStyle())
            }
            if typeSize.isAccessibilitySize { ScrollView(.horizontal) { weekDays }.scrollIndicators(.hidden) }
            else { weekDays }
            HStack { Text("目标").frame(maxWidth: .infinity, alignment: .leading); Text(day["date"] == home["date"] ? "今日" : dayTitle(day["date"].text, format: "M/d")).accessibilityIdentifier("home-selected-date").frame(maxWidth: .infinity, alignment: .trailing); Text("本周").frame(maxWidth: .infinity, alignment: .trailing) }.font(.caption).foregroundStyle(.secondary)
            goalRows
            Spacer(minLength: 0)
            Divider()
            Button { showingFeedback = true } label: {
                HStack { Text(feelings.isEmpty ? "今天感觉如何？" : feelings).foregroundStyle(.primary); Spacer(); Text(feelings.isEmpty ? "可选记录" : "修改").foregroundStyle(.secondary); Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary) }.font(.subheadline).frame(minHeight: 44)
            }.buttonStyle(PinePressStyle()).accessibilityIdentifier("home-feelings")
        }.padding(12).frame(maxWidth: .infinity, maxHeight: typeSize > .large ? nil : .infinity, alignment: .top).background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
    }
    private var weekDays: some View {
        HStack(spacing: 0) {
            ForEach(Array(home["days"].array.enumerated()), id: \.element["date"].text) { index, value in
                Button {
                    let next = value["date"].text
                    guard next != day["date"].text else { return }
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.20)) { selectedDay = next }
                } label: {
                    NativeWeekDay(day: value, name: ["一","二","三","四","五","六","日"][min(index, 6)], today: value["date"] == home["date"], selected: value["date"] == day["date"], compact: true)
                        .background {
                            if value["date"] == day["date"], value["date"] != home["date"] {
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(pine.opacity(0.08))
                                    .matchedGeometryEffect(id: "selected-week-day", in: daySelection)
                            }
                        }
                }.buttonStyle(PinePressStyle(scale: 0.97)).frame(maxWidth: .infinity)
                    .accessibilityLabel(weekAccessibility(value))
                    .accessibilityIdentifier("home-day-" + value["date"].text)
                    .accessibilityAddTraits(value["date"] == day["date"] ? .isSelected : [])
            }
        }
    }
    private var goalRows: some View {
        let past = home["days"].array.filter { $0["date"].text <= home["date"].text }
        let energy = past.compactMap { $0["activity"].number }
        return VStack(spacing: 0) {
            NativeGoalRow(title: "日常活动", color: activityColor, daily: day["activity"], dailyTarget: "/ " + displayNumber(day["goals"]["dailyActivity"], digits: 0), weekly: energy.isEmpty ? .null : .number(energy.reduce(0, +)), weeklyTarget: "/ " + displayNumber(home["goals"]["weeklyActivity"], digits: 0)) { showingDay = true }
            NativeGoalRow(title: "力量训练", color: strengthColor, daily: day["strength_planned"].flag || day["strength_optional"].flag ? day["sets"] : .null, dailyTarget: day["strength_planned"].flag || day["strength_optional"].flag ? "/ \(day["target"].integer) 组" + (day["strength_optional"].flag ? " · 可选" : "") : "休息日", weekly: .number(Double(past.filter { $0["sets"].integer > 0 }.count)), weeklyTarget: "/ \(home["goals"]["weeklyStrength"].integer) 天") { showingDay = true }
            NativeGoalRow(title: "体态练习", color: postureColor, daily: day["posture_planned"].flag || day["posture"].flag ? .number(day["posture"].flag ? 1 : 0) : .null, dailyTarget: day["posture_planned"].flag || day["posture"].flag ? "/ 1 次" : "未安排", weekly: .number(Double(past.filter { $0["posture"].flag }.count)), weeklyTarget: "/ \(home["goals"]["weeklyPosture"].integer) 天") { showingDay = true }
        }
    }
    private var feelings: String { [home["feedback"]["energy"].text, home["feedback"]["fatigue"].text].filter { !$0.isEmpty }.joined(separator: " · ") }
    private func weekAccessibility(_ row: JSONValue) -> String {
        if row["date"].text > home["date"].text { return dayTitle(row["date"].text) + "，未来日期，" + row["short"].text }
        return dayTitle(row["date"].text) + "，日常活动 " + displayNumber(row["activity"], digits: 0) + " 千卡，力量 \(row["sets"].integer)/\(row["target"].integer) 组，体态" + (row["posture"].flag ? "已完成" : row["posture_planned"].flag ? "待完成" : "未安排")
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
            Button("重新读取数据", systemImage: "arrow.clockwise") { Task { await store.refreshHealth() } }.disabled(store.refreshing || store.isDesignPreview)
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

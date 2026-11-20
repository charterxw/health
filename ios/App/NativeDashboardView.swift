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
    @State private var showingWeight = false
    @State private var showingStrength = false
    @State private var weekDetail: WeekDetail?
    /// Visible height between the status bar and the tab bar.
    @State private var viewport: CGFloat = 0
    private var home: JSONValue { store.home }
    private var day: JSONValue { home["days"].array.first { $0["date"].text == selectedDay } ?? home["days"].array.first { $0["date"] == home["date"] } ?? .null }
    private var isToday: Bool { day["date"] == home["date"] }
    private var timezone: String { home["timezone"].text.isEmpty ? TimeZone.current.identifier : home["timezone"].text }
    var body: some View {
        // Computed once per render; the week shares one grouping of local records.
        let sessions = NativeDays.sessions(records: store.records, timezone: timezone)
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                PineTabHeader(title: home.isNull ? "今天" : dayTitle(home["date"].text, format: "M月d日 EEE"))
                syncRow
                if home.isNull { PineEmpty(title: "等待健康数据", symbol: "heart.text.square", detail: "下拉或点上方的同步状态重试。") }
                else {
                    observation.padding(.top, 4).layoutPriority(1)
                    // The page fills exactly one screen: whatever the observation's
                    // length, the leftover height goes to these gaps and the goal rows.
                    flexGap(min: 2, max: 8)
                    PineSectionHeader(title: "目标", minHeight: 36) {
                        Text(isToday ? "今日" : dayTitle(day["date"].text, format: "M/d")).font(.subheadline).foregroundStyle(.secondary).accessibilityIdentifier("home-selected-date")
                    }
                    goalsCard(sessions[day["date"].text] ?? [])
                    flexGap(min: 2, max: 8)
                    // 36 pt header; the buttons keep a 44 pt hit area through their content shape.
                    PineSectionHeader(title: "本周", minHeight: 36) {
                        Button("目标") { showingGoals = true }.font(.subheadline).frame(minWidth: 44, minHeight: 36).contentShape(Rectangle().inset(by: -4))
                        Button("日历") { recordsCalendar = true; store.selectedTab = 2 }.font(.subheadline).frame(minWidth: 44, minHeight: 36).contentShape(Rectangle().inset(by: -4))
                    }
                    weekCard(sessions)
                    flexGap(min: 10, max: 14)
                    bodyList
                    Spacer(minLength: 0)
                }
            }.padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 16)
            .fillHeight(viewport)
        }
        .background {
            GeometryReader { proxy in
                // The floating tab bar reaches about 24 pt above the reported bottom
                // inset; keep the last row clear of it.
                let visible = proxy.size.height - proxy.safeAreaInsets.top - proxy.safeAreaInsets.bottom - 24
                Color.clear.onAppear { viewport = visible }.onChange(of: visible) { _, value in viewport = value }
            }
        }
        .background(pineCanvas)
        .navigationTitle("今天")
        .refreshable { await store.refresh(); await store.refreshHealth() }
        .sheet(item: $metric) { item in NavigationStack { NativeMetricDetail(metric: item) } }
        .sheet(isPresented: $showingGoals) { NavigationStack { NativeGoalsView() } }
        .sheet(isPresented: $showingFeedback) { NavigationStack { NativeFeedbackView() } }
        .sheet(isPresented: $showingDay) { NavigationStack { NativeDayDetail(day: day) } }
        .sheet(isPresented: $showingSync) { NavigationStack { NativeSyncDetail() } }
        .sheet(isPresented: $showingStrength) { NavigationStack { NativeStrengthProgressView() } }
        .sheet(isPresented: $showingWeight) { NavigationStack { NativeWeightList(rows: home["weights"].array) } }
        .task(id: store.brief["status"].text) {
            guard !store.isDesignPreview, store.brief["status"].text == "pending" else { return }
            for _ in 0..<60 {
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
                await store.loadBrief(); if store.brief["status"].text != "pending" { return }
            }
        }
    }

    private func flexGap(min: CGFloat, max: CGFloat) -> some View { Spacer(minLength: min).frame(maxHeight: max) }

    // MARK: Sync and feelings
    private var busy: Bool { store.refreshing || store.healthRefreshing }
    private var syncText: String {
        if busy { return "正在从 Google 更新" }
        if store.message != nil { return "同步需重试" }
        guard let date = NativeDate.parse(home["sources"]["metrics"]["fetched_at"]) else { return "数据与同步" }
        let fetched = shortTime(date) + " 更新"
        guard let band = NativeDate.parse(home["freshness"]["device"]["last_sync_at"]) else { return fetched + "自 Google" }
        return "手环 " + shortTime(band) + " 同步 · " + fetched
    }
    private func shortTime(_ date: Date) -> String {
        NativeDate.label(date, format: NativeDate.day(date, timezone: timezone) == home["date"].text ? "HH:mm" : "M/d HH:mm", timezone: timezone)
    }
    private var feelings: String { [home["feedback"]["energy"].text, home["feedback"]["fatigue"].text].filter { !$0.isEmpty }.joined(separator: " · ") }
    private var syncRow: some View {
        HStack(spacing: 8) {
            Button { showingSync = true } label: {
                HStack(spacing: 6) {
                    if busy { ProgressView().controlSize(.mini) }
                    else { Image(systemName: store.message == nil ? "arrow.clockwise" : "exclamationmark.circle").imageScale(.small) }
                    Text(syncText)
                }.font(.footnote).foregroundStyle(.secondary).frame(minHeight: 36)
            }.buttonStyle(PinePressStyle()).accessibilityLabel("数据与同步，" + syncText)
            Spacer(minLength: 8)
            Button { showingFeedback = true } label: {
                Label(feelings.isEmpty ? "记录感受" : feelings, systemImage: feelings.isEmpty ? "plus" : "face.smiling").font(.footnote.weight(.semibold)).frame(minHeight: 36)
            }.buttonStyle(PinePressStyle()).accessibilityIdentifier("home-feelings")
        }
    }

    // MARK: Observation
    private var observation: some View {
        let lines = store.brief["sentences"].array.map { $0.text.isEmpty ? $0["text"].text : $0.text }.filter { !$0.isEmpty }
        let summary = lines.isEmpty ? home["tip"].text : lines.joined(separator: " ")
        let evening = store.brief["title"].text.contains("晚") || store.brief["period"].text == "evening"
        let pending = store.brief["status"].text == "pending"
        // The whole observation is readable on the overview (smaller type, no line
        // cap); the detail page keeps sources and history.
        return HStack(alignment: .top, spacing: 0) {
            NavigationLink { NativeBriefDetail() } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(evening ? "晚间观察" : "早间观察").font(.caption.weight(.semibold)).foregroundStyle(pine)
                    Text(pending && lines.isEmpty ? "正在分析睡眠和恢复…" : summary).font(.subheadline).lineSpacing(2)
                        .foregroundStyle(pending && lines.isEmpty ? .secondary : .primary)
                        .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.padding(.vertical, 12).padding(.leading, 14).contentShape(Rectangle())
            }.buttonStyle(PinePressStyle()).accessibilityIdentifier("home-observation").accessibilityHint("点按查看来源和历史")
            // Manual trigger: rewrite the observation now, even if the data is unchanged.
            Button { Task { await store.loadBrief(force: true) } } label: {
                Group { if pending { ProgressView().controlSize(.mini) } else { Image(systemName: "sparkles").font(.footnote.weight(.semibold)).foregroundStyle(pine) } }
                    .frame(width: 44, height: 40)
            }.buttonStyle(PinePressStyle(scale: 0.94)).disabled(pending || store.isDesignPreview)
                .accessibilityLabel(pending ? "正在分析" : "立即重新分析")
        }
        // A steady card: it reserves about five lines, so a short or long observation
        // does not move the sections below.
        .frame(maxWidth: .infinity, maxHeight: 150, alignment: .top)
        .background(pineSurface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    // MARK: Goals of the selected day
    private func activityFraction(_ row: JSONValue) -> Double? {
        guard let value = row["activity"].number, let goal = row["goals"]["dailyActivity"].number, goal > 0 else { return nil }
        return value / goal
    }
    private func strengthPlanned(_ row: JSONValue) -> Bool { row["strength_planned"].flag || row["strength_optional"].flag || row["target"].integer > 0 }
    private func halves(_ row: JSONValue, _ sessions: [NativeDaySession]) -> [Double] {
        let weekend = NativeDays.isWeekend(row["date"].text)
        let done = NativeDays.halves(sessions, weekend: weekend)
        if weekend { return done }
        return strengthPlanned(row) ? done + Array(repeating: 0, count: max(0, 2 - done.count)) : done
    }
    private func postureDone(_ row: JSONValue, _ sessions: [NativeDaySession]) -> Bool { row["posture"].flag || NativeDays.postureDone(sessions) }
    private func goalsCard(_ sessions: [NativeDaySession]) -> some View {
        let future = day["date"].text > home["date"].text
        let fraction = activityFraction(day)
        let target = day["target"].integer, sets = day["sets"].integer
        let places = sessions.filter { !$0.posture }.map { $0.title.contains("公司") ? "公司" : $0.title.contains("家庭") ? "家庭" : "训练" }
        let weekend = NativeDays.isWeekend(day["date"].text)
        // Rows are narrow beside the steps tile: a small label and a short value.
        let half = halves(day, sessions)
        let strengthValue: String = {
            if places.count >= 2 { return "两次 · \(sets) 组" }
            if let place = places.first { return place + " · " + (weekend || target <= sets ? "\(sets) 组" : "\(sets)/\(target)") }
            if weekend { return "休息为主" }
            guard strengthPlanned(day) else { return "今天休息" }
            return (future ? "计划 " : "待练 ") + "\(target) 组"
        }()
        let strengthDone = half.count >= 1 && half.allSatisfy { $0 >= 1 } && (weekend || half.count == 2)
        let posture = sessions.last { $0.posture }
        let postureMet = postureDone(day, sessions)
        let postureText: String = {
            if let posture, let start = posture.start {
                let minutes = posture.end.map { max(1, Int(($0.timeIntervalSince(start) / 60).rounded())) }
                return NativeDate.label(start, format: "HH:mm", timezone: timezone) + (minutes.map { " · \($0) 分钟" } ?? "")
            }
            if day["posture"].flag { return "已完成" }
            return day["posture_planned"].flag ? (future ? "计划练习" : "待完成") : "今天不安排"
        }()
        let activityValue = displayNumber(day["activity"], digits: 0) + "/" + displayNumber(day["goals"]["dailyActivity"], digits: 0) + " 千卡"
        // Steps sit beside the rings as a fourth daily goal; both tiles share one height.
        return HStack(alignment: .top, spacing: 10) {
            Button { showingDay = true } label: {
                HStack(spacing: 12) {
                    PineDayGlyph(activity: fraction, halves: half, posture: postureMet, future: future, size: 84)
                    VStack(spacing: 0) {
                        goalLine("活动 · 外圈", activityValue, done: (fraction ?? 0) >= 1)
                        Divider()
                        goalLine("力量 · 中圈", strengthValue, done: strengthDone)
                        Divider()
                        goalLine("体态 · 圆点", postureText, done: postureMet)
                    }
                }.padding(.leading, 14).padding(.trailing, 12).padding(.vertical, 10)
                    .frame(maxWidth: .infinity, maxHeight: Self.goalsMaxHeight)
                    .background(pineSurface, in: RoundedRectangle(cornerRadius: 20, style: .continuous)).contentShape(Rectangle())
            }.buttonStyle(PinePressStyle()).accessibilityElement(children: .combine).accessibilityHint("点按查看这天的详细记录")
            stepsTile
        }
    }
    /// Three rows at most 58 pt, two dividers and the vertical padding.
    private static let goalsMaxHeight: CGFloat = 3 * 58 + 2 + 20
    private func goalLine(_ label: String, _ value: String, done: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 3) {
                Text(value).font(.pineRow.weight(.semibold)).monospacedDigit().foregroundStyle(done ? pine : Color.primary)
                if done { Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(pine).accessibilityLabel("已完成") }
            }.lineLimit(1).minimumScaleFactor(0.8)
        }.frame(maxWidth: .infinity, minHeight: 46, maxHeight: 58, alignment: .leading)
    }
    private var stepsTile: some View {
        // The selected day's steps: today's live count, or the daily history.
        let stepsValue: JSONValue = isToday ? home["today"]["steps"] : home["metrics"].array.first { $0["date"] == day["date"] }?["steps"] ?? .null
        let steps = stepsValue.number, goal = home["step_goal"]["target"].number
        let fraction = steps.flatMap { s in goal.flatMap { $0 > 0 ? min(1, s / $0) : nil } } ?? 0
        let detail: String = {
            guard let steps, let goal, goal > 0 else { return "" }
            return steps >= goal ? "超出 " + displayNumber(.number(steps - goal), digits: 0) : "目标 " + displayNumber(.number(goal), digits: 0)
        }()
        return Button { metric = MetricSelection(id: "steps", title: "今日步数", unit: "步") } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text("步数").font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Text(displayNumber(stepsValue, digits: 0)).font(.title2.weight(.semibold)).monospacedDigit()
                    .foregroundStyle(.primary).lineLimit(1).minimumScaleFactor(0.7)
                    .contentTransition(reduceMotion ? .identity : .numericText(value: steps ?? 0))
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: steps)
                if !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(fraction >= 1 ? pine : Color.secondary).monospacedDigit().lineLimit(1).minimumScaleFactor(0.8) }
                Capsule().fill(pineTrack).frame(height: 6)
                    .overlay(alignment: .leading) { GeometryReader { proxy in Capsule().fill(pine).frame(width: max(6, proxy.size.width * fraction)) } }
                    .padding(.top, 4)
            }.padding(14).frame(width: 112).frame(maxHeight: Self.goalsMaxHeight, alignment: .topLeading)
                .background(pineSurface, in: RoundedRectangle(cornerRadius: 20, style: .continuous)).contentShape(Rectangle())
        }.buttonStyle(PinePressStyle()).accessibilityElement(children: .combine)
            .accessibilityLabel("步数 " + displayNumber(stepsValue, digits: 0) + (detail.isEmpty ? "" : "，" + detail))
            .accessibilityIdentifier("metric-steps")
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
                            Text(NativeDays.focus(dayKey: date, sessions: list, serverTag: row["short"].text)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }.frame(maxWidth: .infinity, minHeight: 72).padding(.vertical, 2)
                            .background(selected ? pineTint : .clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .contentShape(Rectangle())
                    }.buttonStyle(PinePressStyle(scale: 0.97))
                        .accessibilityLabel(weekAccessibility(row, list))
                        .accessibilityIdentifier("home-day-" + date)
                        .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            Divider().padding(.top, 6)
            // Strength and posture days are visible in the glyphs above; the row keeps
            // the two numbers the glyphs cannot show, each expandable in place.
            HStack(spacing: 20) {
                weekToggle(.activity, title: "活动", value: energy.isEmpty ? "—" : displayNumber(.number(energy.reduce(0, +)), digits: 0),
                           suffix: "/" + displayNumber(home["goals"]["weeklyActivity"], digits: 0), tint: false)
                let strength = NativeStrengthWeeks.current(store: store, timezone: timezone)
                weekToggle(.strength, title: "力量指数", value: strength.change.map(NativeStrengthWeeks.percent) ?? "—", suffix: "", tint: (strength.change ?? 0) > 0.005)
            }.padding(.horizontal, 4).padding(.top, 8)
            if weekDetail == .activity { dailyActivity(days) }
            if weekDetail == .strength { strengthPreview }
        }.padding(.horizontal, 12).padding(.vertical, 8).background(pineSurface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
    enum WeekDetail { case activity, strength }
    private func weekToggle(_ kind: WeekDetail, title: String, value: String, suffix: String, tint: Bool) -> some View {
        let open = weekDetail == kind
        return Button {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { weekDetail = open ? nil : kind }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(title).font(.footnote).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Text(value).font(.headline).monospacedDigit().foregroundStyle(tint ? pine : Color.primary)
                if !suffix.isEmpty { Text(suffix).font(.caption).foregroundStyle(.secondary).monospacedDigit() }
                Image(systemName: "chevron.down").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(open ? 180 : 0)).padding(.leading, 2)
            }.lineLimit(1).frame(maxWidth: .infinity, minHeight: 32).contentShape(Rectangle())
        }.buttonStyle(PinePressStyle())
            .accessibilityElement(children: .combine)
            .accessibilityHint(open ? "点按收起" : (kind == .activity ? "点按展开每天的活动量" : "点按展开每个动作的变化"))
            .accessibilityIdentifier(kind == .activity ? "home-activity-total" : "home-strength-index")
    }
    /// Each day's activity under its own column, in step with the glyphs above.
    private func dailyActivity(_ days: [JSONValue]) -> some View {
        let goal = home["goals"]["dailyActivity"].number
        return VStack(spacing: 4) {
            HStack(spacing: 0) {
                ForEach(days, id: \.["date"].text) { row in
                    let value = row["activity"].number
                    let met = value.map { v in goal.map { v >= $0 } ?? false } ?? false
                    Text(row["date"].text > home["date"].text || value == nil ? "—" : displayNumber(.number(value ?? 0), digits: 0))
                        .font(.caption.weight(met ? .semibold : .regular)).monospacedDigit()
                        .foregroundStyle(met ? pine : Color.secondary).frame(maxWidth: .infinity)
                }
            }
            Text("每天活动千卡 · 绿色为达到每日目标 " + displayNumber(.number(goal ?? 0), digits: 0)).font(.caption2).foregroundStyle(.tertiary)
        }.padding(.top, 8).transition(.opacity)
    }
    /// The three largest changes, with the full list one tap away.
    private var strengthPreview: some View {
        let week = NativeStrengthWeeks.current(store: store, timezone: timezone)
        return VStack(spacing: 6) {
            if week.lifts.isEmpty {
                Text("本周还没有和前 4 周可比较的动作。").font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            }
            ForEach(Array(week.lifts.prefix(3))) { lift in
                HStack {
                    Text(lift.name).font(.footnote).lineLimit(1)
                    Spacer(minLength: 8)
                    Text(NativeStrengthWeeks.percent(lift.change)).font(.footnote.weight(.semibold)).monospacedDigit()
                        .foregroundStyle(lift.change > 0.005 ? pine : Color.secondary)
                }
            }
            Button { showingStrength = true } label: {
                HStack(spacing: 2) { Text(week.lifts.count > 3 ? "全部 \(week.lifts.count) 个动作与之前几周" : "动作详情与之前几周"); Image(systemName: "chevron.right").font(.caption2.weight(.semibold)) }
                    .font(.footnote.weight(.semibold)).foregroundStyle(pine).frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
            }.buttonStyle(.plain)
        }.padding(.horizontal, 4).padding(.top, 8).transition(.opacity)
    }
    private func weekAccessibility(_ row: JSONValue, _ sessions: [NativeDaySession]) -> String {
        let title = dayTitle(row["date"].text) + "，" + planLabel(NativeDays.focus(dayKey: row["date"].text, sessions: sessions, serverTag: row["short"].text))
        if row["date"].text > home["date"].text { return title + "，未来日期" }
        return title + "，日常活动 " + displayNumber(row["activity"], digits: 0) + " 千卡，力量 \(row["sets"].integer)/\(row["target"].integer) 组，体态" + (postureDone(row, sessions) ? "已完成" : row["posture_planned"].flag ? "待完成" : "未安排")
    }

    // MARK: Body
    /// Recovery, steps and body weight share one row.
    private var bodyList: some View {
        let weight = weightSummary, sleep = sleepSummary
        return HStack(spacing: 0) {
            NavigationLink(value: NativeOverviewRoute.recovery) {
                thirdTile("恢复", home["recovery"]["label"].text.isEmpty ? "" : home["recovery"]["label"].text, displayNumber(home["recovery"]["score"], digits: 0), "", home["recovery"]["score"].number)
            }.buttonStyle(PinePressStyle()).accessibilityIdentifier("recovery-score")
            Divider().frame(height: 36)
            NavigationLink(value: NativeOverviewRoute.sleep) {
                thirdTile(sleep.title, sleep.detail, sleep.value, sleep.unit, nil)
            }.buttonStyle(PinePressStyle()).accessibilityIdentifier("home-sleep")
            Divider().frame(height: 36)
            Button { showingWeight = true } label: {
                thirdTile("体重", weight.change, weight.value, weight.value == "—" ? "" : "公斤", nil)
            }.buttonStyle(PinePressStyle()).accessibilityIdentifier("metric-weight")
        }.background(pineSurface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
    /// Before 17:00 last night's sleep against the personal need; afterwards a
    /// suggested bedtime: the usual wake time minus the need and the usual awake
    /// time in bed.
    private var sleepSummary: (title: String, detail: String, value: String, unit: String) {
        let need = home["recovery"]["sleep_need"].number ?? 7.5
        let needText = "需 " + displayNumber(.number(need), digits: 1)
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: timezone) ?? .current
        if calendar.component(.hour, from: Date()) < NativeStore.eveningHour {
            let minutes = home["sleep"]["minutes_asleep"].number ?? home["today"]["sleep_hours"].number.map { $0 * 60 }
            guard let minutes, minutes > 0 else { return ("睡眠", needText, "—", "") }
            return ("睡眠", needText, displayNumber(.number((minutes / 6).rounded() / 10), digits: 1), "小时")
        }
        guard let bedtime = NativeDays.bedtime(sleeps: home["sleeps"].array, needHours: need, timezone: timezone) else { return ("今晚", needText, "—", "") }
        return ("今晚", "建议入睡", String(format: "%d:%02d", bedtime / 60, bedtime % 60), "前")
    }
    /// Latest weigh-in and the change against the reading about four weeks earlier.
    private var weightSummary: (value: String, change: String) {
        let rows = home["weights"].array.filter { $0["kg"].number != nil }.sorted { $0["date"].text > $1["date"].text }
        guard let latest = rows.first, let kg = latest["kg"].number else { return ("—", "") }
        let value = displayNumber(.number(kg), digits: 1)
        guard let date = NativeDate.parse(latest["date"].text + "T12:00:00Z"),
              let older = rows.first(where: { (NativeDate.parse($0["date"].text + "T12:00:00Z") ?? date) <= date.addingTimeInterval(-25 * 86400) }),
              let then = older["kg"].number, let thenDate = NativeDate.parse(older["date"].text + "T12:00:00Z") else { return (value, "") }
        let weeks = max(1, Int((date.timeIntervalSince(thenDate) / (7 * 86400)).rounded()))
        let delta = ((kg - then) * 10).rounded() / 10
        return (value, "\(weeks)周 " + (delta >= 0 ? "+" : "") + displayNumber(.number(delta), digits: 1))
    }
    private func thirdTile(_ title: String, _ detail: String, _ value: String, _ unit: String, _ animated: Double?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(title).font(.footnote).foregroundStyle(.secondary)
                if !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.85) }
            }
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value).font(.title3.weight(.semibold)).monospacedDigit().foregroundStyle(.primary)
                    .contentTransition(reduceMotion ? .identity : .numericText(value: animated ?? 0))
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: animated)
                if !unit.isEmpty { Text(unit).font(.caption).foregroundStyle(.secondary) }
            }
        }.padding(.horizontal, 14).padding(.vertical, 10).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            .accessibilityElement(children: .combine)
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
    var body: some View { HStack(spacing: 10) { Image(systemName: symbol).foregroundStyle(pine).frame(width: 22); Text(title).font(.subheadline).foregroundStyle(.primary); Spacer(minLength: 5); Text(value).font(.caption).foregroundStyle(.secondary); Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary) }.frame(minHeight: 44).contentShape(Rectangle()) }
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
            Button(brief["status"].text == "pending" ? "正在分析…" : "立即重新分析", systemImage: "arrow.clockwise") { Task { await store.loadBrief(force: true) } }.buttonStyle(.bordered).disabled(store.isDesignPreview || brief["status"].text == "pending")
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
            VStack(spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 4) { Text(displayNumber(score["score"], digits: 0)).font(.system(size: 64, weight: .semibold, design: .rounded)).monospacedDigit(); Text("/ 100").font(.headline).foregroundStyle(.secondary) }
                Text(score["label"].text.isEmpty ? "待更新" : "状态" + score["label"].text).font(.title3.weight(.semibold))
            }.frame(maxWidth: .infinity)
            Text(score["score"].isNull ? "等待当日指标及至少 7 天的个人记录。" : "HRV、静息心率和睡眠分别和你自己近 4 周的正常范围比较：昨夜和近 7 天各占一半，单晚波动不会左右结果。在正常范围内是「平稳」，明显高于是「充分」，低于是「偏低」。睡眠不足 6.5 小时不会显示「充分」。指数不代表肌肉修复比例，训练仍结合今天的体感。").font(.subheadline).foregroundStyle(.secondary)
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
                PineRow(label: "HRV", value: recoveryPosition(score["components"]["hrv"]) + " · 正常 " + range(score["hrv_range"], fallback: score["hrv_baseline"]) + " 毫秒")
                PineRow(label: "静息心率", value: recoveryPosition(score["components"]["resting_hr"]) + " · 正常 " + range(score["rhr_range"], fallback: score["rhr_baseline"]) + " 次/分")
                if !score["sleep_need"].isNull {
                    PineRow(label: "睡眠", value: recoveryPosition(score["components"]["sleep"]) + " · 需要约 " + displayNumber(score["sleep_need"]) + " 小时")
                    PineRow(label: "近 7 晚平均欠睡", value: displayNumber(score["sleep_debt"]) + " 小时")
                }
                PineRow(label: "今天感受", value: [home["feedback"]["energy"].text, home["feedback"]["fatigue"].text].filter { !$0.isEmpty }.joined(separator: " · "))
            }.pineCard()
        }.navigationTitle("恢复指数").navigationBarTitleDisplayMode(.inline)
    }
    /// Where a signal sits against the personal normal range (±0.5 SD).
    private func recoveryPosition(_ z: JSONValue) -> String {
        guard let z = z.number else { return "—" }
        return z >= 0.5 ? "好于平时" : z <= -0.5 ? "弱于平时" : "正常范围"
    }
    private func range(_ value: JSONValue, fallback: JSONValue) -> String {
        let bounds = value.array.compactMap(\.number)
        guard bounds.count == 2 else { return displayNumber(fallback) }
        return displayNumber(.number(bounds[0])) + "–" + displayNumber(.number(bounds[1]))
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

/// Body-weight readings, newest first, with the change from each previous one.
struct NativeWeightList: View {
    @Environment(\.dismiss) private var dismiss
    let rows: [JSONValue]
    var body: some View {
        let sorted = rows.filter { $0["kg"].number != nil }.sorted { $0["date"].text > $1["date"].text }
        List {
            if sorted.isEmpty { Text("还没有体重记录。").foregroundStyle(.secondary) }
            ForEach(Array(sorted.enumerated()), id: \.offset) { index, row in
                HStack {
                    Text(dayTitle(row["date"].text, format: "M月d日 EEE"))
                    Spacer()
                    if index + 1 < sorted.count, let kg = row["kg"].number, let prior = sorted[index + 1]["kg"].number {
                        let delta = ((kg - prior) * 10).rounded() / 10
                        Text((delta >= 0 ? "+" : "") + displayNumber(.number(delta), digits: 1)).font(.footnote).foregroundStyle(.secondary).monospacedDigit()
                    }
                    Text(displayNumber(row["kg"], digits: 1) + " 公斤").fontWeight(.semibold).monospacedDigit()
                }
            }
        }.navigationTitle("体重").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
    }
}

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
                Text(week.change.map(NativeStrengthWeeks.percent) ?? "—").font(.system(size: 56, weight: .semibold, design: .rounded)).monospacedDigit()
                    .foregroundStyle((week.change ?? 0) > 0.005 ? pine : Color.primary)
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
                            Text(NativeStrengthWeeks.percent(lift.change)).font(.subheadline.weight(.semibold)).monospacedDigit()
                                .foregroundStyle(lift.change > 0.005 ? pine : lift.change < -0.005 ? Color.secondary : Color.primary)
                        }.padding(.vertical, 10)
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
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
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

/// A scroll view proposes no height, so flexible children would stay at their
/// minimum. This proposes the visible height instead and grows past it only when
/// the content's minimum is taller (then the page scrolls).
private struct PineFillHeight: Layout {
    var height: CGFloat
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let size = child.sizeThatFits(ProposedViewSize(width: proposal.width, height: height > 0 ? height : nil))
        return CGSize(width: proposal.width ?? size.width, height: max(size.height, height))
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}
private extension View {
    func fillHeight(_ height: CGFloat) -> some View { PineFillHeight(height: height) { self } }
}

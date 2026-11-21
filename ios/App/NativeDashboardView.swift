import SwiftUI
import Charts
import PhotosUI

struct MetricSelection: Identifiable { let id: String; let title: String; let unit: String }
struct NativeDashboardView: View {
    @Environment(NativeStore.self) var store
    @PineReducedMotion private var reduceMotion
    @State private var selectedDay = ""
    @State private var showingGoals = false
    @State private var showingFeedback = false
    @State private var weekDetail: WeekDetail?
    @State private var barsShown = false
    /// Sentences of a newly written observation shown so far (all when settled).
    @State private var revealed = Int.max
    @State private var seenBrief = ""
    /// Yesterday's glyph glows once when all three closed while the app was away.
    @State private var glowDate = ""
    /// On Sunday evening the week's summary takes the observation's place.
    @State private var showBrief = false
    @Namespace private var weekSpace
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
                // A free signature lasts seven days; warn in the last two.
                if let left = NativeSigning.daysLeft(), left <= 2 {
                    PineBanner(text: "签名" + (left <= 0 ? "已过期" : NativeSigning.text) + "。用 Mac 上的 Sideloadly 重新安装一次即可续签，记录会保留。").padding(.bottom, 6)
                }
                if home.isNull { PineEmpty(title: "等待健康数据", symbol: "heart.text.square", detail: "下拉或点上方的同步状态重试。") }
                else {
                    topCard.padding(.top, 4).layoutPriority(1)
                    // The page fills exactly one screen: whatever the observation's
                    // length, the leftover height goes to these gaps and the goal rows.
                    flexGap(min: 2, max: 8)
                    PineSectionHeader(title: "目标", minHeight: 36) {
                        Text(isToday ? "" : dayTitle(day["date"].text, format: "M/d")).font(.subheadline).foregroundStyle(.secondary).accessibilityIdentifier("home-selected-date")
                    }
                    goalsCard(sessions[day["date"].text] ?? [])
                    flexGap(min: 2, max: 8)
                    // 36 pt header; the buttons keep a 44 pt hit area through their content shape.
                    PineSectionHeader(title: "本周", minHeight: 36) {
                        Button("目标") { showingGoals = true }.font(.subheadline).frame(minWidth: 44, minHeight: 36).contentShape(Rectangle().inset(by: -4))
                        NavigationLink("日历", value: NativeOverviewRoute.calendar).font(.subheadline).frame(minWidth: 44, minHeight: 36).contentShape(Rectangle().inset(by: -4))
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
        .modifier(PinePullRefresh { await store.refresh(); await store.refreshHealth() })
        .sheet(isPresented: $showingGoals) { NavigationStack { NativeGoalsView() } }
        .sheet(isPresented: $showingFeedback) { NavigationStack { NativeFeedbackView() } }
        .task(id: home["date"].text) { if !home.isNull, !store.isDesignPreview { checkYesterday(sessions) } }
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
            NavigationLink(value: NativeOverviewRoute.sync) {
                HStack(spacing: 6) {
                    if busy {
                        // The glyph turns while data comes in.
                        TimelineView(.animation(minimumInterval: nil, paused: reduceMotion)) { context in
                            PineDayGlyph(activity: 0.75, halves: [1, 0.5], posture: true, size: 15)
                                .rotationEffect(.degrees(reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.1) / 1.1 * 360))
                        }
                    } else { Image(systemName: store.message == nil ? "arrow.clockwise" : "exclamationmark.circle").imageScale(.small) }
                    Text(syncText).contentTransition(reduceMotion ? .identity : .numericText()).animation(reduceMotion ? nil : .snappy, value: syncText)
                }.font(.footnote).foregroundStyle(.secondary).frame(minHeight: 36)
            }.buttonStyle(PinePressStyle()).accessibilityLabel("数据与同步，" + syncText)
            Spacer(minLength: 8)
            Button { showingFeedback = true } label: {
                Label(feelings.isEmpty ? "记录感受" : feelings, systemImage: feelings.isEmpty ? "plus" : "face.smiling").font(.footnote.weight(.semibold)).frame(minHeight: 36)
            }.buttonStyle(PinePressStyle()).accessibilityIdentifier("home-feelings")
        }
    }

    // MARK: Weekly summary
    private var summaryTime: Bool {
        guard NativeDays.weekday(home["date"].text) == 1 else { return false }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: timezone) ?? .current
        return calendar.component(.hour, from: Date()) >= NativeStore.eveningHour
    }
    @ViewBuilder private var topCard: some View {
        if summaryTime && !showBrief { weeklySummary.transition(.opacity) } else { observation.transition(.opacity) }
    }
    /// Sunday evening: the week in four lines, the same height as the observation.
    private var weeklySummary: some View {
        let days = home["days"].array
        let trained = days.filter { $0["sets"].integer > 0 }.count
        let sets = days.reduce(0) { $0 + $1["sets"].integer }
        let goal = home["goals"]["dailyActivity"].number ?? 0
        let active = days.filter { goal > 0 && ($0["activity"].number ?? 0) >= goal }.count
        let stepGoal = home["step_goal"]["target"].number ?? 0
        let steps = stepGoal > 0 ? days.filter { daySteps($0) >= stepGoal }.count : 0
        let strength = NativeStrengthWeeks.current(store: store, timezone: timezone)
        let weights = home["weights"].array.filter { row in days.contains { $0["date"] == row["date"] } && row["kg"].number != nil }.sorted { $0["date"].text < $1["date"].text }
        let weightLine: String = {
            guard let last = weights.last?["kg"].number else { return "" }
            let change = weights.count > 1 ? ((last - (weights.first?["kg"].number ?? last)) * 10).rounded() / 10 : nil
            return "体重 " + displayNumber(.number(last)) + " 公斤" + (change.map { "（本周 " + ($0 >= 0 ? "+" : "") + displayNumber(.number($0)) + "）" } ?? "")
        }()
        let waist = NativeMeasurements.latest(.waist, in: NativeMeasurements.entries())
        let waistLine = waist.map { "腰围 " + displayNumber(.number($0.value)) + " 厘米" } ?? "这周还没量腰围"
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("本周小结").font(.caption.weight(.semibold)).foregroundStyle(pine)
                Spacer()
                Button("看观察") { withAnimation(.easeOut(duration: 0.2)) { showBrief = true } }.font(.caption.weight(.semibold))
            }
            summaryLine("dumbbell.fill", "练了 \(trained) 天 · \(sets) 组" + (strength.change.map { " · 力量指数 " + NativeStrengthWeeks.percent($0) } ?? ""))
            summaryLine("flame.fill", "活动达标 \(active)/7 天 · 步数达标 \(steps)/7 天")
            summaryLine("scalemass.fill", [weightLine, waistLine].filter { !$0.isEmpty }.joined(separator: " · "))
            if strength.records > 0 { summaryLine("medal.fill", "\(strength.records) 个动作超过了近 4 周最好成绩", gold: true) }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: 150, alignment: .top)
        .background(pineSurface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
    private func daySteps(_ day: JSONValue) -> Double {
        if day["date"] == home["date"] { return home["today"]["steps"].number ?? 0 }
        let row = home["metrics"].array.first { $0["date"] == day["date"] }
        return row?["steps"].number ?? 0
    }
    private func summaryLine(_ symbol: String, _ text: String, gold: Bool = false) -> some View {
        Label { Text(text).font(.subheadline).lineLimit(1).minimumScaleFactor(0.85) } icon: {
            Image(systemName: symbol).font(.footnote).foregroundStyle(gold ? pineGold : pine).frame(width: 20)
        }
    }

    // MARK: Observation
    private var observation: some View {
        let lines = store.brief["sentences"].array.map { $0.text.isEmpty ? $0["text"].text : $0.text }.filter { !$0.isEmpty }
        let summary = lines.isEmpty ? home["tip"].text : lines.joined(separator: " ")
        let evening = store.brief["title"].text.contains("晚") || store.brief["period"].text == "evening"
        let pending = store.brief["status"].text == "pending"
        let written = NativeDate.parse(store.brief["generated_at"]).map { " · " + NativeDate.label($0, format: "HH:mm", timezone: timezone) } ?? ""
        // The whole observation is readable on the overview; the text runs the full
        // width, and the re-analyse control sits on the label line instead of
        // taking a column of its own.
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 8) {
                Text((evening ? "晚间观察" : "早间观察") + (lines.isEmpty ? "" : written)).font(.caption.weight(.semibold)).foregroundStyle(pine)
                Spacer(minLength: 8)
                if summaryTime { Button("本周小结") { withAnimation(.easeOut(duration: 0.2)) { showBrief = false } }.font(.caption.weight(.semibold)) }
                // Manual trigger: rewrite the observation now, even if the data is unchanged.
                Button { Task { await store.loadBrief(force: true) } } label: {
                    Image(systemName: "sparkles").font(.footnote.weight(.semibold)).foregroundStyle(pending ? pineGold : pine)
                        .symbolEffect(.variableColor.iterative.reversing, options: .repeating, isActive: pending && !reduceMotion)
                        .frame(width: 28, height: 20).contentShape(Rectangle().inset(by: -12))
                }.buttonStyle(PinePressStyle(scale: 0.94)).disabled(pending || store.isDesignPreview)
                    .accessibilityLabel(pending ? "正在分析" : "立即重新分析")
            }
            NavigationLink { NativeBriefDetail() } label: {
                observationText(lines: lines, fallback: pending && lines.isEmpty ? "正在分析睡眠和恢复…" : summary).font(.subheadline).lineSpacing(2)
                    .foregroundStyle(pending && lines.isEmpty ? .secondary : .primary)
                    .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(PinePressStyle()).accessibilityIdentifier("home-observation").accessibilityHint("点按查看来源和历史")
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        // A steady card: it reserves about five lines, so a short or long observation
        // does not move the sections below.
        .frame(maxWidth: .infinity, maxHeight: 150, alignment: .top)
        .background(pineSurface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .task(id: store.brief["generated_at"].text + String(lines.count)) {
            // A freshly written observation appears sentence by sentence; the one
            // already on screen when the page opens does not replay.
            let key = store.brief["generated_at"].text
            defer { seenBrief = key }
            guard !reduceMotion, !seenBrief.isEmpty, key != seenBrief, !lines.isEmpty else { revealed = .max; return }
            revealed = 0
            for count in 1...lines.count {
                do { try await Task.sleep(for: .milliseconds(380)) } catch { revealed = .max; return }
                withAnimation(.easeOut(duration: 0.35)) { revealed = count }
            }
            revealed = .max
        }
    }
    /// Sentences not yet revealed stay in place but transparent, so the card
    /// does not change height while they fade in.
    private func observationText(lines: [String], fallback: String) -> Text {
        guard revealed != .max, !lines.isEmpty else { return Text(fallback) }
        return lines.enumerated().reduce(Text("")) { text, item in
            text + Text((item.offset > 0 ? " " : "") + item.element).foregroundStyle(item.offset < revealed ? Color.primary : Color.clear)
        }
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
        // The steps tile is an overlay so it always matches the goal tile's height.
        return HStack(spacing: 10) {
            NavigationLink(value: NativeOverviewRoute.day(day["date"].text)) {
                HStack(spacing: 12) {
                    PineDayGlyph(activity: fraction, halves: half, posture: postureMet, future: future, size: 80, animated: true)
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
            Color.clear.frame(width: Self.stepsWidth)
        }
        .overlay(alignment: .trailing) { stepsTile.frame(width: Self.stepsWidth).frame(maxHeight: .infinity) }
    }
    private static let stepsWidth: CGFloat = 116
    /// Three rows at most 58 pt, two dividers and the vertical padding.
    private static let goalsMaxHeight: CGFloat = 3 * 58 + 2 + 20
    private func goalLine(_ label: String, _ value: String, done: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 3) {
                Text(value).font(.subheadline.weight(.semibold)).monospacedDigit().foregroundStyle(done ? pine : Color.primary)
                    .contentTransition(reduceMotion ? .identity : .numericText()).animation(reduceMotion ? nil : .snappy, value: value)
                if done { Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(pine).accessibilityLabel("已完成") }
            }.lineLimit(1).minimumScaleFactor(0.8)
        }.frame(maxWidth: .infinity, minHeight: 46, maxHeight: 58, alignment: .leading)
    }
    /// This week's steps, one bar per day against a faint dashed goal line; the part
    /// above the line is the extra (capped so one long day does not dominate).
    private func stepBars(goal: Double?) -> some View {
        let rows: [(date: String, steps: Double?)] = home["days"].array.map { row in
            let date = row["date"].text
            let value = date == home["date"].text ? home["today"]["steps"].number : home["metrics"].array.first { $0["date"].text == date }?["steps"].number
            return (date, date > home["date"].text ? nil : value)
        }
        let target = max(goal ?? 0, 1), goalHeight: CGFloat = 24, top: CGFloat = 38
        return VStack(spacing: 3) {
            ZStack(alignment: .bottom) {
                PineHorizontalLine().stroke(Color.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                    .frame(height: 1).padding(.bottom, goalHeight)
                Rectangle().fill(pineTrack).frame(height: 1)
                HStack(alignment: .bottom, spacing: 0) {
                    ForEach(rows, id: \.date) { row in
                        let steps = row.steps ?? 0
                        // Today's bar flashes gold while the steps toast is up.
                        let flash = store.celebration?.kind == .steps && row.date == home["date"].text
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(flash ? pineGold : steps >= target ? pine : pine.opacity(0.35))
                            .shadow(color: pineGold.opacity(flash ? 0.8 : 0), radius: 4)
                            .scaleEffect(x: flash && !reduceMotion ? 1.3 : 1, y: 1, anchor: .bottom)
                            .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.5), value: flash)
                            .frame(width: 8, height: row.steps == nil || !(barsShown || reduceMotion) ? 0 : max(2, min(top, CGFloat(steps / target) * goalHeight)))
                            .frame(maxWidth: .infinity)
                    }
                }
            }.frame(height: top, alignment: .bottom)
            .onAppear { guard !barsShown else { return }; withAnimation(.spring(response: 0.7, dampingFraction: 0.8).delay(0.35)) { barsShown = true } }
            HStack(spacing: 0) {
                ForEach(rows, id: \.date) { row in
                    Circle().fill(row.date == day["date"].text ? pine : .clear).frame(width: 3, height: 3).frame(maxWidth: .infinity)
                }
            }
        }.accessibilityHidden(true)
    }
    private var stepsTile: some View {
        // The selected day's steps: today's live count, or the daily history.
        let stepsValue: JSONValue = isToday ? home["today"]["steps"] : home["metrics"].array.first { $0["date"] == day["date"] }?["steps"] ?? .null
        let steps = stepsValue.number, goal = home["step_goal"]["target"].number
        let distance: JSONValue = isToday ? home["today"]["distance_km"] : home["metrics"].array.first { $0["date"] == day["date"] }?["distance_km"] ?? .null
        let fraction = steps.flatMap { s in goal.flatMap { $0 > 0 ? min(1, s / $0) : nil } } ?? 0
        let detail: String = {
            guard let steps, let goal, goal > 0 else { return "" }
            return steps >= goal ? "超出 " + displayNumber(.number(steps - goal), digits: 0) : "目标 " + displayNumber(.number(goal), digits: 0)
        }()
        return NavigationLink(value: NativeOverviewRoute.steps) {
            VStack(alignment: .leading, spacing: 2) {
                Text("步数").font(.caption).foregroundStyle(.secondary)
                Text(displayNumber(stepsValue, digits: 0)).font(.title3.weight(.semibold)).monospacedDigit()
                    .foregroundStyle(.primary).lineLimit(1).minimumScaleFactor(0.7)
                    .contentTransition(reduceMotion ? .identity : .numericText(value: steps ?? 0))
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: steps)
                if !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(fraction >= 1 ? pine : Color.secondary).monospacedDigit().lineLimit(1).minimumScaleFactor(0.8) }
                if let km = distance.number, km > 0 { Text(displayNumber(.number(km), digits: 1) + " 公里").font(.caption).foregroundStyle(.secondary).monospacedDigit() }
                Spacer(minLength: 4)
                stepBars(goal: goal)
            }.padding(12).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
                        withAnimation(reduceMotion ? nil : .spring(response: 0.38, dampingFraction: 0.82)) { selectedDay = date }
                    } label: {
                        VStack(spacing: 4) {
                            Text(["一","二","三","四","五","六","日"][min(index, 6)]).font(.caption.weight(selected ? .bold : .regular)).foregroundStyle(selected ? pine : Color.secondary)
                            PineDayGlyph(activity: activityFraction(row), halves: halves(row, list), posture: postureDone(row, list), future: future, size: 36, animated: true, delay: 0.15 + 0.05 * Double(index))
                                .overlay { if glowDate == date { PineGlow() } }
                            Text(NativeDays.focus(dayKey: date, sessions: list, serverTag: row["short"].text)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }.frame(maxWidth: .infinity, minHeight: 72).padding(.vertical, 2)
                            .background {
                                if selected { RoundedRectangle(cornerRadius: 12, style: .continuous).fill(pineTint).matchedGeometryEffect(id: "day", in: weekSpace) }
                            }
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
    /// Yesterday closed all three while the app was not looked at: its glyph
    /// glows once instead of a full celebration a day late.
    private func checkYesterday(_ sessions: [String: [NativeDaySession]]) {
        let days = home["days"].array
        guard let index = days.firstIndex(where: { $0["date"] == home["date"] }), index > 0 else { return }
        let row = days[index - 1], date = row["date"].text, list = sessions[date] ?? []
        let defaults = UserDefaults.standard, key = "pine.celebrated." + date + ".all"
        guard !defaults.bool(forKey: key) else { return }
        let half = halves(row, list)
        let strength = NativeDays.isWeekend(date) ? (half.first ?? 0) >= 1 : half.count >= 2 && half.prefix(2).allSatisfy { $0 >= 1 }
        guard (activityFraction(row) ?? 0) >= 1, strength, postureDone(row, list) else { return }
        defaults.set(true, forKey: key)
        Task { try? await Task.sleep(for: .seconds(1.2)); glowDate = date; try? await Task.sleep(for: .seconds(2.5)); glowDate = "" }
    }
    private func weekToggle(_ kind: WeekDetail, title: String, value: String, suffix: String, tint: Bool) -> some View {
        let open = weekDetail == kind
        return Button {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { weekDetail = open ? nil : kind }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(title).font(.footnote).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Text(value).font(.headline).monospacedDigit().foregroundStyle(tint ? pine : Color.primary)
                    .contentTransition(reduceMotion ? .identity : .numericText()).animation(reduceMotion ? nil : .snappy, value: value)
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
            NavigationLink(value: NativeOverviewRoute.strength) {
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
            NavigationLink(value: NativeOverviewRoute.weight) {
                thirdTile("体重", NativeGain.rate(home["weights"].array, today: home["date"].text).map { "增速" + NativeGain.status($0.percentPerMonth) } ?? weight.change, weight.value, weight.value == "—" ? "" : "公斤", nil)
            }.buttonStyle(PinePressStyle()).accessibilityIdentifier("metric-weight")
        }.background(pineSurface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
    /// Before 17:00 last night's sleep against the personal need; afterwards a
    /// suggested bedtime: the usual wake time minus the need and the usual awake
    /// time in bed.
    private var sleepSummary: (title: String, detail: String, value: String, unit: String) {
        // Fixed 8-hour target, the same one the server's recovery score uses.
        let need = NativeDays.sleepTargetHours
        let needText = "目标 " + displayNumber(.number(need), digits: 0)
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
                // The recovery score counts up from zero when the page opens.
                if let animated { PineCountUp(value: animated, font: .title3.weight(.semibold)).foregroundStyle(.primary) }
                else { Text(value).font(.title3.weight(.semibold)).monospacedDigit().foregroundStyle(.primary) }
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
        }.navigationTitle("数据与同步").navigationBarTitleDisplayMode(.inline)
    }
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
                Text(plan["version"].integer == 2 ? "本轮按 A、B、E、C、D 五天顺序进行，可以跨周；每天可以选公司+家庭、只公司或只家庭。" : "本轮可以跨周，可选 E 不影响主训练进度。").font(.footnote).foregroundStyle(.secondary)
            }
            if plan["version"].integer == 2 {
                // The new round: one row per day; how a day was trained does not matter.
                Section("五天") {
                    ForEach(Array(plan["schedule"].array.enumerated()), id: \.offset) { _, day in
                        HStack {
                            Text(day["letter"].text).font(.headline).frame(width: 28)
                            Text(day["slots"][0]["name"].text.components(separatedBy: "｜").last ?? "").font(.subheadline)
                            Spacer()
                            if day["completed"].flag { Image(systemName: "checkmark.circle.fill").foregroundStyle(pine) }
                            else { Text("\(day["done"].integer)/\(day["target"].integer) 组").font(.subheadline).monospacedDigit().foregroundStyle(.secondary) }
                        }
                    }
                }
            }
            ForEach(Array((plan["version"].integer == 2 ? [] : plan["schedule"].array).enumerated()), id: \.offset) { _, day in
                Section("第\(day["day"].integer)天 · " + day["letter"].text + (day["optional"].flag ? " · 可选" : "")) {
                    ForEach(Array(day["slots"].array.enumerated()), id: \.offset) { _, item in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(item["name"].text).font(.headline)
                            HStack { Text("\(item["done"].integer)/\(item["target"].integer) 组").font(.subheadline).foregroundStyle(.secondary); Spacer(); if item["completed"].flag { Image(systemName: "checkmark.circle.fill").foregroundStyle(pine) } else { Button(item["done"].integer > 0 ? "继续" : "开始") { dismiss(); store.homeAction(["template_id": item["template_id"], "remaining": item["remaining"]]) }.buttonStyle(.bordered) } }
                        }.padding(.vertical, 4)
                    }
                }
            }
            let streaks = NativeMedals.streaks
            if !streaks.isEmpty {
                Section("体态徽章") {
                    ForEach(Array(streaks.enumerated()), id: \.offset) { _, badge in
                        HStack(spacing: 12) {
                            PineStreakBadge(count: badge.count).frame(width: 40, height: 40)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("体态连续 \(badge.count) 天").font(.subheadline.weight(.semibold))
                                Text(dayTitle(badge.date, format: "M月d日") + " 达成").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            let medals = NativeMedals.all
            if !medals.isEmpty {
                Section("奖章") {
                    ForEach(medals.reversed(), id: \.round) { medal in
                        HStack(spacing: 12) {
                            PineMedal(round: medal.round).frame(width: 40, height: 40)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("第 \(medal.round) 轮").font(.subheadline.weight(.semibold))
                                Text(dayTitle(medal.date, format: "M月d日") + " 完成 · \(medal.sets) 组").font(.caption).foregroundStyle(.secondary)
                            }
                        }
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

struct NativeRecoveryContent: View {
    @Environment(NativeStore.self) var store
    var body: some View {
        let home=store.home, score=home["recovery"]
        PinePage {
            VStack(spacing: 2) {
                // A half dial sweeps to the score while the number counts up.
                ZStack(alignment: .bottom) {
                    PineHalfDial(fraction: (score["score"].number ?? 0) / 100, lineWidth: 14).frame(width: 260, height: 137)
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        if let value = score["score"].number { PineCountUp(value: value, font: .system(size: 64, weight: .semibold, design: .rounded), duration: 1.0) }
                        else { Text("—").font(.system(size: 64, weight: .semibold, design: .rounded)) }
                        Text("/ 100").font(.headline).foregroundStyle(.secondary)
                    }
                }.accessibilityElement(children: .combine).accessibilityLabel("恢复指数 " + displayNumber(score["score"], digits: 0) + " 分，满分 100")
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
                    PineRow(label: "睡眠", value: recoveryPosition(score["components"]["sleep"]) + " · 目标 " + displayNumber(score["sleep_need"], digits: 0) + " 小时")
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
        }.navigationTitle("每日记录").navigationBarTitleDisplayMode(.inline)
    }
}

/// Body-weight readings, newest first, with the change from each previous one.
/// Lean-gain pace against a band for a newer lifter: 0.5–1 % of body weight a
/// month. Slower rarely builds much muscle; faster mostly adds fat.
enum NativeGain {
    static let band = 0.5...1.0
    static func rate(_ rows: [JSONValue], today: String) -> (percentPerMonth: Double, kgPerMonth: Double, average: Double)? {
        NativeDays.weightRate(rows.compactMap { row in row["kg"].number.map { (date: row["date"].text, kg: $0) } }, today: today)
    }
    static func status(_ percent: Double) -> String { percent < band.lowerBound ? "偏慢" : percent > band.upperBound ? "偏快" : "合适" }
    static func advice(_ percent: Double) -> String {
        if percent < 0 { return "近 4 周体重在往下走，增肌很难。每天多吃约 300–400 千卡，比如多一碗米饭加一杯牛奶。" }
        if percent < band.lowerBound { return "涨得偏慢。每天多吃约 200–300 千卡，比如多一份主食或一杯牛奶。" }
        if percent > band.upperBound { return "涨得偏快，多出来的多半是脂肪。每天少吃约 200 千卡，同时留意腰围。" }
        return "节奏合适，保持现在的吃法。腰围每月增加不超过约 1 厘米就说明主要在长肌肉。"
    }
}
/// Protein eaten today, tapped in by portions; kept on this phone.
enum NativeProtein {
    static let key = "pine.protein"
    static func all() -> [String: Double] { UserDefaults.standard.dictionary(forKey: key) as? [String: Double] ?? [:] }
    static func add(_ grams: Double, on date: String) {
        var rows = all(); rows[date] = max(0, (rows[date] ?? 0) + grams)
        // Keep about two months.
        if rows.count > 70 { for old in rows.keys.sorted().prefix(rows.count - 70) { rows[old] = nil } }
        UserDefaults.standard.set(rows, forKey: key)
    }
    /// 1.6 g per kg of body weight, rounded to 5 g.
    static func target(kg: Double) -> Double { (kg * 1.6 / 5).rounded() * 5 }
}
/// Shoulder circumference over waist, pairing each shoulder reading with the
/// waist reading closest in time (within ten days).
enum NativeShape {
    static func ratios(_ entries: [NativeMeasurements.Entry]) -> [(date: String, ratio: Double)] {
        let waists = entries.filter { $0.kind == NativeMeasurements.Kind.waist.rawValue }
        func day(_ key: String) -> Double { (NativeDate.parse(key + "T12:00:00Z")?.timeIntervalSince1970 ?? 0) / 86400 }
        return entries.filter { $0.kind == NativeMeasurements.Kind.shoulder.rawValue }.sorted { $0.date < $1.date }.compactMap { shoulder in
            guard let waist = waists.min(by: { abs(day($0.date) - day(shoulder.date)) < abs(day($1.date) - day(shoulder.date)) }),
                  abs(day(waist.date) - day(shoulder.date)) <= 10, waist.cm > 0 else { return nil }
            return (shoulder.date, shoulder.cm / waist.cm)
        }
    }
}

struct NativeWeightList: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(NativeStore.self) private var store
    let rows: [JSONValue]
    @State private var protein = NativeProtein.all()
    @State private var entries = NativeMeasurements.entries()
    private var today: String { store.home["date"].text.isEmpty ? NativeDate.day(Date(), timezone: TimeZone.current.identifier) : store.home["date"].text }
    var body: some View {
        let sorted = rows.filter { $0["kg"].number != nil }.sorted { $0["date"].text > $1["date"].text }
        let rate = NativeGain.rate(rows, today: today)
        let kg = rate?.average ?? sorted.first?["kg"].number
        List {
            Section {
                if let rate {
                    HStack(alignment: .firstTextBaseline) {
                        Text(NativeGain.status(rate.percentPerMonth)).font(.title3.weight(.semibold))
                            .foregroundStyle(NativeGain.status(rate.percentPerMonth) == "合适" ? pine : Color.primary)
                        Spacer()
                        Text(signed(rate.kgPerMonth) + " 公斤/月").font(.subheadline.weight(.semibold)).monospacedDigit()
                    }
                    gainBar(rate.percentPerMonth)
                    Text(paceText(percent: rate.percentPerMonth, average: rate.average))
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    Text(NativeGain.advice(rate.percentPerMonth)).font(.subheadline)
                } else {
                    Text("近 4 周至少称 6 次、跨度两周以上后显示。每周称 3 次以上，固定在早上起床后。").font(.subheadline).foregroundStyle(.secondary)
                }
            } header: { Text("增肌速度") } footer: { Text("目标每月涨体重的 0.5–1%：力量训练前一两年的常用增肌节奏。按每天的称重拟合趋势，单次波动不影响。") }
            Section {
                let eaten = protein[today] ?? 0, goal = kg.map(NativeProtein.target) ?? 0
                HStack(alignment: .firstTextBaseline) {
                    Text(displayNumber(.number(eaten), digits: 0) + " 克").font(.title3.weight(.semibold)).monospacedDigit()
                        .contentTransition(.numericText(value: eaten))
                    if goal > 0 { Text("/ " + displayNumber(.number(goal), digits: 0)).font(.subheadline).foregroundStyle(.secondary) }
                    Spacer()
                    if goal > 0, eaten >= goal { Label("达标", systemImage: "checkmark").font(.subheadline.weight(.semibold)).foregroundStyle(pine) }
                }
                if goal > 0 { ProgressView(value: min(1, eaten / goal)).tint(pine) }
                HStack(spacing: 8) {
                    ForEach([20.0, 30.0, 50.0], id: \.self) { grams in
                        Button("+\(Int(grams))") { addProtein(grams) }.buttonStyle(.bordered).tint(pine)
                    }
                    Spacer()
                    Button("撤销", systemImage: "arrow.uturn.backward") { addProtein(-10) }.labelStyle(.iconOnly).buttonStyle(.bordered).disabled(eaten <= 0)
                }.font(.subheadline.weight(.semibold))
                let week = (0..<7).compactMap { offset -> Double? in
                    guard let date = NativeDate.parse(today + "T12:00:00Z")?.addingTimeInterval(-Double(offset) * 86400) else { return nil }
                    return protein[NativeDate.day(date, timezone: "UTC")]
                }
                if goal > 0, !week.isEmpty { Text("近 7 天记录了 \(week.count) 天，其中 \(week.filter { $0 >= goal }.count) 天达标").font(.caption).foregroundStyle(.secondary) }
            } header: { Text("今天的蛋白质") } footer: { Text("每公斤体重约 1.6 克，分到三四顿。参考：一个鸡蛋约 6 克，一杯牛奶约 8 克，一掌心肉或鱼约 25 克，一勺蛋白粉约 25 克。只保存在这台手机上。") }
            Section {
                let ratios = NativeShape.ratios(entries)
                if let last = ratios.last {
                    HStack(alignment: .firstTextBaseline) {
                        Text(displayNumber(.number(last.ratio), digits: 2)).font(.title3.weight(.semibold)).monospacedDigit()
                        Spacer()
                        if let first = ratios.first, ratios.count > 1 {
                            let change = ((last.ratio - first.ratio) * 100).rounded() / 100
                            Text("自 \(dayTitle(first.date, format: "M月d日")) \(signed(change))")
                                .font(.subheadline).foregroundStyle(change > 0 ? pine : Color.secondary).monospacedDigit()
                        }
                    }
                    Text("肩围 ÷ 腰围。肩变宽、腰不变粗，这个数就往上走，是外形变化最直接的指标。常被当作理想参考的是 1.6 左右。").font(.footnote).foregroundStyle(.secondary)
                } else {
                    Text("记录肩围和腰围（相隔不超过 10 天）后显示。").font(.subheadline).foregroundStyle(.secondary)
                }
                NavigationLink { NativeMeasurementsView() } label: { Label("围度与对比照片", systemImage: "ruler") }
            } header: { Text("肩腰比") } footer: { Text("腰围每周一次，臂围和肩围每月一次。") }
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
        }.navigationTitle("体重与体型").navigationBarTitleDisplayMode(.inline)
            .onAppear { entries = NativeMeasurements.entries(); protein = NativeProtein.all() }
    }
    private func signed(_ value: Double) -> String { (value >= 0 ? "+" : "") + displayNumber(.number(value), digits: 2) }
    private func paceText(percent: Double, average: Double) -> String {
        let avg: String = displayNumber(.number(average), digits: 1)
        return "近 4 周每月 \(signed(percent))% · 7 天平均 \(avg) 公斤"
    }
    private func addProtein(_ grams: Double) {
        NativeProtein.add(grams, on: today)
        withAnimation(.snappy) { protein = NativeProtein.all() }
    }
    /// The month's pace on a 0–1.5 % scale with the target band shaded.
    private func gainBar(_ percent: Double) -> some View {
        GeometryReader { proxy in
            let w = proxy.size.width, scale = 1.5
            let x = { (v: Double) in CGFloat(max(0, min(scale, v)) / scale) * w }
            ZStack(alignment: .leading) {
                Capsule().fill(pineTrack).frame(height: 8)
                Capsule().fill(pine.opacity(0.3)).frame(width: x(NativeGain.band.upperBound) - x(NativeGain.band.lowerBound), height: 8).offset(x: x(NativeGain.band.lowerBound))
                Circle().fill(pine).frame(width: 14, height: 14).overlay(Circle().stroke(pineSurface, lineWidth: 2)).offset(x: x(percent) - 7)
            }.frame(height: 14)
        }.frame(height: 14).accessibilityHidden(true)
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

struct PineHorizontalLine: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path(); path.move(to: CGPoint(x: rect.minX, y: rect.midY)); path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY)); return path
    }
}

/// A single gold pulse with a few sparks around a small glyph.
struct PineGlow: View {
    @State private var on = false
    @PineReducedMotion private var reduceMotion
    var body: some View {
        ZStack {
            if !reduceMotion { PineSparkBurst(radius: 26, count: 12, duration: 0.9).frame(width: 70, height: 70) }
            Circle().stroke(pineGold, lineWidth: 2).scaleEffect(on ? 1.5 : 0.9).opacity(on ? 0 : 1)
        }
        .allowsHitTesting(false).accessibilityHidden(true)
        .onAppear { withAnimation(.easeOut(duration: 1.1)) { on = true } }
    }
}

/// Girths kept on this phone: waist weekly, arm and shoulders monthly.
enum NativeMeasurements {
    enum Kind: String, CaseIterable, Identifiable {
        case waist, arm, shoulder
        var id: String { rawValue }
        var title: String { switch self { case .waist: return "腰围"; case .arm: return "上臂围"; case .shoulder: return "肩围" } }
        var days: Int { self == .waist ? 7 : 30 }
        var how: String {
            switch self {
            case .waist: return "早上空腹、自然呼气后，软尺贴着皮肤过肚脐绕一圈，不要勒紧。"
            case .arm: return "右臂放松下垂，量上臂最粗的地方。"
            case .shoulder: return "站直、双臂自然下垂，软尺绕过两侧肩膀最宽处一圈。"
            }
        }
    }
    struct Entry: Codable, Identifiable, Equatable { var id = UUID(); let kind: String; let date: String; let cm: Double }
    struct Photo: Codable, Identifiable, Equatable { var id = UUID(); let date: String; let file: String }
    static let key = "pine.measurements", photosKey = "pine.photos"
    static func entries() -> [Entry] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
    }
    static func save(_ entries: [Entry]) { UserDefaults.standard.set(try? JSONEncoder().encode(entries), forKey: key) }
    static func photos() -> [Photo] {
        guard let data = UserDefaults.standard.data(forKey: photosKey) else { return [] }
        return (try? JSONDecoder().decode([Photo].self, from: data)) ?? []
    }
    static func savePhotos(_ photos: [Photo]) { UserDefaults.standard.set(try? JSONEncoder().encode(photos), forKey: photosKey) }
    static var folder: URL {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("pine-photos", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    /// Latest value and the change against the reading at least 25 days earlier.
    static func latest(_ kind: Kind, in list: [Entry]) -> (value: Double, date: String, change: Double?)? {
        let rows = list.filter { $0.kind == kind.rawValue }.sorted { $0.date > $1.date }
        guard let last = rows.first else { return nil }
        let older = rows.first { entry in
            guard let a = NativeDate.parse(last.date + "T12:00:00Z"), let b = NativeDate.parse(entry.date + "T12:00:00Z") else { return false }
            return a.timeIntervalSince(b) >= 25 * 86400
        }
        return (last.cm, last.date, older.map { ((last.cm - $0.cm) * 10).rounded() / 10 })
    }
}

struct NativeMeasurementsView: View {
    @Environment(NativeStore.self) var store
    @State private var entries = NativeMeasurements.entries()
    @State private var photos = NativeMeasurements.photos()
    @State private var editing: NativeMeasurements.Kind?
    @State private var picked: PhotosPickerItem?
    @State private var viewing: NativeMeasurements.Photo?
    @State private var comparing = false
    private var today: String { store.home["date"].text.isEmpty ? NativeDate.day(Date(), timezone: TimeZone.current.identifier) : store.home["date"].text }
    var body: some View {
        List {
            ForEach(NativeMeasurements.Kind.allCases) { kind in
                Section {
                    let latest = NativeMeasurements.latest(kind, in: entries)
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(latest.map { displayNumber(.number($0.value)) + " 厘米" } ?? "还没有记录").font(.title3.weight(.semibold)).monospacedDigit()
                            if let latest {
                                Text(dayTitle(latest.date, format: "M月d日") + (latest.change.map { " · 4周 " + ($0 >= 0 ? "+" : "") + displayNumber(.number($0)) } ?? ""))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        let due = latest.map { (NativeDate.parse(today + "T12:00:00Z")?.timeIntervalSince(NativeDate.parse($0.date + "T12:00:00Z") ?? .distantPast) ?? 0) >= Double(kind.days - 1) * 86400 } ?? true
                        Button(due ? "记录" : "更新") { editing = kind }.buttonStyle(.borderedProminent).tint(due ? pine : .secondary)
                    }
                    ForEach(entries.filter { $0.kind == kind.rawValue }.sorted { $0.date > $1.date }.prefix(6)) { entry in
                        HStack { Text(dayTitle(entry.date, format: "M月d日 EEE")); Spacer(); Text(displayNumber(.number(entry.cm)) + " 厘米").monospacedDigit() }
                            .font(.subheadline).foregroundStyle(.secondary)
                            .swipeActions { Button("删除", role: .destructive) { entries.removeAll { $0.id == entry.id }; NativeMeasurements.save(entries) } }
                    }
                } header: { Text(kind.title + (kind == .waist ? " · 每周" : " · 每月")) } footer: { Text(kind.how) }
            }
            Section {
                PhotosPicker(selection: $picked, matching: .images) { Label("添加今天的照片", systemImage: "camera") }
                if photos.count >= 2 { Button { comparing = true } label: { Label("第一张和最新一张对比", systemImage: "rectangle.split.2x1") } }
                if !photos.isEmpty {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                        ForEach(photos.sorted { $0.date > $1.date }) { photo in
                            Button { viewing = photo } label: {
                                ZStack(alignment: .bottomLeading) {
                                    photoImage(photo).resizable().scaledToFill().frame(height: 120).clipped()
                                    Text(dayTitle(photo.date, format: "M/d")).font(.caption2.weight(.semibold)).foregroundStyle(.white).padding(4)
                                }.clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            }.buttonStyle(.plain)
                        }
                    }.padding(.vertical, 4)
                }
            } header: { Text("对比照片 · 每月") } footer: { Text("同样的光线和站姿，正面、侧面、背面各一张。围度和照片只保存在这台手机上，不上传服务器；删除 App 会一起删除。") }
        }
        .navigationTitle("围度与照片").navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editing) { kind in NavigationStack { NativeMeasurementEntry(kind: kind, date: today) { value in
            entries.append(.init(kind: kind.rawValue, date: today, cm: value)); NativeMeasurements.save(entries)
        } }.presentationDetents([.medium]) }
        .sheet(item: $viewing) { photo in
            NavigationStack {
                photoImage(photo).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.black)
                    .navigationTitle(dayTitle(photo.date, format: "M月d日")).navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) { Button("完成") { viewing = nil } }
                        ToolbarItem(placement: .destructiveAction) { Button("删除", role: .destructive) { remove(photo); viewing = nil } }
                    }
            }
        }
        .sheet(isPresented: $comparing) {
            let sorted = photos.sorted { $0.date < $1.date }
            NavigationStack {
                HStack(spacing: 4) {
                    ForEach([sorted.first, sorted.last].compactMap { $0 }) { photo in
                        VStack(spacing: 6) {
                            photoImage(photo).resizable().scaledToFit()
                            Text(dayTitle(photo.date, format: "M月d日")).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }.padding().navigationTitle("对比").navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { comparing = false } } }
            }
        }
        .onChange(of: picked) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data), let jpeg = image.jpegData(compressionQuality: 0.85) {
                    let file = UUID().uuidString + ".jpg"
                    try? jpeg.write(to: NativeMeasurements.folder.appendingPathComponent(file), options: .completeFileProtection)
                    photos.append(.init(date: today, file: file)); NativeMeasurements.savePhotos(photos)
                }
                picked = nil
            }
        }
    }
    private func photoImage(_ photo: NativeMeasurements.Photo) -> Image {
        let path = NativeMeasurements.folder.appendingPathComponent(photo.file).path
        return UIImage(contentsOfFile: path).map { Image(uiImage: $0) } ?? Image(systemName: "photo")
    }
    private func remove(_ photo: NativeMeasurements.Photo) {
        try? FileManager.default.removeItem(at: NativeMeasurements.folder.appendingPathComponent(photo.file))
        photos.removeAll { $0.id == photo.id }; NativeMeasurements.savePhotos(photos)
    }
}

struct NativeMeasurementEntry: View {
    @Environment(\.dismiss) private var dismiss
    let kind: NativeMeasurements.Kind
    let date: String
    let save: (Double) -> Void
    @State private var text = ""
    var body: some View {
        Form {
            Section {
                HStack {
                    TextField("例如 80.5", text: $text).keyboardType(.decimalPad).font(.title2.weight(.semibold)).monospacedDigit()
                    Text("厘米").foregroundStyle(.secondary)
                }
            } footer: { Text(kind.how) }
        }
        .navigationTitle(kind.title + " · " + dayTitle(date, format: "M月d日")).navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") { if let value = Double(text.replacingOccurrences(of: ",", with: ".")) { save(value); dismiss() } }
                    .disabled(Double(text.replacingOccurrences(of: ",", with: ".")).map { $0 < 10 || $0 > 300 } ?? true)
            }
        }
    }
}

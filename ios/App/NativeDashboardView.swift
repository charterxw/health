import SwiftUI

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
    /// The observation stayed "pending" through every poll.
    @State private var briefSlow = false
    @State private var briefRetry = 0
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
        .task(id: home["date"].text) {
            guard !home.isNull, !store.isDesignPreview else { return }
            checkYesterday(sessions)
            await NativeBodySync.sync(store.api)
        }
        .task(id: store.brief["status"].text + "|\(briefRetry)") {
            briefSlow = false
            guard !store.isDesignPreview, store.brief["status"].text == "pending" else { return }
            for _ in 0..<60 {
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
                await store.loadBrief(); if store.brief["status"].text != "pending" { return }
            }
            briefSlow = true
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
    private var feelings: String {
        let sore: [String] = home["feedback"]["soreness"].array.map(\.text)
        var parts: [String] = [home["feedback"]["energy"].text, home["feedback"]["fatigue"].text]
        if sore.count > 2 { parts.append("\(sore.count) 处酸痛") } else if !sore.isEmpty { parts.append(sore.joined(separator: "、") + "酸") }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }
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
        let pending = store.brief["status"].text == "pending" && !briefSlow
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
                Button { briefRetry += 1; Task { await store.loadBrief(force: true) } } label: {
                    Image(systemName: "sparkles").font(.footnote.weight(.semibold)).foregroundStyle(pending ? pineGold : pine)
                        .symbolEffect(.variableColor.iterative.reversing, options: .repeating, isActive: pending && !reduceMotion)
                        .frame(width: 28, height: 20).contentShape(Rectangle().inset(by: -12))
                }.buttonStyle(PinePressStyle(scale: 0.94)).disabled(pending || store.isDesignPreview)
                    .accessibilityLabel(pending ? "正在分析" : "立即重新分析")
            }
            NavigationLink { NativeBriefDetail() } label: {
                observationText(lines: lines, fallback: pending && lines.isEmpty ? "正在分析睡眠和恢复…" : briefSlow && lines.isEmpty ? "这次分析比平时慢，稍后打开会自动更新；也可以点右上角重新分析。" : summary).font(.subheadline).lineSpacing(2)
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

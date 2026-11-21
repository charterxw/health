import SwiftUI

// Pages and forms opened from the overview: observation, sync, metrics, goals,
// feelings, round progress, walks, recovery and a single day.
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
            if let problem = store.homeProblem {
                Section { Text("服务器的数据格式和这个 App 版本不一致（" + problem + "）。部分数字可能显示为“—”，更新 App 或服务器后会恢复。").font(.subheadline) }
            }
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
    /// The list shows the four weeks the chart covers; older days are one tap away.
    @State private var showingAll = false
    var body: some View {
        let rows = store.home["metrics"].array.sorted { $0["date"].text > $1["date"].text }
        let visible = showingAll ? rows : Array(rows.prefix(28))
        PinePage {
            Text(displayNumber(healthValue(store.home["today"][metric.id], key: metric.id)) + " " + metric.unit).font(.largeTitle.bold())
            MetricChart(rows: Array(rows.prefix(28).reversed()), key: metric.id).pineCard()
            VStack(spacing: 10) {
                ForEach(Array(visible.enumerated()), id: \.offset) { _, row in
                    PineRow(label: dayTitle(row["date"].text, format: "M月d日 EEE"), value: displayNumber(healthValue(row[metric.id], key: metric.id)) + " " + metric.unit)
                }
            }.pineCard()
            if rows.count > visible.count {
                Button("显示更早的 \(rows.count - visible.count) 天") { withAnimation(.easeOut(duration: 0.2)) { showingAll = true } }.font(.subheadline).frame(minHeight: 44)
            }
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
            // Two separate saves with different timing, each stated beside its button.
            Section {
                LabeledContent("每日步数") { TextField("每日步数", value: $steps, format: .number).keyboardType(.numberPad).multilineTextAlignment(.trailing) }
                Button("保存步数目标") { save(stepsOnly: true) }.disabled(busy || !(1000...50000).contains(steps))
            } header: { Text("步数 · 保存后立即生效") } footer: {
                if !(1000...50000).contains(steps) { Text("步数目标需要在 1,000 到 50,000 之间。").foregroundStyle(.red) }
            }
            Section {
                LabeledContent("每日活动千卡") { TextField("每日活动千卡", value: $daily, format: .number).keyboardType(.numberPad).multilineTextAlignment(.trailing) }
                LabeledContent("每周活动千卡") { TextField("每周活动千卡", value: $weekly, format: .number).keyboardType(.numberPad).multilineTextAlignment(.trailing) }
                Stepper("力量训练 \(strength) 天", value: $strength, in: 1...7)
                Stepper("体态练习 \(posture) 天", value: $posture, in: 1...7)
                Button("保存下周目标") { save(stepsOnly: false) }.disabled(busy || !(1...3000).contains(daily) || !(1...21000).contains(weekly))
            } header: { Text("活动与训练 · 从下周起生效") } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    if !(1...3000).contains(daily) { Text("每日活动需要在 1 到 3,000 千卡之间。").foregroundStyle(.red) }
                    if !(1...21000).contains(weekly) { Text("每周活动需要在 1 到 21,000 千卡之间。").foregroundStyle(.red) }
                    Text("生效日期：" + (store.home["next_effective"].text.isEmpty ? "下周一" : dayTitle(store.home["next_effective"].text, format: "M月d日 EEEE")) + "。本周仍按原目标计算。")
                }
            }
            if let error { Section { Text(error).foregroundStyle(.red) } }
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
    static let areas = ["胸", "背", "肩", "手臂", "腹", "下背", "臀", "大腿", "小腿", "颈"]
    @State private var energy = ""
    @State private var fatigue = ""
    @State private var sore: Set<String> = []
    @State private var stress = ""
    @State private var note = ""
    @State private var busy = false
    @State private var error: String?
    var body: some View {
        Form {
            Section {
                Picker("精神", selection: $energy) { Text("未记录").tag(""); ForEach(["充沛","一般","困倦"], id: \.self) { Text($0).tag($0) } }
                Picker("疲劳", selection: $fatigue) { Text("未记录").tag(""); ForEach(["轻","中","重"], id: \.self) { Text($0).tag($0) } }
                Picker("压力", selection: $stress) { Text("未记录").tag(""); ForEach(["低","中","高"], id: \.self) { Text($0).tag($0) } }
            }
            Section {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), spacing: 8)], alignment: .leading, spacing: 8) {
                    ForEach(Self.areas, id: \.self) { area in
                        let on = sore.contains(area)
                        Button { if on { sore.remove(area) } else { sore.insert(area) } } label: {
                            Text(area).font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 36)
                                .foregroundStyle(on ? Color.white : pine).background(on ? pine : pineTint, in: Capsule())
                        }.buttonStyle(.plain).accessibilityAddTraits(on ? .isSelected : [])
                    }
                }.padding(.vertical, 4)
            } header: { Text("哪里酸痛") } footer: { Text("观察会提醒今天少给这些部位加量。") }
            Section("备注") {
                TextField("例如：昨晚没睡好、左肩有点紧", text: $note, axis: .vertical).lineLimit(1...3)
            }
            if let error { Section { Text(error).foregroundStyle(.red) } }
            Button("保存今天的感受") { save() }.disabled(busy || note.count > 200)
        }.navigationTitle("今天的感受").toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
            .onAppear {
                let saved = store.home["feedback"]
                energy = saved["energy"].text; fatigue = saved["fatigue"].text; stress = saved["stress"].text; note = saved["note"].text
                sore = Set(saved["soreness"].array.map(\.text))
            }
    }
    private func save() {
        busy = true
        let body: JSONValue = ["energy": energy.isEmpty ? .null : .string(energy), "fatigue": fatigue.isEmpty ? .null : .string(fatigue),
                               "stress": stress.isEmpty ? .null : .string(stress), "note": .string(note),
                               "soreness": .array(Self.areas.filter { sore.contains($0) }.map { .string($0) })]
        Task {
            do { try await store.mutateHome("/home/feedback", body: body); dismiss() }
            catch let failure as HealthAPIError where failure.status == 422 {
                // A server from before sore areas, stress and notes: keep what it understands.
                do {
                    try await store.mutateHome("/home/feedback", body: ["energy": body["energy"], "fatigue": body["fatigue"]])
                    self.error = "精神和疲劳已保存；酸痛、压力和备注要等服务器更新后才能保存。"
                } catch { self.error = error.localizedDescription }
            }
            catch { self.error = error.localizedDescription }
            busy = false
        }
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
                PineRow(label: "今天感受", value: [home["feedback"]["energy"].text, home["feedback"]["fatigue"].text, home["feedback"]["stress"].text.isEmpty ? "" : "压力" + home["feedback"]["stress"].text].filter { !$0.isEmpty }.joined(separator: " · "))
                if !home["feedback"]["soreness"].array.isEmpty { PineRow(label: "酸痛部位", value: home["feedback"]["soreness"].array.map(\.text).joined(separator: "、")) }
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
            PineHeading(title: dayTitle(day["date"].text, format: "M月d日 EEEE"))
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
                if day["date"]==store.home["date"],!day["posture_recorded"].flag { Button("查看今天的体态练习") { dismiss();store.homeAction(["template_id": .string(store.postureTemplateID)]) } }
            }.pineCard()
        }.navigationTitle("每日记录").navigationBarTitleDisplayMode(.inline)
    }
}

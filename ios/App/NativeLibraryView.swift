import SwiftUI
import Charts

struct NativeExerciseLibrary: View {
    @Environment(NativeStore.self) var store
    @Environment(\.dismiss) private var dismiss
    var onSelect: ((JSONValue) -> Void)? = nil
    @State private var query = ""
    @State private var category = "全部"
    @State private var creating = false
    private var rows: [JSONValue] {
        store.exercises.filter { ex in
            let text = ([ex["name"].text, ex["english_name"].text, ex["equipment"].text] + ex["muscles"].array.map(\.text) + ex["aliases"].array.map(\.text)).joined(separator: " ")
            return (category == "全部" || (category == "体态" ? NativeTraining.mobility(ex) : !NativeTraining.mobility(ex))) && (query.isEmpty || text.localizedCaseInsensitiveContains(query))
        }
    }
    var body: some View {
        List {
            Picker("类型", selection: $category) { Text("全部").tag("全部"); Text("力量").tag("力量"); Text("体态").tag("体态") }.pickerStyle(.segmented)
            ForEach(rows, id: \.id) { exercise in
                if let onSelect { Button { onSelect(exercise) } label: { exerciseRow(exercise) }.tint(.primary) }
                else { NavigationLink { NativeExerciseDetail(exercise: exercise) } label: { exerciseRow(exercise) } }
            }
            if rows.isEmpty { PineEmpty(title: "没有匹配的动作", symbol: "figure.strengthtraining.traditional") }
        }.navigationTitle(onSelect == nil ? "动作库" : "选择动作").searchable(text: $query, prompt: "动作、器械或肌群")
            .toolbar {
                if onSelect != nil { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
                ToolbarItem(placement: .topBarTrailing) { Button("自定义动作", systemImage: "plus") { creating = true }.labelStyle(.iconOnly) }
            }.sheet(isPresented: $creating) { NavigationStack { NativeExerciseCreator() } }
    }
    private func exerciseRow(_ ex: JSONValue) -> some View {
        HStack(spacing: 14) {
            Image(systemName: NativeTraining.mobility(ex) ? "figure.flexibility" : "dumbbell").font(.title3).foregroundStyle(pine).frame(width: 30)
            VStack(alignment: .leading, spacing: 5) {
                Text(ex["name"].text).font(.headline)
                Text([ex["equipment"].text, ex["muscles"].array.map(\.text).joined(separator: " · ")].filter { !$0.isEmpty }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
            }.padding(.vertical, 5)
        }
    }
}
struct NativeExerciseDetail: View {
    @Environment(NativeStore.self) var store
    let exercise: JSONValue
    @State private var remote: JSONValue = .null
    @State private var error: String?
    @State private var unit = "lb"
    @State private var retry = 0
    @State private var editingNote = false
    /// "top" (best set), "e1rm" (estimated one-rep max) or "volume" (load × reps).
    @State private var metric = "top"
    private var mode: String { exercise["load_mode"].text }
    /// The measures that mean something for this lift, with their labels.
    private var metrics: [NativeLiftMetric] {
        if NativeTraining.timed(exercise) { return [.init(key: "top", title: "单组最长")] }
        if mode == "bodyweight" { return [.init(key: "top", title: "单组最多次数"), .init(key: "volume", title: "总次数")] }
        if mode == "assistance" { return [.init(key: "top", title: "最小辅助量")] }
        return [.init(key: "top", title: "最高重量"), .init(key: "e1rm", title: "估算 1RM"), .init(key: "volume", title: "总量")]
    }
    private var chartUnit: String {
        if NativeTraining.timed(exercise) { return "秒" }
        if mode == "bodyweight" { return "次" }
        return unit == "kg" ? "公斤" : "磅"
    }
    /// One point per session: the chosen measure over its completed work sets, and
    /// whether it beat every earlier session (lower is better for assistance).
    private var liftPoints: [NativeLiftPoint] {
        let timed = NativeTraining.timed(exercise), key = metrics.contains { $0.key == metric } ? metric : "top"
        var byDay: [String: Double] = [:]
        for session in history {
            let date = String(session["started_at"].text.prefix(10))
            for m in session["exercises"].array where m["exercise_id"].text == exercise.id && m["load_mode"].text == mode {
                let rows = NativeTraining.done(m).filter { !$0["warmup"].flag }
                guard !rows.isEmpty else { continue }
                let values: [Double] = rows.compactMap { row -> Double? in
                    let reps = row["reps"].number
                    if timed { return row["duration_seconds"].number }
                    if mode == "bodyweight" { return reps }
                    guard let weight = NativeTraining.convert(row["weight"], from: m["unit"].text, to: unit).number else { return nil }
                    switch key {
                    case "e1rm": return reps.map { weight * (1 + min($0, 20) / 30) }
                    case "volume": return reps.map { weight * $0 }
                    default: return weight
                    }
                }
                guard !values.isEmpty else { continue }
                let value = key == "volume" ? values.reduce(0, +) : mode == "assistance" ? values.min()! : values.max()!
                byDay[date] = byDay[date].map { key == "volume" ? $0 + value : mode == "assistance" ? min($0, value) : max($0, value) } ?? value
            }
        }
        var best: Double?
        let lowerIsBetter = mode == "assistance" && key == "top"
        let all = byDay.keys.sorted().compactMap { day -> NativeLiftPoint? in
            guard let value = byDay[day], let date = NativeDate.parse(day + "T12:00:00Z") else { return nil }
            let record = best.map { lowerIsBetter ? value < $0 - 0.01 : value > $0 + 0.01 } ?? false
            best = best.map { lowerIsBetter ? min($0, value) : max($0, value) } ?? value
            return NativeLiftPoint(day: day, date: date, value: (value * 10).rounded() / 10, record: record)
        }
        return Array(all.suffix(30))
    }
    private var history: [JSONValue] {
        var result: [String: JSONValue] = [:]
        for row in remote["records"].array where !store.deleted.contains(row["session"].id) { result[row["session"].id] = row["session"] }
        for s in store.history where !store.deleted.contains(s.id) && s["exercises"].array.contains(where: { $0["exercise_id"].text == exercise.id }) { result[s.id] = s }
        return result.values.sorted { $0["started_at"].text > $1["started_at"].text }
    }
    var body: some View {
        PinePage {
            PineHeading(title: exercise["name"].text, subtitle: exercise["english_name"].text)
            NativeMuscleMap(primary: exercise["primary_muscles"].array.map(\.text), secondary: exercise["secondary_muscles"].array.map(\.text)).pineCard()
            if !exercise["description"].text.isEmpty { Text(exercise["description"].text).font(.subheadline) }
            if !exercise["instructions"].array.isEmpty {
                VStack(alignment: .leading, spacing: 14) { Text("动作要领").font(.headline); ForEach(Array(exercise["instructions"].array.enumerated()), id: \.offset) { i, step in HStack(alignment: .top, spacing: 12) { Text("\(i + 1)").font(.caption.bold()).foregroundStyle(pine).padding(6).background(pine.opacity(0.1), in: Circle()); Text(step.text).font(.subheadline) } } }.pineCard()
            }
            if !exercise["weight_note"].text.isEmpty { PineBanner(text: exercise["weight_note"].text) }
            if !NativeTraining.mobility(exercise) {
                let setup = store.setupNote(exercise.id)
                Button { editingNote = true } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "note.text").foregroundStyle(pine).frame(width: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("器械设置备注").font(.footnote).foregroundStyle(.secondary)
                            Text(setup.isEmpty ? "例如座椅档位、握距，训练时会显示在动作名下方" : setup).font(.subheadline).foregroundStyle(setup.isEmpty ? Color.secondary : Color.primary).multilineTextAlignment(.leading)
                        }
                        Spacer(minLength: 8)
                        Text(setup.isEmpty ? "添加" : "修改").font(.subheadline.weight(.semibold)).foregroundStyle(pine)
                    }.frame(minHeight: 44).contentShape(Rectangle())
                }.buttonStyle(.plain).pineCard()
            }
            VStack(alignment: .leading, spacing: 12) {
                Text("主要肌群").font(.headline)
                Text(exercise["primary_muscles"].array.map { muscleName($0.text) }.joined(separator: " · ")).font(.subheadline)
                Text(exercise["secondary_muscles"].array.map { muscleName($0.text) }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
            }.pineCard()
            PineHeading(title: "历史表现", subtitle: "只统计已完成组；热身单独标记")
            let points = liftPoints
            if !points.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    if metrics.count > 1 {
                        Picker("指标", selection: $metric) { ForEach(metrics, id: \.key) { Text($0.title).tag($0.key) } }.pickerStyle(.segmented)
                    } else { Text(metrics[0].title).font(.headline) }
                    if mode != "bodyweight", !NativeTraining.timed(exercise) { Picker("图表单位", selection: $unit) { Text("磅").tag("lb"); Text("公斤").tag("kg") }.pickerStyle(.segmented) }
                    NativeLiftChart(points: points, unit: chartUnit)
                    let records = points.filter(\.record)
                    if let last = records.last {
                        let when = dayTitle(last.day, format: "M月d日"), value = displayNumber(.number(last.value))
                        Label("最近一次新纪录：\(when) · \(value) \(chartUnit)（共 \(records.count) 次）", systemImage: "medal.fill")
                            .font(.footnote).foregroundStyle(pineGold)
                    }
                    if metric == "e1rm" { Text("估算 1RM 按 Epley 公式：重量 × (1 + 次数 ÷ 30)，次数超过 20 按 20 计。只用于看趋势，不代表真的去试极限。").font(.caption).foregroundStyle(.secondary) }
                }.pineCard()
            }
            if let error { PineBanner(text: error); Button("重新加载") { retry += 1 } }
            if history.isEmpty { PineEmpty(title: "这个动作还没有记录", symbol: "chart.xyaxis.line") }
            ForEach(Array(history.enumerated()), id: \.offset) { _, s in
                VStack(alignment: .leading, spacing: 10) {
                    Text(dateLabel(s["started_at"])).font(.headline)
                    Text(s["title"].text).font(.caption).foregroundStyle(.secondary)
                    ForEach(Array(s["exercises"].array.filter { $0["exercise_id"].text == exercise.id }.enumerated()), id: \.offset) { _, m in
                        ForEach(Array(NativeTraining.done(m).enumerated()), id: \.offset) { i, row in PineRow(label: row["warmup"].flag ? "热身" : "第 \(i + 1) 组", value: loadText(m, row)) }
                    }
                }.pineCard()
            }
        }.navigationTitle("动作详情").navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $editingNote) { NativeSetupNoteEditor(exerciseID: exercise.id, name: exercise["name"].text).presentationDetents([.medium]) }
            .task(id: retry) {
            do { remote = try await store.api.request("/strength/exercises/" + exercise.id + "/history"); error = nil }
            catch { if !Task.isCancelled { self.error = "暂时无法读取完整历史，显示已保存在本机的记录。"; if (error as? HealthAPIError)?.status == 401 { store.handle(error) } } }
        }
    }
}
struct NativeLiftMetric: Hashable { let key: String; let title: String }
struct NativeLiftPoint: Identifiable, Equatable {
    var id: String { day }
    let day: String
    let date: Date
    let value: Double
    /// Better than every earlier session.
    let record: Bool
}
/// One lift across sessions, with new bests in gold.
struct NativeLiftChart: View {
    let points: [NativeLiftPoint]
    let unit: String
    var body: some View {
        Chart(points) { point in
            LineMark(x: .value("日期", point.date), y: .value(unit, point.value)).foregroundStyle(pine).interpolationMethod(.monotone)
            PointMark(x: .value("日期", point.date), y: .value(unit, point.value))
                .foregroundStyle(point.record ? pineGold : pine).symbolSize(point.record ? 90 : 28)
        }
        .chartYScale(domain: .automatic(includesZero: false))
        .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) { _ in AxisGridLine(); AxisValueLabel(format: .dateTime.month(.defaultDigits).day()) } }
        .frame(height: 190)
        .accessibilityLabel("动作历史曲线，金色点为新纪录")
    }
}
struct NativeExerciseCreator: View {
    @Environment(NativeStore.self) var store
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var equipment = ""
    @State private var mode = "external"
    @State private var tracking = "reps"
    @State private var type = "strength"
    @State private var note = ""
    @State private var error: String?
    @State private var busy = false
    var body: some View {
        Form {
            TextField("动作名称", text: $name); TextField("器械", text: $equipment)
            Picker("类型", selection: $type) { Text("力量").tag("strength"); Text("体态与活动度").tag("mobility") }
            Picker("记录方式", selection: $tracking) { Text("次数").tag("reps"); Text("秒数").tag("duration") }
            if tracking != "duration" { Picker("负荷", selection: $mode) { Text("外部负重").tag("external"); Text("辅助重量").tag("assistance"); Text("自重").tag("bodyweight") } }
            TextField("记重说明", text: $note, axis: .vertical)
            if let error { Text(error).foregroundStyle(.red) }
        }.navigationTitle("自定义动作").toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button("保存") { save() }.disabled(busy || name.trimmingCharacters(in: .whitespaces).isEmpty || name.count > 100 || equipment.count > 40 || note.count > 200) }
        }
    }
    private func save() {
        busy = true
        let exercise: JSONValue = ["id": .string("custom-" + UUID().uuidString.lowercased()), "name": .string(name), "equipment": .string(equipment),
            "load_mode": .string(tracking == "duration" ? "bodyweight" : mode), "tracking": .string(tracking), "training_type": .string(type), "weight_note": .string(note)]
        Task { do { try await store.createExercise(exercise); dismiss() } catch { self.error = error.localizedDescription }; busy = false }
    }
}

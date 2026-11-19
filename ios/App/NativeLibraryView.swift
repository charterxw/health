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
    private var chartTitle: String {
        if NativeTraining.timed(exercise) { return "单组最多秒数" }
        if exercise["load_mode"].text == "bodyweight" { return "单组最多次数" }
        return exercise["load_mode"].text == "assistance" ? "工作组最小辅助量" : "工作组最高重量"
    }
    private var chartRows: [JSONValue] {
        var values: [String: Double] = [:]
        let timed = NativeTraining.timed(exercise), mode = exercise["load_mode"].text
        for session in history {
            let date = String(session["started_at"].text.prefix(10))
            for m in session["exercises"].array where m["exercise_id"].text == exercise.id && m["load_mode"].text == mode {
                for row in NativeTraining.done(m) where !row["warmup"].flag {
                    let value = timed ? row["duration_seconds"].number : mode == "bodyweight" ? row["reps"].number : NativeTraining.convert(row["weight"], from: m["unit"].text, to: unit).number
                    guard let value else { continue }
                    values[date] = values[date].map { mode == "assistance" ? min($0, value) : max($0, value) } ?? value
                }
            }
        }
        return values.keys.sorted().suffix(30).map { ["date": .string($0), "value": .number(values[$0]!)] }
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
            VStack(alignment: .leading, spacing: 12) {
                Text("主要肌群").font(.headline)
                Text(exercise["primary_muscles"].array.map { muscleName($0.text) }.joined(separator: " · ")).font(.subheadline)
                Text(exercise["secondary_muscles"].array.map { muscleName($0.text) }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
            }.pineCard()
            PineHeading(title: "历史表现", subtitle: "只统计已完成组；热身单独标记")
            if !chartRows.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text(chartTitle).font(.headline)
                    if exercise["load_mode"].text != "bodyweight" { Picker("图表单位", selection: $unit) { Text("磅").tag("lb"); Text("公斤").tag("kg") }.pickerStyle(.segmented) }
                    MetricChart(rows: chartRows, key: "value")
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
        }.navigationTitle("动作详情").navigationBarTitleDisplayMode(.inline).task(id: retry) {
            do { remote = try await store.api.request("/strength/exercises/" + exercise.id + "/history"); error = nil }
            catch { if !Task.isCancelled { self.error = "暂时无法读取完整历史，显示已保存在本机的记录。"; if (error as? HealthAPIError)?.status == 401 { store.handle(error) } } }
        }
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

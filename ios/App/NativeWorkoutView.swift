import SwiftUI

struct SetSelection: Identifiable { let id: String; let movementID: String }
struct NativeWorkoutView: View {
    @Environment(NativeStore.self) var store
    @State private var finish = false
    @State private var discard = false
    @State private var adding = false
    @State private var options = false
    @State private var setSelection: SetSelection?
    @State private var editingMovement = false
    @State private var replacing = false
    @State private var showExercise = false
    @State private var lastEdited: String?
    private var record: NativeRecord? { store.active }
    private var session: JSONValue { record?.session ?? .null }
    private var mi: Int { min(store.movementIndex, max(0, session["exercises"].array.count - 1)) }
    private var movement: JSONValue { session["exercises"][mi] }
    var body: some View {
        NavigationStack {
            PinePage {
                if let row = record {
                    workoutHeader(row)
                    if !session["paused_at"].isNull { PineBanner(text: "训练已暂停，计时与休息倒计时保持不变。") }
                    if let message = store.message { PineBanner(text: message) }
                    if row.blocked != nil { NativeConflictView(record: row) }
                    if movement.isNull { PineEmpty(title: "添加第一个动作", symbol: "dumbbell", detail: "从动作库选择，开始记录这场训练。") }
                    else { movementCard }
                    Button("添加动作", systemImage: "plus") { adding = true }.buttonStyle(.bordered).frame(maxWidth: .infinity).disabled(session["exercises"].array.count >= 40)
                } else { PineEmpty(title: "没有进行中的训练", symbol: "checkmark.circle"); Button("返回") { store.workoutPresented = false } }
            }.navigationTitle("训练中").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { Button("收起", systemImage: "chevron.down") { store.workoutPresented = false }.labelStyle(.iconOnly) }
                    ToolbarItem(placement: .topBarTrailing) { Button("结束训练") { finish = true }.disabled(record == nil) }
                }
                .alert("完成这场训练？", isPresented: $finish) {
                    Button("继续记录", role: .cancel) { }
                    Button("完成并保存") { if let id = record?.id { store.finish(id) } }
                } message: { let p = NativeTraining.progress(session); Text("已完成 \(p.done)/\(p.planned) 工作组，热身 \(p.warmup) 组。未勾选的组不会计入完成记录。") }
                .confirmationDialog("放弃这场训练？", isPresented: $discard, titleVisibility: .visible) { Button("放弃训练", role: .destructive) { if let id = record?.id { store.finish(id, discard: true) } } }
                .sheet(isPresented: $adding) { NavigationStack { NativeExerciseLibrary { exercise in
                    mutate { s in s["exercises"] = .array(s["exercises"].array + [NativeTraining.movement(exercise)]) }; store.selectMovement(session["exercises"].array.count - 1); adding = false
                } } }
                .sheet(isPresented: $replacing) { NavigationStack { NativeExerciseLibrary { exercise in replace(exercise); replacing = false } } }
                .sheet(isPresented: $options) { workoutOptions }
                .sheet(isPresented: $editingMovement) { movementOptions }
                .sheet(isPresented: $showExercise) { NavigationStack { NativeExerciseDetail(exercise: store.exercises.first { $0.id == movement["exercise_id"].text } ?? movement).toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showExercise = false } } } } }
                .sheet(item: $setSelection) { selection in NativeSetOptions(sessionID: session.id, selection: selection) }
        }
    }
    private func workoutHeader(_ row: NativeRecord) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) { Text(session["title"].text).font(.title2.bold()); Spacer(); Button("训练选项", systemImage: "ellipsis.circle") { options = true }.labelStyle(.iconOnly).font(.title2) }
            HStack {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let end = NativeDate.parse(session["paused_at"]) ?? context.date
                    let seconds = max(0, end.timeIntervalSince(NativeDate.parse(session["started_at"]) ?? end) - (session["paused_seconds"].number ?? 0))
                    Label(WorkoutSnapshot.clock(seconds), systemImage: "timer").monospacedDigit().font(.title3.bold())
                }
                Spacer()
                let p = NativeTraining.progress(session)
                Text("\(p.done) / \(p.planned) 工作组").font(.subheadline).foregroundStyle(.secondary)
            }
            HStack { Label(row.blocked != nil ? "同步需要处理" : row.dirty ? "本机已保存 · 待同步" : "已保存到服务器", systemImage: row.dirty ? "arrow.triangle.2.circlepath" : "checkmark.icloud").font(.caption).foregroundStyle(.secondary); Spacer(); Button(session["paused_at"].isNull ? "暂停" : "继续", systemImage: session["paused_at"].isNull ? "pause.fill" : "play.fill") { mutate { $0 = NativeTraining.pause($0) } }.font(.subheadline) }
        }.pineCard()
    }
    private var movementCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Menu {
                    ForEach(Array(session["exercises"].array.enumerated()), id: \.offset) { index, item in Button("\(index + 1). " + item["name"].text) { store.selectMovement(index); lastEdited = nil } }
                } label: { Label("动作 \(mi + 1) / \(session["exercises"].array.count)", systemImage: "list.bullet").font(.subheadline) }
                Spacer()
                Button("动作设置", systemImage: "slider.horizontal.3") { editingMovement = true }.labelStyle(.iconOnly)
            }
            Text(movement["name"].text).font(.title2.bold())
            if !movement["weight_note"].text.isEmpty { Text(movement["weight_note"].text).font(.caption).foregroundStyle(.secondary) }
            if !movement["prescription"]["reason"].text.isEmpty { Text(movement["prescription"]["reason"].text).font(.footnote).foregroundStyle(pine) }
            previousPerformance
            HStack {
                Text("组").frame(width: 42)
                if movement["load_mode"].text != "bodyweight" { Text((movement["load_mode"].text == "assistance" ? "辅助 / " : "重量 / ") + unitLabel(movement)).frame(maxWidth: .infinity) }
                Text(NativeTraining.timed(movement) ? "秒数" : "次数").frame(maxWidth: .infinity)
                Text("完成").frame(width: 46)
            }.font(.caption).foregroundStyle(.secondary)
            ForEach(Array(movement["sets"].array.enumerated()), id: \.element.id) { si, row in setRow(si, row) }
            Button("添加一组", systemImage: "plus") { appendSet() }.font(.subheadline).frame(maxWidth: .infinity).frame(minHeight: 44).disabled(movement["sets"].array.count >= 50)
            restView
            HStack {
                Button("上一个", systemImage: "chevron.left") { store.selectMovement(mi - 1); lastEdited = nil }.disabled(mi == 0)
                Spacer()
                Button("下一个", systemImage: "chevron.right") { store.selectMovement(mi + 1); lastEdited = nil }.disabled(mi + 1 >= session["exercises"].array.count)
            }.font(.subheadline).frame(minHeight: 44)
        }.pineCard()
    }
    private var previousPerformance: some View {
        let hints = store.previousSets(exercise: movement["exercise_id"].text, mode: movement["load_mode"].text,
            before: session["started_at"], timezone: session["timezone"].text, current: session.id)
        return Group {
            if !hints.isEmpty {
                Text("上次：" + hints.filter { !$0["warmup"].flag }.map { prior in var row = prior; row["weight"] = NativeTraining.convert(prior["weight"], from: prior["unit"].text, to: movement["unit"].text); return loadText(movement, row) }.joined(separator: " / ")).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private func setRow(_ si: Int, _ row: JSONValue) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button { setSelection = SetSelection(id: row.id, movementID: movement.id) } label: {
                    VStack(spacing: 3) {
                        Text(row["warmup"].flag ? "热" : "\(movement["sets"].array.prefix(si + 1).filter { !$0["warmup"].flag }.count)").font(.subheadline.bold())
                        if !row["hard_reps"].isNull { Circle().fill(pine).frame(width: 4, height: 4) }
                    }.frame(width: 42, height: 44).background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10))
                }.buttonStyle(.plain).accessibilityLabel("第 \(si + 1) 组操作")
                if movement["load_mode"].text != "bodyweight" {
                    NativeNumberField(label: "第 \(si + 1) 组重量", value: row["weight"], decimal: true) { value in editSet(si, key: "weight", value: value) }.accessibilityIdentifier("set-\(si)-weight")
                }
                NativeNumberField(label: "第 \(si + 1) 组" + (NativeTraining.timed(movement) ? "秒数" : "次数"), value: row[NativeTraining.timed(movement) ? "duration_seconds" : "reps"], maximum: NativeTraining.timed(movement) ? 3600 : 1000, minimum: 1) { value in editSet(si, key: NativeTraining.timed(movement) ? "duration_seconds" : "reps", value: value) }.accessibilityIdentifier("set-\(si)-value")
                Button {
                    mutate { s in s = try NativeTraining.toggle(s, movement: mi, set: si) }
                    if !row["completed_at"].isNull || session["exercises"][mi]["sets"][si]["completed_at"].isNull { return }; UIImpactFeedbackGenerator(style: .light).impactOccurred()
                } label: { Image(systemName: row["completed_at"].isNull ? "circle" : "checkmark.circle.fill").font(.system(size: 29)).frame(width: 46, height: 46).foregroundStyle(row["completed_at"].isNull ? Color.secondary : pine) }
                    .buttonStyle(.plain).disabled(!session["paused_at"].isNull || store.storageFailed).accessibilityLabel(row["completed_at"].isNull ? "完成第 \(si + 1) 组" : "撤销第 \(si + 1) 组").accessibilityIdentifier("set-\(si)-complete")
            }
            if lastEdited == row.id, NativeTraining.valid(movement, row), movement["sets"].array.dropFirst(si + 1).contains(where: { $0["completed_at"].isNull && ($0["weight"] != row["weight"] || $0["reps"] != row["reps"] || $0["duration_seconds"] != row["duration_seconds"]) }) {
                Button("填入后续未完成组") { fillFollowing(si); lastEdited = nil }.font(.caption).frame(maxWidth: .infinity, alignment: .trailing).frame(minHeight: 44)
            }
        }
    }
    @ViewBuilder private var restView: some View {
        if let rest = NativeDate.parse(session["rest_until"]) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let reference = NativeDate.parse(session["paused_at"]) ?? context.date
                let remaining = max(0, rest.timeIntervalSince(reference))
                HStack {
                    VStack(alignment: .leading, spacing: 4) { Text(remaining > 0 ? "组间休息" : "休息结束").font(.caption); Text(WorkoutSnapshot.clock(ceil(remaining))).font(.title.bold().monospacedDigit()) }
                    Spacer()
                    Button("跳过") { mutate { $0["rest_until"] = .null; $0["rest_set_id"] = .null } }.buttonStyle(.bordered)
                }.padding(16).background(pine.opacity(0.09), in: RoundedRectangle(cornerRadius: 16))
            }
        }
    }
    private var workoutOptions: some View {
        NavigationStack {
            Form {
                Section("本次训练") {
                    TextField("名称", text: Binding(get: { session["title"].text }, set: { text in if !text.trimmingCharacters(in: .whitespaces).isEmpty && text.count <= 100 { mutate { $0["title"] = .string(text) } } }))
                    TextField("训练笔记", text: Binding(get: { session["notes"].text }, set: { text in if text.count <= 4000 { mutate { $0["notes"] = .string(text) } } }), axis: .vertical)
                    if !session["template_notes"].text.isEmpty { Text(session["template_notes"].text).font(.footnote).foregroundStyle(.secondary) }
                }
                Section { Button("放弃训练", role: .destructive) { options = false; discard = true } }
            }.navigationTitle("训练选项").toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { options = false } } }
        }
    }
    private var movementOptions: some View {
        NavigationStack {
            Form {
                Section(movement["name"].text) {
                    Picker("重量单位", selection: Binding(get: { movement["unit"].text }, set: changeUnit)) { Text("磅").tag("lb"); Text("公斤").tag("kg") }
                    HStack { Text("休息 / 秒"); NativeNumberField(label: "休息秒数", value: movement["rest_seconds"], maximum: 600) { value in mutate { $0["exercises"][mi]["rest_seconds"] = value.or(0) } } }
                    Picker("动作感受", selection: Binding(get: { movement["effort"].text }, set: { value in mutate { $0["exercises"][mi]["effort"] = value.isEmpty ? .null : .string(value) } })) { Text("未记录").tag(""); Text("轻松").tag("easy"); Text("适中").tag("normal"); Text("吃力").tag("hard") }
                    Button("动作要领与历史") { editingMovement = false; showExercise = true }
                    Button("替换未完成部分") { editingMovement = false; replacing = true }.disabled(movement["sets"].array.allSatisfy { !$0["completed_at"].isNull })
                }
            }.navigationTitle("动作设置").toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { editingMovement = false } } }
        }
    }
    private func mutate(_ action: (inout JSONValue) throws -> Void) { if let id = record?.id { store.update(id, action) } }
    private func editSet(_ si: Int, key: String, value: JSONValue) {
        guard movement["sets"][si][key] != value else { return }; lastEdited = movement["sets"][si].id
        mutate { s in
            s["exercises"][mi]["sets"][si][key] = value
            if key == "reps", s["exercises"][mi]["sets"][si]["hard_reps"].integer > value.integer { s["exercises"][mi]["sets"][si]["hard_reps"] = .null }
            if !NativeTraining.valid(s["exercises"][mi], s["exercises"][mi]["sets"][si]) {
                s["exercises"][mi]["sets"][si]["completed_at"] = .null
                if s["rest_set_id"] == s["exercises"][mi]["sets"][si]["id"] { s["rest_set_id"] = .null; s["rest_until"] = .null }
            }
        }
    }
    private func appendSet() {
        let source = movement["sets"].array.first { $0.id == lastEdited } ?? movement["sets"].array.last ?? .null
        mutate { s in s["exercises"][mi]["sets"] = .array(s["exercises"][mi]["sets"].array + [NativeTraining.newSet(["weight": source["weight"], "reps": source["reps"], "duration_seconds": source["duration_seconds"]])]) }
    }
    private func fillFollowing(_ si: Int) {
        let source = movement["sets"][si]
        mutate { s in
            var rows = s["exercises"][mi]["sets"].array
            for i in rows.indices where i > si && rows[i]["completed_at"].isNull { for key in ["weight","reps","duration_seconds"] { rows[i][key] = source[key] } }
            s["exercises"][mi]["sets"] = .array(rows)
        }
    }
    private func changeUnit(_ unit: String) {
        let old = movement["unit"].text
        if movement["sets"].array.contains(where: { (NativeTraining.convert($0["weight"], from: old, to: unit).number ?? 0) > 2000 }) { store.message = "转换后超过记重范围，保留原单位。"; return }
        mutate { s in
            s["exercises"][mi]["unit"] = .string(unit)
            var m = s["exercises"][mi]; m["sets"] = .array(m["sets"].array.map { var row = $0; row["weight"] = NativeTraining.convert(row["weight"], from: old, to: unit); return row })
            if !m["prescription"].isNull { m["prescription"]["weight"] = NativeTraining.convert(m["prescription"]["weight"], from: old, to: unit); m["prescription"]["increment"] = NativeTraining.convert(m["prescription"]["increment"], from: old, to: unit) }
            s["exercises"][mi] = m
        }
    }
    private func replace(_ exercise: JSONValue) {
        let completed = movement["sets"].array.filter { !$0["completed_at"].isNull }; let pending = movement["sets"].array.filter { $0["completed_at"].isNull }
        let plan: JSONValue = ["set_count": .number(Double(pending.count)), "warmup_count": .number(Double(pending.filter { $0["warmup"].flag }.count)), "unit": movement["unit"], "rest_seconds": movement["rest_seconds"]]
        let replacement = NativeTraining.movement(exercise, plan: plan)
        mutate { s in var rows = s["exercises"].array; if completed.isEmpty { rows[mi] = replacement } else { rows[mi]["sets"] = .array(completed); rows.insert(replacement, at: mi + 1) }; s["exercises"] = .array(rows) }
        if !completed.isEmpty { store.selectMovement(mi + 1) }
    }
}

struct NativeSetOptions: View {
    @Environment(NativeStore.self) var store
    @Environment(\.dismiss) private var dismiss
    let sessionID: String
    let selection: SetSelection
    @State private var hard: JSONValue = .null
    @State private var warmup = false
    @State private var confirming = false
    private var session: JSONValue { store.recordDocuments[sessionID]?.session ?? .null }
    private var mi: Int? { session["exercises"].array.firstIndex { $0.id == selection.movementID } }
    private var movement: JSONValue { mi.map { session["exercises"][$0] } ?? .null }
    private var si: Int? { movement["sets"].array.firstIndex { $0.id == selection.id } }
    private var row: JSONValue { si.map { movement["sets"][$0] } ?? .null }
    var body: some View {
        NavigationStack {
            Form {
                Section(movement["name"].text) {
                    Toggle("热身组", isOn: $warmup)
                    if !NativeTraining.timed(movement), !NativeTraining.mobility(movement) {
                        HStack { Text("最后几次明显吃力"); NativeNumberField(label: "吃力次数", value: hard, maximum: Double(row["reps"].integer)) { hard = $0 } }
                        Text("填 0 表示没有明显吃力，留空不记录。").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Section { Button("删除本组", role: .destructive) { confirming = true } }
            }.navigationTitle("组次选项").onAppear { hard = row["hard_reps"]; warmup = row["warmup"].flag }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("保存") { guard let mi, let si else { dismiss(); return }; store.update(sessionID) { $0["exercises"][mi]["sets"][si]["hard_reps"] = hard; $0["exercises"][mi]["sets"][si]["warmup"] = .bool(warmup) }; dismiss() }.disabled(!hard.isNull && hard.integer > row["reps"].integer) }
                }.confirmationDialog("删除这组实际记录？", isPresented: $confirming, titleVisibility: .visible) { Button("确认删除本组", role: .destructive) { remove() } } message: { Text(movement["sets"].array.count == 1 ? "这是最后一组，删除后也会移除此动作。" : "已完成的组也会从本次记录中移除。") }
        }
    }
    private func remove() {
        guard let mi, let si else { dismiss(); return }
        store.update(sessionID) { s in
            var ms = s["exercises"].array; var rows = ms[mi]["sets"].array; rows.remove(at: si)
            if rows.isEmpty { ms.remove(at: mi) } else { ms[mi]["sets"] = .array(rows) }; s["exercises"] = .array(ms)
            if s["rest_set_id"].text == selection.id { s["rest_until"] = .null; s["rest_set_id"] = .null }
        }; dismiss()
    }
}

import SwiftUI

private struct RoutineGroup: Identifiable {
    let id: String
    let letter: String
    let title: String
    let subtitle: String
    let optional: Bool
    let records: [JSONValue]
}
struct NativeTrainingView: View {
    @Environment(NativeStore.self) var store
    @State private var showingPlan = false
    private var groups: [RoutineGroup] {
        var grouped: [String: [JSONValue]] = [:]
        for record in store.templates {
            let t = record["template"], id = t.id
            let suffix = id.split(separator: "-").last.map(String.init) ?? ""
            let letter: String
            if id.hasPrefix("posture-") { letter = "体态" }
            else if id.hasPrefix("personal-company-") || id.hasPrefix("personal-home-") { letter = suffix.count == 1 ? suffix.uppercased() : "其他" }
            else if !t["rotation_order"].isNull { letter = String(UnicodeScalar(65 + max(0, min(25, t["rotation_order"].integer)))!) }
            else { letter = templateCategory(t) == "周末" ? "周末" : "其他" }
            grouped[letter, default: []].append(record)
        }
        let order = ["体态", "A", "B", "E", "C", "D", "周末", "其他"]
        return grouped.keys.sorted { (order.firstIndex(of: $0) ?? 99) < (order.firstIndex(of: $1) ?? 99) }.map { key in
            let rows = grouped[key]!
            var parts: [String] = []
            for r in rows { let name = r["template"]["name"].text.replacingOccurrences(of: "｜", with: "|").components(separatedBy: "|"); let focus = name.count > 1 ? name[1] : ""; for item in focus.components(separatedBy: "·").map({ $0.trimmingCharacters(in: .whitespaces) }) where !item.isEmpty && !parts.contains(item) { parts.append(item) } }
            let title = key == "体态" ? "体态练习" : parts.isEmpty ? (key == "其他" ? "其他模板" : key + " 轮训练") : parts.joined(separator: " · ")
            let locations = Set(rows.map { templateCategory($0["template"]) })
            let subtitle = key == "体态" ? "日常练习与独立动作" : [locations.contains("公司") ? "公司" : "", locations.contains("居家") ? "居家" : "", key == "E" ? "可选" : ""].filter { !$0.isEmpty }.joined(separator: " + ")
            return RoutineGroup(id: key, letter: key, title: title, subtitle: subtitle, optional: key == "E", records: rows)
        }
    }
    private var currentLetter: String {
        let id = store.home["plan"]["current"]["slots"][0]["template_id"].or(store.home["plan"]["next"]["template_id"]).text
        guard let record = store.templates.first(where: { $0["template"].id == id }) else { return "" }
        let t = record["template"]
        if !t["rotation_order"].isNull { return String(UnicodeScalar(65 + max(0, min(25, t["rotation_order"].integer)))!) }
        return id.split(separator: "-").last.map { String($0).uppercased() } ?? ""
    }
    @State private var slotChoice = 0
    var body: some View {
        PinePage {
            PineTabHeader(title: "训练") {
                Menu {
                    Button("自由训练", systemImage: "plus") { store.start() }.disabled(store.catalog.isNull)
                    NavigationLink("动作库", destination: NativeExerciseLibrary())
                    NavigationLink("全部模板", destination: NativeTemplateLibrary())
                } label: { PineCircleIcon(systemImage: "ellipsis") }.accessibilityLabel("训练工具").accessibilityIdentifier("training-tools")
            }
            if let active = store.active { continueCard(active) }
            if let message = store.message { PineBanner(text: message) }
            roundProgress
            nextSession
            postureRow
            if store.catalog.isNull { PineEmpty(title: "正在读取训练安排", symbol: "dumbbell", detail: "联网后下拉刷新即可读取你的模板。") }
            let rotation = groups.filter { $0.letter.count == 1 }
            if !rotation.isEmpty {
                PineSectionHeader(title: "本轮计划")
                VStack(spacing: 0) {
                    ForEach(Array(rotation.enumerated()), id: \.element.id) { index, group in
                        if index > 0 { Divider().padding(.leading, 60) }
                        NavigationLink { NativeRoutineGroupView(title: group.title, records: group.records) } label: { groupRow(group) }.buttonStyle(.plain)
                    }
                }.background(pineSurface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
            PineSectionHeader(title: "其他")
            VStack(spacing: 0) {
                ForEach(groups.filter { $0.letter.count > 1 && $0.letter != "体态" }) { group in
                    NavigationLink { NativeRoutineGroupView(title: group.title, records: group.records) } label: { plainRow(group.letter == "周末" ? "周末 · 保底训练" : group.title) }.buttonStyle(.plain)
                    Divider().padding(.leading, 16)
                }
                NavigationLink { NativeExerciseLibrary() } label: { plainRow("动作库") }.buttonStyle(.plain)
                Divider().padding(.leading, 16)
                NavigationLink { NativeTemplateLibrary() } label: { plainRow("全部模板") }.buttonStyle(.plain)
                Divider().padding(.leading, 16)
                NavigationLink { PinePage { weeklyMuscles.pineCard() }.navigationTitle("本周肌群工作组") } label: { plainRow("本周肌群工作组") }.buttonStyle(.plain)
            }.background(pineSurface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            ForEach(store.records.filter { $0.blocked != nil }, id: \.id) { NativeConflictView(record: $0) }
        }.navigationTitle("训练").refreshable { await store.refresh() }
            .sheet(isPresented: $showingPlan) { NavigationStack { NativePlanView() } }
    }

    // MARK: Round and next session
    private var roundProgress: some View {
        let plan = store.home["plan"]
        let done = plan["done"].integer, target = plan["target"].integer
        return Button { showingPlan = true } label: {
            HStack(spacing: 10) {
                ProgressView(value: Double(done), total: Double(max(1, target))).tint(pine)
                Text("本轮 \(done) / \(target) 组").font(.footnote).monospacedDigit().foregroundStyle(.secondary).fixedSize()
                Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
            }.frame(minHeight: 44).contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(plan.isNull).accessibilityLabel("本轮进度，已完成 \(done) 组，共 \(target) 组")
    }
    private var slots: [JSONValue] {
        let plan = store.home["plan"], current = plan["current"]["slots"].array
        return !current.isEmpty ? current : plan["next"].isNull ? [] : [plan["next"]]
    }
    @ViewBuilder private var nextSession: some View {
        let list = slots
        if store.home["plan"].isNull {
            Text("下拉刷新，读取最新安排。").font(.subheadline).foregroundStyle(.secondary).pineCard()
        } else if list.isEmpty || list.allSatisfy({ $0["completed"].flag }) {
            VStack(alignment: .leading, spacing: 8) {
                Label("本次安排都完成了", systemImage: "checkmark.circle").font(.headline).foregroundStyle(pine)
                Button("查看本轮进度") { showingPlan = true }.font(.subheadline).frame(minHeight: 44)
            }.pineCard()
        } else {
            let firstOpen = list.firstIndex { !$0["completed"].flag } ?? 0
            let index = list.indices.contains(slotChoice) ? slotChoice : firstOpen
            let slot = list[index]
            let name = slot["name"].text.components(separatedBy: "｜")
            let template = store.templates.first { $0["template"].id == slot["template_id"].text }?["template"] ?? .null
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(groupLabel(name.first ?? "")).font(.footnote).foregroundStyle(.secondary)
                        Text(name.count > 1 ? name[1] : slot["name"].text).font(.title2.weight(.semibold))
                    }
                    Spacer(minLength: 8)
                    if list.count > 1 {
                        Picker("地点", selection: Binding(get: { index }, set: { slotChoice = $0 })) {
                            ForEach(Array(list.enumerated()), id: \.offset) { i, item in Text(place(item["name"].text)).tag(i) }
                        }.pickerStyle(.segmented).frame(width: 120)
                    }
                }
                VStack(spacing: 0) {
                    ForEach(Array(template["exercises"].array.enumerated()), id: \.offset) { _, plan in exerciseLine(plan) }
                }.padding(.top, 10)
                if slot["completed"].flag {
                    Label("这一次已完成", systemImage: "checkmark").font(.subheadline).foregroundStyle(pine).frame(maxWidth: .infinity, minHeight: 52)
                } else {
                    Button { store.homeAction(["template_id": slot["template_id"], "remaining": slot["remaining"]]) } label: {
                        Label(slot["done"].integer > 0 ? "继续 · 还剩 \(max(0, slot["target"].integer - slot["done"].integer)) 组" : "开始 · \(slot["target"].integer) 组", systemImage: "play.fill")
                            .font(.headline).foregroundStyle(.white).frame(maxWidth: .infinity, minHeight: 52).background(pine, in: Capsule())
                    }.buttonStyle(PinePressStyle(scale: 0.98)).padding(.top, 12).disabled(store.catalog.isNull)
                }
            }.pineCard()
        }
    }
    private func groupLabel(_ prefix: String) -> String {
        let parts = prefix.components(separatedBy: " · ")
        return parts.count > 1 ? parts[0] + " 组" : prefix
    }
    private func place(_ name: String) -> String { name.contains("公司") ? "公司" : name.contains("家庭") ? "家庭" : "训练" }
    private func exerciseLine(_ plan: JSONValue) -> some View {
        let exercise = store.exercises.first { $0.id == plan["exercise_id"].text } ?? .null
        let mode = exercise["load_mode"].text
        let hints = store.previousSets(exercise: plan["exercise_id"].text, mode: mode, before: NativeDate.stamp(), timezone: TimeZone.current.identifier, current: "").filter { !$0["warmup"].flag }
        let detail: String = {
            guard let first = hints.first else { return "\(max(0, plan["set_count"].integer - plan["warmup_count"].integer)) 组" }
            var row = first; row["weight"] = NativeTraining.convert(first["weight"], from: first["unit"].text, to: first["unit"].text)
            var movement = exercise; movement["unit"] = first["unit"]
            return "上次 " + loadText(movement, row).replacingOccurrences(of: " 次", with: "")
        }()
        return HStack {
            Text(exercise["name"].text.isEmpty ? plan["exercise_id"].text : exercise["name"].text).font(.body).lineLimit(1)
            Spacer(minLength: 8)
            Text(detail).font(.footnote).foregroundStyle(.secondary).monospacedDigit()
        }.frame(minHeight: 46).overlay(alignment: .top) { Divider() }
    }

    // MARK: Posture and groups
    private var postureRow: some View {
        let today = store.home["days"].array.first { $0["date"] == store.home["date"] } ?? .null
        let done = today["posture"].flag
        let posture = groups.first { $0.letter == "体态" }
        return Button {
            if !done { store.homeAction(["template_id": "posture-daily"]) }
        } label: {
            HStack(spacing: 12) {
                Circle().fill(done ? pine : pineTrack).frame(width: 14, height: 14).frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text("每日体态").font(.body).foregroundStyle(.primary)
                    Text(done ? "今天已做" : (today["posture_planned"].flag ? "今天待完成 · 5–8 分钟" : "5–8 分钟")).font(.footnote).foregroundStyle(.secondary)
                }
                Spacer()
                if done { Image(systemName: "checkmark").foregroundStyle(pine).font(.subheadline.weight(.semibold)) }
                else { Text("开始").font(.subheadline.weight(.semibold)).foregroundStyle(pine) }
            }.padding(.horizontal, 16).frame(minHeight: 60).contentShape(Rectangle())
        }.buttonStyle(PinePressStyle()).background(pineSurface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .contextMenu { if let posture { NavigationLink("体态练习模板") { NativeRoutineGroupView(title: posture.title, records: posture.records) } } }
    }
    private func lastDone(_ group: RoutineGroup) -> String {
        let ids = Set(group.records.map { $0["template"].id })
        guard let latest = store.completedRecords.first(where: { ids.contains($0.session["template_id"].text) }), let start = NativeDate.parse(latest.session["started_at"]) else { return group.subtitle }
        return NativeDate.label(start, format: "M月d日", timezone: TimeZone.current.identifier) + " 已练"
    }
    private func groupRow(_ group: RoutineGroup) -> some View {
        let current = group.letter == currentLetter
        return HStack(spacing: 12) {
            Text(group.letter).font(.subheadline.weight(.bold)).foregroundStyle(current ? .white : pine)
                .frame(width: 32, height: 32).background(current ? pine : pineTint, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(group.title + (group.optional ? " · 可选" : "")).font(.body).foregroundStyle(.primary)
                Text(current ? "下一次" : lastDone(group)).font(.footnote).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
        }.padding(.horizontal, 16).frame(minHeight: 60).contentShape(Rectangle())
    }
    private func plainRow(_ title: String) -> some View {
        HStack { Text(title).foregroundStyle(.primary); Spacer(); Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary) }
            .padding(.horizontal, 16).frame(minHeight: 50).contentShape(Rectangle())
    }
    private func continueCard(_ active: NativeRecord) -> some View {
        Button { store.workoutPresented = true } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("进行中").font(.footnote).foregroundStyle(.white.opacity(0.8))
                    Text(active.session["title"].text.components(separatedBy: "｜").last ?? "").font(.headline).foregroundStyle(.white)
                    Text("已完成 \(NativeTraining.progress(active.session).done) 组").font(.footnote).foregroundStyle(.white.opacity(0.8))
                }
                Spacer()
                Text("继续").font(.headline).foregroundStyle(pine).padding(.horizontal, 18).frame(minHeight: 44).background(.white, in: Capsule())
            }.padding(16).background(pine, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }.buttonStyle(PinePressStyle())
    }
    private var weeklyMuscles: some View {
        let counts = store.weeklyMuscleCounts.reduce(into: [String: Int]()) { result, entry in result[muscleName(entry.key), default: 0] += entry.value }
        return VStack(spacing: 8) {
            if counts.isEmpty { Text("完成训练后，这里显示本周实际工作组。").font(.subheadline).foregroundStyle(.secondary).padding(.top, 10) }
            ForEach(counts.keys.sorted(), id: \.self) { PineRow(label: $0, value: "\(counts[$0] ?? 0) 组") }
        }
    }
}
struct NativeRoutineDisclosureStyle: DisclosureGroupStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) { configuration.isExpanded.toggle() } } label: {
                HStack(spacing: 8) { configuration.label; Image(systemName: "chevron.down").font(.caption.weight(.semibold)).foregroundStyle(.secondary).rotationEffect(.degrees(configuration.isExpanded ? 180 : 0)) }.frame(minHeight: 52).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityValue(configuration.isExpanded ? "已展开" : "已收起")
            if configuration.isExpanded { configuration.content }
        }
    }
}
struct NativeRoutineTemplateRow: View {
    let record: JSONValue
    var body: some View {
        NavigationLink { NativeTemplateDetail(record: record) } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(record["template"]["name"].text).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                    Text("\(record["template"]["exercises"].array.count) 个动作 · \(record["template"]["exercises"].array.reduce(0) { $0 + $1["set_count"].integer - $1["warmup_count"].integer }) 工作组").font(.caption).foregroundStyle(.secondary)
                }; Spacer(minLength: 4); Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }.frame(minHeight: 64).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

func muscleName(_ id: String) -> String {
    ["trapezius":"斜方肌", "deltoids":"肩部", "serratus":"前锯肌", "forearm":"前臂", "obliques":"腹斜肌", "gluteal":"臀部", "quadriceps":"股四头肌", "hamstring":"腘绳肌", "hip-flexors":"髋屈肌", "tibialis":"胫骨前肌", "chest":"胸部", "upper-back":"上背", "lats":"背阔肌", "front-delts":"三角肌前束", "side-delts":"三角肌中束", "rear-delts":"三角肌后束", "biceps":"肱二头肌", "triceps":"肱三头肌", "quads":"股四头肌", "hamstrings":"腘绳肌", "glutes":"臀部", "calves":"小腿", "abs":"腹部", "core":"核心", "forearms":"前臂", "lower-back":"下背", "adductors":"内收肌"][id] ?? id
}
struct NativeConflictView: View {
    @Environment(NativeStore.self) var store
    let record: NativeRecord
    @State private var confirmingDiscard = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("同步需要处理", systemImage: "exclamationmark.arrow.triangle.2.circlepath").font(.headline)
            Text(record.session["title"].text).font(.subheadline.bold())
            Text(record.blocked ?? "").font(.footnote).foregroundStyle(.secondary)
            if record.server != nil {
                Text("选择继续使用的版本，另一份记录会作为本机副本保留。").font(.footnote).foregroundStyle(.secondary)
                HStack { Button("使用服务器版本") { store.resolve(record.id, useLocal: false) }; Spacer(); Button("使用本机版本") { store.resolve(record.id, useLocal: true) } }
            } else {
                Button("重新同步") { store.update(record.id) { _ in }; store.retrySync() }
                if record.session["status"].text == "active" { Button("结束这份草稿", role: .destructive) { confirmingDiscard = true } }
            }
        }.pineCard().confirmationDialog("结束并放弃这份草稿？", isPresented: $confirmingDiscard, titleVisibility: .visible) {
            Button("放弃草稿", role: .destructive) { store.finish(record.id, discard: true) }
        }
    }
}

struct NativeTemplateLibrary: View {
    @Environment(NativeStore.self) var store
    @State private var query = ""
    @State private var category = "全部"
    private var rows: [JSONValue] {
        store.templates.filter { record in
            let t = record["template"]; let text = t["name"].text + " " + t["description"].text + " " + t["exercises"].array.map { plan in store.exercises.first { $0.id == plan["exercise_id"].text }?["name"].text ?? "" }.joined(separator: " ")
            return (category == "全部" || templateCategory(t) == category) && (query.isEmpty || text.localizedCaseInsensitiveContains(query))
        }
    }
    var body: some View {
        List {
            Picker("位置", selection: $category) { ForEach(["全部","公司","居家","周末","体态","其他"], id: \.self) { Text($0).tag($0) } }.pickerStyle(.menu)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, record in
                NavigationLink { NativeTemplateDetail(record: record) } label: {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(record["template"]["name"].text).font(.headline)
                        Text("\(record["template"]["exercises"].array.count) 个动作 · \(record["template"]["exercises"].array.reduce(0) { $0 + $1["set_count"].integer - $1["warmup_count"].integer }) 工作组 · " + templateCategory(record["template"])).font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 6)
                }
            }
            if rows.isEmpty { PineEmpty(title: "没有匹配的模板", symbol: "rectangle.stack") }
        }.navigationTitle("训练模板").searchable(text: $query, prompt: "搜索模板、动作")
    }
}
func templateCategory(_ t: JSONValue) -> String {
    if t.id.hasPrefix("posture-") { return "体态" }
    if !t["rotation_order"].isNull || t.id.hasPrefix("personal-company-") { return "公司" }
    if t.id.hasPrefix("personal-home-") { return "居家" }
    if t.id.hasPrefix("personal-weekend-") { return "周末" }; return "其他"
}
struct NativeTemplateDetail: View {
    @Environment(NativeStore.self) var store
    let record: JSONValue
    @State private var editing = false
    var body: some View {
        let t = store.templates.first { $0["template"].id == record["template"].id } ?? record
        PinePage {
            PineHeading(title: t["template"]["name"].text, subtitle: t["template"]["description"].text)
            NativeMuscleMap(primary: Array(Set(t["template"]["exercises"].array.flatMap { plan in store.exercises.first { $0.id == plan["exercise_id"].text }?["primary_muscles"].array.map(\.text) ?? [] }))).pineCard()
            if !t["template"]["notes"].text.isEmpty { Text(t["template"]["notes"].text).font(.subheadline).foregroundStyle(.secondary) }
            ForEach(Array(t["template"]["exercises"].array.enumerated()), id: \.offset) { i, plan in
                let ex = store.exercises.first { $0.id == plan["exercise_id"].text } ?? .null
                VStack(alignment: .leading, spacing: 9) {
                    Text("\(i + 1). " + ex["name"].text).font(.headline)
                    Text("\(plan["set_count"].integer) 组" + (plan["warmup_count"].integer > 0 ? " · 热身 \(plan["warmup_count"].integer) 组" : "") + " · 休息 \(plan["rest_seconds"].integer) 秒").font(.subheadline).foregroundStyle(.secondary)
                    if !plan["target_seconds"].isNull { Text("每组 \(plan["target_seconds"].integer) 秒").font(.subheadline) }
                    if !plan["set_targets"].array.isEmpty { Text(plan["set_targets"].array.map { displayNumber($0["weight"]) + " " + plan["unit"].text + " × \($0["reps"].integer)" }.joined(separator: " / ")).font(.footnote) }
                    if plan["progression"].text == "double" { Label("双重进阶 · \(plan["rep_min"].integer)–\(plan["rep_max"].integer) 次", systemImage: "chart.line.uptrend.xyaxis").font(.caption).foregroundStyle(pine) }
                }.pineCard()
            }
            Button { store.start(template: t["template"]) } label: { Label(store.active == nil ? "开始训练" : "继续进行中的训练", systemImage: "play.fill").frame(maxWidth: .infinity).padding(.vertical, 8) }.buttonStyle(.borderedProminent)
        }.navigationTitle("训练安排").navigationBarTitleDisplayMode(.inline).toolbar { ToolbarItem(placement: .topBarTrailing) { Button("编辑") { editing = true } } }
            .sheet(isPresented: $editing) { NavigationStack { NativeTemplateEditor(record: t) } }
    }
}

struct NativeTemplateEditor: View {
    @Environment(NativeStore.self) var store
    @Environment(\.dismiss) private var dismiss
    let record: JSONValue
    @State private var draft: JSONValue = .null
    @State private var error: String?
    @State private var busy = false
    @State private var adding = false
    @State private var discard = false
    private var dirty: Bool { draft != record["template"] }
    var body: some View {
        Form {
            Section("模板") { TextField("名称", text: field("name")); TextField("说明", text: field("description"), axis: .vertical); TextField("备注", text: field("notes"), axis: .vertical) }
            ForEach(Array(draft["exercises"].array.enumerated()), id: \.offset) { i, plan in
                let exercise = store.exercises.first { $0.id == plan["exercise_id"].text } ?? .null
                Section(exercise["name"].text) {
                    NativePlanEditor(plan: Binding(get: { draft["exercises"][i] }, set: { draft["exercises"][i] = $0 }), exercise: exercise)
                    HStack { Button("上移", systemImage: "arrow.up") { var rows = draft["exercises"].array; rows.swapAt(i, i - 1); draft["exercises"] = .array(rows) }.disabled(i == 0); Spacer(); Button("移除动作", role: .destructive) { var rows = draft["exercises"].array; rows.remove(at: i); draft["exercises"] = .array(rows) } }
                }
            }
            Button("添加动作", systemImage: "plus") { adding = true }.disabled(draft["exercises"].array.count >= 40)
            if let error { Text(error).foregroundStyle(.red) }
        }.navigationTitle(record["version"].integer == 0 ? "保存为模板" : "编辑模板")
            .onAppear { if draft.isNull { draft = record["template"] } }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { if dirty { discard = true } else { dismiss() } } }
                ToolbarItem(placement: .confirmationAction) { Button(busy ? "保存中" : "保存") { save() }.disabled(busy || draft["name"].text.trimmingCharacters(in: .whitespaces).isEmpty || draft["name"].text.count > 100 || draft["exercises"].array.isEmpty) }
            }.interactiveDismissDisabled(dirty)
            .confirmationDialog("放弃尚未保存的修改？", isPresented: $discard, titleVisibility: .visible) { Button("放弃修改", role: .destructive) { dismiss() } }
            .sheet(isPresented: $adding) { NavigationStack { NativeExerciseLibrary { exercise in
                let timed = NativeTraining.timed(exercise)
                let plan: JSONValue = ["exercise_id": exercise["id"], "set_count": 3, "unit": "lb", "rest_seconds": 90,
                    "target_reps": timed ? .null : 8, "target_seconds": timed ? 30 : .null, "progression": "off", "warmup_count": 0]
                draft["exercises"] = .array(draft["exercises"].array + [plan]); adding = false
            } } }
    }
    private func field(_ key: String) -> Binding<String> { Binding(get: { draft[key].text }, set: { draft[key] = .string($0) }) }
    private func save() { busy = true; Task { do { try await store.saveTemplate(draft, version: record["version"].integer); dismiss() } catch { self.error = error.localizedDescription }; busy = false } }
}
struct NativePlanEditor: View {
    @Binding var plan: JSONValue
    let exercise: JSONValue
    var body: some View {
        Stepper("总组数 \(plan["set_count"].integer)", value: integer("set_count", fallback: 3), in: 1...30)
        Stepper("热身 \(plan["warmup_count"].integer) 组", value: integer("warmup_count", fallback: 0), in: 0...min(10, max(0, plan["set_count"].integer - 1)))
        HStack { Text("休息 / 秒"); Spacer(); NativeNumberField(label: "休息秒数", value: plan["rest_seconds"].or(90), maximum: 600) { plan["rest_seconds"] = $0.or(0) }.frame(width: 100) }
        if NativeTraining.timed(exercise) {
            HStack { Text("每组秒数"); Spacer(); NativeNumberField(label: "目标秒数", value: plan["target_seconds"], maximum: 3600, minimum: 1) { plan["target_seconds"] = $0 }.frame(width: 100) }
        } else {
            Picker("重量单位", selection: Binding(get: { plan["unit"].text.isEmpty ? "lb" : plan["unit"].text }, set: { value in
                plan = NativeTraining.changePlan(plan, key: "unit", value: .string(value))
            })) { Text("磅").tag("lb"); Text("公斤").tag("kg") }
            Toggle("逐组预设目标", isOn: Binding(get: { !plan["set_targets"].isNull }, set: { enabled in
                plan["set_targets"] = enabled ? .array((0..<max(1,plan["set_count"].integer)).map { _ in ["weight": nil, "reps": plan["target_reps"].or(8)] }) : .null
                if enabled { plan["warmup_count"] = plan["warmup_count"].or(0) }; touchTargets()
            }))
            ForEach(Array(plan["set_targets"].array.enumerated()), id: \.offset) { i, target in
                HStack { Text(i < plan["warmup_count"].integer ? "热身 \(i + 1)" : "第 \(i + 1 - plan["warmup_count"].integer) 组").font(.caption).frame(width: 62, alignment: .leading)
                    if exercise["load_mode"].text != "bodyweight" { NativeNumberField(label: "目标重量", value: target["weight"], decimal: true) { plan["set_targets"][i]["weight"] = $0; touchTargets() } }
                    NativeNumberField(label: "目标次数", value: target["reps"], maximum: 1000, minimum: 1) { plan["set_targets"][i]["reps"] = $0; touchTargets() }
                }
            }
            HStack { Text("默认次数"); Spacer(); NativeNumberField(label: "默认次数", value: plan["target_reps"], maximum: 1000, minimum: 1) { plan = NativeTraining.changePlan(plan, key: "target_reps", value: $0) }.frame(width: 100) }
            if !NativeTraining.mobility(exercise) {
                Toggle("双重进阶", isOn: Binding(get: { plan["progression"].text == "double" }, set: { plan["progression"] = $0 ? "double" : "off" }))
                if plan["progression"].text == "double" {
                    Stepper("次数下限 \(max(1,plan["rep_min"].integer))", value: integer("rep_min", fallback: 8), in: 1...100)
                    Stepper("次数上限 \(max(1,plan["rep_max"].integer))", value: integer("rep_max", fallback: 12), in: max(1,plan["rep_min"].integer)...100)
                    HStack { Text("加重步长"); Spacer(); NativeNumberField(label: "加重步长", value: plan["increment"], maximum: 100, decimal: true, minimum: 0.01) { plan["increment"] = $0 }.frame(width: 100) }
                }
            }
        }
    }
    private func integer(_ key: String, fallback: Int) -> Binding<Int> { Binding(get: { plan[key].isNull ? fallback : plan[key].integer }, set: { value in
        plan = NativeTraining.changePlan(plan, key: key, value: .number(Double(value)))
        if key == "set_count", plan["warmup_count"].integer >= value { plan["warmup_count"] = .number(Double(value - 1)) }
        if key == "rep_min", plan["rep_max"].integer < value { plan["rep_max"] = .number(Double(value)) }
    }) }
    private func touchTargets() { plan["targets_updated_at"] = plan["set_targets"].isNull ? .null : NativeDate.stamp() }
}

/// One rotation group's templates as a plain list.
struct NativeRoutineGroupView: View {
    let title: String
    let records: [JSONValue]
    var body: some View {
        PinePage {
            VStack(spacing: 0) {
                ForEach(Array(records.enumerated()), id: \.offset) { index, row in
                    if index > 0 { Divider() }
                    NativeRoutineTemplateRow(record: row)
                }
            }.pineCard()
        }.navigationTitle(title).navigationBarTitleDisplayMode(.inline)
    }
}

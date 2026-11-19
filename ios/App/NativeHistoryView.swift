import SwiftUI
import Charts

private struct NativeTimelineRevision: Hashable { let history: Int; let archive: Int }
struct NativeHistoryView: View {
    @Environment(NativeStore.self) var store
    @State private var query = ""
    @State private var kind = "all"
    @State private var month = ""
    @State private var limit = 30
    @State private var archive: JSONValue = .null
    @State private var failed = false
    @State private var rows: [NativeTimelineItem] = []
    @State private var archiveRevision = 0
    @AppStorage("pine.records.calendar") private var calendarMode = false
    var body: some View {
        PinePage {
            PineTabHeader(title: "运动记录")
            Picker("显示方式", selection: $calendarMode) { Text("列表").tag(false); Text("日历").tag(true) }
                .pickerStyle(.segmented).accessibilityIdentifier("records-mode")
            if calendarMode { NativeMonthCalendar() } else { listBody }
        }
        .navigationTitle("运动记录")
        .refreshable { await store.refresh(); await loadArchive() }
        .onChange(of: kind) { _, _ in limit = 30 }.onChange(of: query) { _, _ in limit = 30 }.onChange(of: month) { _, _ in limit = 30 }
        .task { await loadArchive() }
        .task(id: NativeTimelineRevision(history: store.historyRevision, archive: archiveRevision)) {
            let records = store.completedRecords, source = archive, imported = store.imported.array
            let prepared = await Task.detached(priority: .userInitiated) { NativeTimeline.items(records: records, archive: source, imported: imported) }.value
            guard !Task.isCancelled else { return }; rows = prepared
        }
    }
    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("搜索动作或训练名称", text: $query).textInputAutocapitalization(.never).autocorrectionDisabled().submitLabel(.search)
            if !query.isEmpty { Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }.accessibilityLabel("清除搜索") }
        }.padding(.horizontal, 12).frame(height: 40).background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
    @ViewBuilder private var listBody: some View {
        let filtered = NativeTimeline.filter(rows, kind: kind, query: query, month: month)
        let visible = Array(filtered.prefix(limit))
        let grouped = Dictionary(grouping: visible, by: \.date)
        let dates = grouped.keys.sorted(by: >)
        VStack(alignment: .leading, spacing: 16) {
            searchField
            Picker("记录类型", selection: $kind) { Text("全部").tag("all"); Text("力量").tag("strength"); Text("体态").tag("posture"); Text("散步").tag("walk") }.pickerStyle(.segmented).accessibilityIdentifier("record-kind")
            HStack {
                Menu {
                    Button("全部月份") { month = "" }
                    ForEach(Array(Set(rows.map { String($0.date.prefix(7)) })).filter { !$0.isEmpty }.sorted(by: >), id: \.self) { value in Button(value.replacingOccurrences(of: "-", with: "年") + "月") { month = value } }
                } label: { Label(month.isEmpty ? "按月份查找" : month, systemImage: "calendar").font(.subheadline).frame(minHeight: 44) }
                Spacer()
                if !month.isEmpty { Button("清除") { month = "" }.font(.subheadline).frame(minHeight: 44) }
            }
            if failed || store.message != nil { HStack { Text("部分记录暂未更新。").font(.footnote).foregroundStyle(.secondary); Spacer(); Button("重试") { Task { await store.refresh(); await loadArchive() } }.font(.footnote).frame(minHeight: 44) } }
            if filtered.isEmpty { PineEmpty(title: rows.isEmpty ? "还没有运动记录" : "没有匹配的记录", symbol: "list.bullet.clipboard", detail: rows.isEmpty ? "完成训练后，实际记录会显示在这里。" : "试试其他类型、月份或搜索词。"); if !rows.isEmpty { Button("清除筛选") { kind = "all"; query = ""; month = "" } } }
            ForEach(dates, id: \.self) { date in
                VStack(alignment: .leading, spacing: 0) {
                    Text(date == store.home["date"].text ? "今天" : dayTitle(date, format: "M月d日 EEE")).font(.headline).padding(.bottom, 4)
                    let items = grouped[date] ?? []
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, row in
                        if index > 0 { Divider() }
                        NavigationLink { if row.source == "app" { NativeReportView(id: row.id) } else { NativeArchivedDetail(item: row) } } label: { NativeRecordRow(item: row) }.buttonStyle(.plain)
                    }
                }.pineCard()
            }
            if filtered.count > limit { Button("显示更早记录") { limit += 30 }.buttonStyle(.bordered).frame(maxWidth: .infinity).frame(minHeight: 44) }
        }
    }
    private func updateArchive(_ value: JSONValue) {
        guard archive != value else { return }; archive = value; archiveRevision += 1
    }
    private func loadArchive() async {
        if store.isDesignPreview { updateArchive(store.designPreviewArchive); return }
        do { let value = try await store.api.request("/workouts/archive"); updateArchive(value); failed = false }
        catch { if !Task.isCancelled { failed = true; if (error as? HealthAPIError)?.status == 401 { store.handle(error) } } }
    }
}
struct NativeRecordRow: View {
    let item: NativeTimelineItem
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(item.time.isEmpty ? "—" : item.time).font(.subheadline).monospacedDigit().foregroundStyle(.secondary).frame(width: 44, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                Text(focus).font(.body).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
                Text(([group] + [item.detail]).filter { !$0.isEmpty }.joined(separator: " · ")).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if item.pending { Label("本机已保存 · 待同步", systemImage: "arrow.triangle.2.circlepath").font(.caption).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
        }.padding(.vertical, 12).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle()).accessibilityElement(children: .combine)
    }
    /// "E · 家庭｜腹部·小腿" reads as the focus, with group and place as detail.
    private var focus: String { let parts = item.title.components(separatedBy: "｜"); return parts.count > 1 ? parts[1] : item.title }
    private var group: String { let parts = item.title.components(separatedBy: "｜"); return parts.count > 1 ? parts[0] : "" }
}
struct NativeArchivedDetail: View {
    let item: NativeTimelineItem
    var body: some View {
        PinePage {
            PineHeading(title: item.title, subtitle: dayTitle(item.date) + " · " + item.time)
            Text(item.detail).font(.title3.bold())
            if item.source == "archive" {
                ForEach(Array(item.document["movements"].array.enumerated()), id: \.offset) { _, m in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(m["name"].text).font(.headline)
                        ForEach(Array(m["sets"].array.enumerated()), id: \.offset) { i, row in PineRow(label: row["warmup"].flag ? "热身" : "第 \(i + 1) 组", value: (row["selfWeight"].flag ? "自重" : displayNumber(row["weight"]) + " " + (row["unit"].text == "kg" ? "公斤" : "磅")) + " × " + displayNumber(row["reps"], digits: 0) + " 次") }
                    }.pineCard()
                }
            }
            Text(item.source == "archive" ? "来源：训记历史档案" : "来源：Google Health 活动档案，时长按设备记录显示。").font(.footnote).foregroundStyle(.secondary)
        }.navigationTitle("运动详情").navigationBarTitleDisplayMode(.inline)
    }
}

struct NativeReportView: View {
    @Environment(NativeStore.self) var store
    @Environment(\.dismiss) private var dismiss
    let id: String
    @State private var physiology: JSONValue = .null
    @State private var review: JSONValue = .null
    @State private var error: String?
    @State private var deleting = false
    @State private var busy = false
    @State private var correcting = false
    @State private var template: JSONValue = .null
    @State private var templateSheet = false
    @State private var clearAlternative = false
    @State private var attempt = 0
    private var record: NativeRecord? { store.recordDocuments[id] }
    private var session: JSONValue { record?.session ?? .null }
    private var saved: Bool { record.map { !$0.dirty && $0.blocked == nil && $0.version > 0 } ?? false }
    var body: some View {
        PinePage {
            if let record {
                reportHeader
                dayContribution
                Label(record.blocked != nil ? "同步需要处理" : record.dirty ? "本机已保存 · 待同步" : "已保存到服务器", systemImage: record.dirty ? "arrow.triangle.2.circlepath" : "checkmark.icloud").font(.caption).foregroundStyle(.secondary)
                if record.blocked != nil { NativeConflictView(record: record) }
                if let error { PineBanner(text: error) }
                reviewCard
                NativeMuscleMap(primary: Array(Set(session["exercises"].array.filter { !NativeTraining.done($0).filter { !$0["warmup"].flag }.isEmpty && !NativeTraining.mobility($0) }.flatMap { $0["primary_muscles"].array.map(\.text) }))).pineCard()
                if saved { physiologyCard }
                ForEach(Array(session["exercises"].array.enumerated()), id: \.element.id) { i, movement in movementReport(movement, index: i) }
                if !session["notes"].text.isEmpty { VStack(alignment: .leading, spacing: 10) { Text("训练笔记").font(.headline); Text(session["notes"].text).font(.subheadline) }.pineCard() }
                VStack(spacing: 0) {
                    Button { repeatSession() } label: { Text("再练一次").frame(maxWidth: .infinity, minHeight: 50, alignment: .leading).padding(.leading, 16).contentShape(Rectangle()) }.disabled(store.active != nil)
                    Divider().padding(.leading, 16)
                    Button { template = makeTemplate(); templateSheet = true } label: { Text("存为模板").frame(maxWidth: .infinity, minHeight: 50, alignment: .leading).padding(.leading, 16).contentShape(Rectangle()) }.disabled(session["exercises"].array.isEmpty)
                    Divider().padding(.leading, 16)
                    Button(role: .destructive) { deleting = true } label: { Text("删除这条记录").frame(maxWidth: .infinity, minHeight: 50, alignment: .leading).padding(.leading, 16).contentShape(Rectangle()) }.disabled(!saved || busy)
                }.background(pineSurface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                if let alternative = record.alternative {
                    DisclosureGroup("保留的冲突副本") {
                        Text(alternative["title"].text).font(.headline)
                        ForEach(Array(alternative["exercises"].array.enumerated()), id: \.offset) { _, m in Text(m["name"].text + "：" + NativeTraining.done(m).map { loadText(m, $0) }.joined(separator: " / ")).font(.caption) }
                        ShareLink("导出副本", item: String(data: (try? alternative.data()) ?? Data(), encoding: .utf8) ?? "")
                        Button("清除这份副本", role: .destructive) { clearAlternative = true }
                    }.pineCard()
                }
            } else { PineEmpty(title: "训练记录已删除", symbol: "trash") }
        }.navigationTitle("").navigationBarTitleDisplayMode(.inline)
            .toolbar { if record != nil { ToolbarItem(placement: .topBarTrailing) { Button("更正记录") { correcting = true }.disabled(record?.blocked != nil) } } }
            .sheet(isPresented: $correcting) { NavigationStack { NativeRecordCorrection(original: session) } }
            .sheet(isPresented: $templateSheet) { NavigationStack { NativeTemplateEditor(record: ["template": template, "version": 0]) } }
            .confirmationDialog("删除这场训练？", isPresented: $deleting, titleVisibility: .visible) { Button("删除训练", role: .destructive) { busy = true; Task { do { try await store.delete(id); dismiss() } catch { self.error = error.localizedDescription }; busy = false } } } message: { Text("将删除服务器上的训练记录、心率报告和关联分析。") }
            .confirmationDialog("清除保留的冲突副本？", isPresented: $clearAlternative, titleVisibility: .visible) { Button("清除副本", role: .destructive) { store.clearAlternative(id) } }
            .task(id: "\(record?.version ?? 0)-\(saved)-\(attempt)") { await loadReports() }
    }
    /// Title split at the "｜" the templates use: focus as title, group and place below.
    private var reportHeader: some View {
        let title = session["title"].text
        let parts = title.components(separatedBy: "｜")
        let focus = parts.count > 1 ? parts[1] : title
        let group = parts.count > 1 ? parts[0].replacingOccurrences(of: " · ", with: " 组 · ") : ""
        let p = NativeTraining.progress(session)
        let start = NativeDate.parse(session["started_at"]), end = NativeDate.parse(session["ended_at"])
        let seconds = max(0, (end?.timeIntervalSince(start ?? .now) ?? 0) - (session["paused_seconds"].number ?? 0))
        let when = start.map { NativeDate.label($0, format: "M月d日 HH:mm", timezone: session["timezone"].text.isEmpty ? TimeZone.current.identifier : session["timezone"].text) } ?? ""
        return VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(focus).font(.largeTitle.weight(.semibold))
                Text([group, when].filter { !$0.isEmpty }.joined(separator: " · ")).font(.subheadline).foregroundStyle(.secondary)
            }
            HStack(alignment: .top) {
                reportStat("时长", "\(Int((seconds / 60).rounded()))", "分钟")
                reportStat("完成", "\(p.done)", "/ \(p.planned) 组")
                reportStat("动作", "\(session["exercises"].array.count)", "个")
            }
            if p.done == 0 { Text("本次没有完成的工作组，不推断训练表现。").font(.footnote).foregroundStyle(.secondary) }
        }
    }
    private func reportStat(_ title: String, _ value: String, _ unit: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 3) { Text(value).font(.title2.weight(.semibold)).monospacedDigit(); Text(unit).font(.footnote).foregroundStyle(.secondary) }
        }.frame(maxWidth: .infinity, alignment: .leading).accessibilityElement(children: .combine)
    }
    /// How this session filled its day's glyph.
    @ViewBuilder private var dayContribution: some View {
        let zone = session["timezone"].text.isEmpty ? TimeZone.current.identifier : session["timezone"].text
        if session["status"].text == "completed", let start = NativeDate.parse(session["started_at"]) {
            let key = NativeDate.day(start, timezone: zone)
            let list = NativeDays.sessions(records: store.records, timezone: zone)[key] ?? []
            let strength = list.filter { !$0.posture }
            let index = strength.firstIndex { $0.id == id }
            let halves = NativeDays.halves(list)
            let text: String = {
                if list.contains(where: { $0.id == id && $0.posture }) { return "这天的圆点已经填满。" }
                guard let index else { return "" }
                if index >= 2 { return "这是这天的第 \(index + 1) 次力量训练。" }
                let full = halves.count == 2 && halves.allSatisfy { $0 >= 1 }
                return index == 0 ? (full ? "这是这天的第一次力量，中圈已经满了。" : "这是这天的第一次力量，中圈填了一半。") : (full ? "这是这天的第二次力量，中圈已经满了。" : "这是这天的第二次力量。")
            }()
            if !text.isEmpty {
                HStack(spacing: 14) {
                    PineDayGlyph(activity: nil, halves: halves, posture: NativeDays.postureDone(list), size: 52)
                    Text(text).font(.subheadline).frame(maxWidth: .infinity, alignment: .leading)
                }.pineCard()
            }
        }
    }
    private var reportSummary: some View {
        VStack(alignment: .leading, spacing: 12) {
            let p = NativeTraining.progress(session)
            let start = NativeDate.parse(session["started_at"]), end = NativeDate.parse(session["ended_at"])
            let seconds = max(0, (end?.timeIntervalSince(start ?? .now) ?? 0) - (session["paused_seconds"].number ?? 0))
            Text(WorkoutSnapshot.clock(seconds)).font(.system(size: 42, weight: .bold, design: .rounded)).monospacedDigit()
            HStack { Text("\(p.done)/\(p.planned) 工作组"); Spacer(); Text("热身 \(p.warmup) 组") }.font(.subheadline).foregroundStyle(.secondary)
            if p.done == 0 { Text("本次没有完成的工作组，不推断训练表现。").font(.footnote).foregroundStyle(.secondary) }
        }.pineCard()
    }
    private var reviewCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Label(review["status"].text == "ready" ? "AI 复盘" : "本次复盘", systemImage: "sparkles").font(.headline); Spacer(); if review["status"].text == "pending" { ProgressView() } }
            let lines = review["status"].text == "ready" ? review["analysis"] : NativeReview.fallback(session, evidence: review["evidence"])
            ForEach([("today","本次"),("trend","趋势"),("next","下次")], id: \.0) { key, title in
                VStack(alignment: .leading, spacing: 5) { Text(title).font(.caption).foregroundStyle(.secondary); Text(lines[key]["text"].text).font(.subheadline).lineSpacing(4) }
            }
            if review["status"].text == "ready" {
                DisclosureGroup("查看分析依据") { ForEach(Array(review["evidence"]["facts"].array.enumerated()), id: \.offset) { _, fact in Text("• " + fact["text"].text).font(.footnote).padding(.vertical, 3) } }
            } else if saved { Button(review["status"].text == "pending" ? "正在生成复盘…" : "生成 AI 复盘") { Task { await requestReview() } }.disabled(review["status"].text == "pending") }

        }.pineCard()
    }
    private var physiologyCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Label("心率与活动", systemImage: "heart.fill").font(.headline); Spacer(); if physiology["syncing"].flag { ProgressView() } }
            Text(physiologyLabel(physiology["status"].text)).font(.subheadline).foregroundStyle(.secondary)
            let heart = physiology["heart_rate"]
            if heart["sources"].array.count > 1 {
                Picker("心率来源", selection: Binding(get: { heart["selected_source"]["id"].text }, set: { value in Task { do { physiology = try await store.api.request("/strength/sessions/" + id + "/physiology/source", method: "PUT", body: ["source_id": .string(value)]) } catch { reportError(error) } } })) {
                    Text("选择本次佩戴的设备").tag("")
                    ForEach(heart["sources"].array, id: \.id) { source in Text(source["label"].text).tag(source.id) }
                }
            }
            if heart["summary"]["sample_count"].integer > 0 {
                HStack { VStack(alignment: .leading, spacing: 5) { Text("平均心率").font(.caption).foregroundStyle(.secondary); Text(displayNumber(heart["summary"]["mean_bpm"]) + " 次/分").font(.title2.bold()) }; Spacer(); VStack(alignment: .trailing, spacing: 5) { Text("最高心率").font(.caption).foregroundStyle(.secondary); Text(displayNumber(heart["summary"]["max_bpm"]) + " 次/分").font(.title2.bold()) } }
                NativeHeartChart(rows: heart["chart"].array)
                Text("\(heart["summary"]["sample_count"].integer) 个样本 · 缺失分钟留空").font(.caption).foregroundStyle(.secondary)
            }
            PineRow(label: "估算活动热量", value: displayNumber(physiology["metrics"]["active_energy"]["value"]) + " 千卡")
            if ["waiting_sync","partial","unavailable","error"].contains(physiology["status"].text), !heart["fetched_at"].isNull || !physiology["errors"].object.isEmpty { Link("打开 Google Health 同步", destination: URL(string: "https://www.fitbit.com/in-app/today")!).font(.subheadline) }
            Button("重新获取", systemImage: "arrow.clockwise") { Task { do { physiology = try await store.api.request("/strength/sessions/" + id + "/physiology/refresh", method: "POST"); attempt += 1 } catch { reportError(error) } } }.font(.subheadline).disabled(physiology["syncing"].flag || physiology["status"].text == "unsupported")
        }.pineCard()
    }
    private func movementReport(_ m: JSONValue, index: Int) -> some View {
        let done = NativeTraining.done(m)
        return VStack(alignment: .leading, spacing: 12) {
            Text(m["name"].text).font(.headline)
            Text("完成 \(done.filter { !$0["warmup"].flag }.count) 工作组 · 热身 \(done.filter { $0["warmup"].flag }.count) 组").font(.subheadline).foregroundStyle(.secondary)
            if let comparison = comparison(m, index: index) { Text(comparison).font(.subheadline).foregroundStyle(pine) }
            DisclosureGroup("查看每组记录") {
                ForEach(Array(m["sets"].array.enumerated()), id: \.element.id) { si, row in
                    VStack(alignment: .leading, spacing: 4) {
                        PineRow(label: row["warmup"].flag ? "热身" : "第 \(si + 1) 组", value: (row["completed_at"].isNull ? "未完成 · " : "") + loadText(m, row))
                        if !row["hard_reps"].isNull { Text(row["hard_reps"].integer == 0 ? "没有明显吃力" : "最后 \(row["hard_reps"].integer) 次明显吃力").font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }.font(.subheadline)
        }.pineCard()
    }
    private func comparison(_ m: JSONValue, index: Int) -> String? {
        guard !NativeTraining.timed(m), !NativeTraining.mobility(m) else { return nil }
        let prefix = session["exercises"].array.prefix(index).map { $0["exercise_id"].text }
        let scoped = store.history.filter { old in
            if let baseline = NativeDate.parse(m["baseline_at"]), (NativeDate.parse(old["started_at"]) ?? .distantPast) < baseline { return false }
            if !session["template_id"].isNull && old["template_id"] != session["template_id"] { return false }
            guard let i = old["exercises"].array.firstIndex(where: { $0["exercise_id"] == m["exercise_id"] && $0["load_mode"] == m["load_mode"] }) else { return false }
            return old["exercises"].array.prefix(i).map { $0["exercise_id"].text } == prefix
        }
        let previous = NativeTraining.previous(scoped, exercise: m["exercise_id"].text, mode: m["load_mode"].text, before: NativeDate.parse(session["started_at"]) ?? .now, timezone: session["timezone"].text, current: id, allowSameDay: false).filter { !$0["warmup"].flag }
        let done = NativeTraining.done(m).filter { !$0["warmup"].flag }
        guard !done.isEmpty, done.count == previous.count else { return nil }
        guard m["load_mode"].text == "bodyweight" || zip(done, previous).allSatisfy({ current, prior in
            guard let a = current["weight"].number, let b = NativeTraining.convert(prior["weight"], from: prior["unit"].text, to: m["unit"].text).number else { return false }; return abs(a - b) < 0.02
        }) else { return nil }
        let delta = done.reduce(0) { $0 + $1["reps"].integer } - previous.reduce(0) { $0 + $1["reps"].integer }
        return "与上次同组数、同负荷相比，" + (delta == 0 ? "次数持平。" : "\(delta > 0 ? "多" : "少") \(abs(delta)) 次。")
    }
    private func loadReports() async {
        guard saved else { return }
        for index in 0..<36 {
            if Task.isCancelled || !saved { return }
            async let p = store.api.request("/strength/sessions/" + id + "/physiology")
            async let r = store.api.request("/strength/sessions/" + id + "/review")
            do {
                let values = try await (p,r); guard !Task.isCancelled else { return }; physiology = values.0; review = values.1
                if index == 0 && review["status"].text == "idle" { await requestReview() }
                let pendingHeart = ["pending","waiting_sync","partial"].contains(physiology["status"].text) || physiology["syncing"].flag
                if !pendingHeart && review["status"].text != "pending" { return }
            } catch { if !Task.isCancelled { reportError(error) }; return }
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
        }
    }
    private func requestReview() async { do { review = try await store.api.request("/strength/sessions/" + id + "/review", method: "POST") } catch { reportError(error) } }
    private func reportError(_ error: Error) { self.error = error.localizedDescription; if (error as? HealthAPIError)?.status == 401 { store.handle(error) } }
    private func repeatSession() {
        var t = makeTemplate(); t["id"] = session["template_id"]
        for i in t["exercises"].array.indices { t["exercises"][i]["targets_updated_at"] = session["exercises"][i]["baseline_at"] }
        store.start(template: t); dismiss()
    }
    private func makeTemplate() -> JSONValue {
        let plans = session["exercises"].array.map { m -> JSONValue in
            let rows = m["sets"].array.sorted { $0["warmup"].flag && !$1["warmup"].flag }; let count = min(30, rows.count)
            var p: JSONValue = ["exercise_id": m["exercise_id"], "set_count": .number(Double(count)), "unit": m["unit"], "rest_seconds": m["rest_seconds"], "warmup_count": .number(Double(min(count - 1, rows.filter { $0["warmup"].flag }.count))), "progression": "off"]
            if NativeTraining.timed(m) { p["target_seconds"] = rows.last?["duration_seconds"].or(30) ?? 30 }
            else { p["set_targets"] = .array(rows.prefix(count).map { ["weight": $0["weight"], "reps": $0["reps"].or(8)] }); p["targets_updated_at"] = NativeDate.stamp() }; return p
        }
        return ["id": .string("custom-" + UUID().uuidString.lowercased()), "name": session["title"], "notes": session["notes"], "exercises": .array(plans)]
    }
}
func physiologyLabel(_ status: String) -> String {
    ["pending":"正在获取训练数据", "waiting_sync":"等待设备数据同步", "partial":"部分心率数据已到达", "ready":"已获取训练时段数据", "needs_source":"请选择心率来源", "connection_required":"需要检查 Google Health 授权", "error":"云端数据暂时无法获取", "unavailable":"未获取到这段时间的心率", "unsupported":"这场训练的时长不支持自动获取", "not_requested":"尚未获取"][status] ?? "正在准备训练数据"
}
struct NativeHeartChart: View {
    let rows: [JSONValue]
    var body: some View {
        let segments = heartSegments(rows)
        Chart(Array(segments.enumerated()), id: \.offset) { _, point in
            if let date = NativeDate.parse(point["at"]), let bpm = point["mean_bpm"].number {
                LineMark(x: .value("时间", date), y: .value("心率", bpm), series: .value("片段", point["segment"].integer)).foregroundStyle(.pink).symbol(.circle)
            }
        }.chartYScale(domain: .automatic(includesZero: false)).frame(height: 170)
    }
    private func heartSegments(_ rows: [JSONValue]) -> [JSONValue] {
        var segment = 0; var points: [JSONValue] = []
        for row in rows { if row["mean_bpm"].isNull { segment += 1; continue }; var point = row; point["segment"] = .number(Double(segment)); points.append(point) }; return points
    }
}
struct NativeRecordCorrection: View {
    @Environment(NativeStore.self) var store
    @Environment(\.dismiss) private var dismiss
    let original: JSONValue
    @State private var draft: JSONValue = .null
    @State private var error: String?
    @State private var discard = false
    private var dirty: Bool { !draft.isNull && draft != original }
    var body: some View {
        Form {
            TextField("训练名称", text: Binding(get: { draft["title"].text }, set: { draft["title"] = .string($0) }))
            ForEach(Array(draft["exercises"].array.enumerated()), id: \.element.id) { mi, m in
                Section(m["name"].text) {
                    ForEach(Array(m["sets"].array.enumerated()), id: \.element.id) { si, row in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack { Text("第 \(si + 1) 组").font(.caption); if m["load_mode"].text != "bodyweight" { NativeNumberField(label: "重量", value: row["weight"], decimal: true) { draft["exercises"][mi]["sets"][si]["weight"] = $0 } }; NativeNumberField(label: NativeTraining.timed(m) ? "秒数" : "次数", value: row[NativeTraining.timed(m) ? "duration_seconds" : "reps"], maximum: NativeTraining.timed(m) ? 3600 : 1000, minimum: 1) { draft["exercises"][mi]["sets"][si][NativeTraining.timed(m) ? "duration_seconds" : "reps"] = $0 } }
                            Toggle("已完成", isOn: Binding(get: { !draft["exercises"][mi]["sets"][si]["completed_at"].isNull }, set: { draft["exercises"][mi]["sets"][si]["completed_at"] = $0 ? original["ended_at"] : .null }))
                        }
                    }
                }
            }
            TextField("训练笔记", text: Binding(get: { draft["notes"].text }, set: { draft["notes"] = .string($0) }), axis: .vertical)
            if let error { Text(error).foregroundStyle(.red) }
        }.navigationTitle("更正本次记录").onAppear { if draft.isNull { draft = original } }.interactiveDismissDisabled(dirty)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { if dirty { discard = true } else { dismiss() } } }; ToolbarItem(placement: .confirmationAction) { Button("保存") { save() }.disabled(!dirty) } }
            .confirmationDialog("放弃未保存的更正？", isPresented: $discard, titleVisibility: .visible) { Button("放弃修改", role: .destructive) { dismiss() } }
    }
    private func save() {
        guard !draft["title"].text.trimmingCharacters(in: .whitespaces).isEmpty, draft["title"].text.count <= 100, draft["notes"].text.count <= 4000 else { error = "请检查训练名称和笔记长度。"; return }
        for m in draft["exercises"].array { for row in m["sets"].array where !row["completed_at"].isNull { if !NativeTraining.valid(m, row) { error = "请补齐已完成组数值，或取消该组的完成标记。"; return } } }
        store.update(original.id) { $0 = draft }; dismiss()
    }
}
struct NativeArchiveView: View {
    @Environment(NativeStore.self) var store
    @State private var archive: JSONValue = .null
    @State private var error: String?
    var body: some View {
        List {
            if let error { Text(error).foregroundStyle(.secondary) }
            ForEach(Array(archive["training"].or(store.imported).array.enumerated()), id: \.offset) { _, workout in
                DisclosureGroup(workout["datestr"].text + " · " + workout["title"].text) {
                    ForEach(Array(workout["movements"].array.enumerated()), id: \.offset) { _, m in archiveMovement(m) }
                }
            }
            Section("Google Health 历史活动") { ForEach(Array(archive["exercises"].array.enumerated()), id: \.offset) { _, row in VStack(alignment: .leading, spacing: 5) { Text(row["name"].or(row["title"].or(row["type"])).text); Text(row["date"].or(row["start_time"]).text).font(.caption).foregroundStyle(.secondary) } } }
        }.navigationTitle("历史档案").task { do { archive = try await store.api.request("/workouts/archive") } catch { self.error = "暂时无法读取完整档案。" } }
    }
    // Split out so older Swift type checkers (Xcode 26) finish within their time limit.
    private func archiveMovement(_ m: JSONValue) -> some View {
        let rows: [JSONValue] = m["sets"].array.filter { $0["done"].flag }
        return VStack(alignment: .leading, spacing: 5) {
            Text(m["name"].text).font(.headline)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in Text(archiveSetText(row)).font(.subheadline) }
        }
    }
    private func archiveSetText(_ row: JSONValue) -> String {
        let weight: String = displayNumber(row["weight"])
        let reps: String = displayNumber(row["reps"])
        return "\(weight) \(row["unit"].text) × \(reps) 次"
    }
}
struct NativeObservationsView: View {
    @Environment(NativeStore.self) var store
    @State private var busy = false
    @State private var error: String?
    var body: some View {
        List {
            if let error { Text(error).foregroundStyle(.red) }
            Section {
                Menu { Button("早间观察") { generate("/insights/generate/morning") }; Button("晚间观察") { generate("/insights/generate/evening") }; Button("每周观察") { generate("/insights/weekly/generate") } } label: { Label(busy ? "正在生成…" : "生成分析", systemImage: "sparkles") }.disabled(busy)
            }
            ForEach(Array(store.observations.array.enumerated()), id: \.offset) { _, observation in
                NavigationLink { NativeObservationDetail(observation: observation) } label: { VStack(alignment: .leading, spacing: 6) { Text(observation["title"].text).font(.headline); Text(observation["date"].text).font(.caption).foregroundStyle(.secondary); let headline = observation["report"]["findings"][0]["headline"].or(observation["report"]["summary"]); if !headline.text.isEmpty { Text(headline.text).font(.subheadline).lineLimit(2).foregroundStyle(.secondary) } }.padding(.vertical, 5) }
            }
            if store.observations.array.isEmpty { PineEmpty(title: "暂无观察", symbol: "sparkles", detail: "保存的早间、晚间和每周观察都会在这里。") }
        }.navigationTitle("观察").refreshable { await store.refresh() }
    }
    private func generate(_ path: String) { busy = true; error = nil; Task { do { _ = try await store.api.request(path, method: "POST", timeout: 90); await store.refresh() } catch { self.error = error.localizedDescription }; busy = false } }
}
struct NativeObservationDetail: View {
    let observation: JSONValue
    var body: some View {
        PinePage {
            PineHeading(title: observation["title"].text, subtitle: observation["date"].text)
            let report = observation["report"]
            if !report["trend"].array.isEmpty { MetricChart(rows: report["trend"].array, key: "minutes", color: .indigo).pineCard() }
            ForEach(Array(report["findings"].array.enumerated()), id: \.offset) { _, finding in
                VStack(alignment: .leading, spacing: 14) {
                    Text(finding["headline"].text).font(.title3.bold()); Text(finding["body"].text).font(.subheadline).lineSpacing(5)
                    DisclosureGroup("查看依据") {
                        ForEach(Array(finding["evidence"].array.enumerated()), id: \.offset) { _, line in Text("• " + line.text).font(.footnote).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4) }
                        Text("证据强度：" + (["low":"有限","medium":"中等","high":"较充分"][finding["confidence"].text] ?? finding["confidence"].text)).font(.caption).foregroundStyle(.secondary)
                        if !report["limitations"].text.isEmpty { Text(report["limitations"].text).font(.caption).foregroundStyle(.secondary) }
                    }.font(.subheadline)
                }.pineCard()
            }
            if report["findings"].array.isEmpty { Text(report["summary"].text.isEmpty ? observation["content"].text : report["summary"].text).font(.body).lineSpacing(6).pineCard() }
        }.navigationTitle("观察详情").navigationBarTitleDisplayMode(.inline)
    }
}

/// Month grid of day glyphs built from this app's local records; tapping a day
/// shows that day's activity, strength sessions and posture practice.
struct NativeMonthCalendar: View {
    @Environment(NativeStore.self) var store
    @PineReducedMotion private var reduceMotion
    @State private var monthOffset = 0
    @State private var selected = ""
    private var timezone: String { store.home["timezone"].text.isEmpty ? TimeZone.current.identifier : store.home["timezone"].text }
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian); value.timeZone = TimeZone(identifier: timezone) ?? .current; value.firstWeekday = 2; return value
    }
    private var today: String { store.home["date"].text.isEmpty ? NativeDate.day(Date(), timezone: timezone) : store.home["date"].text }
    private struct Cell: Identifiable { let id: String; let key: String; let number: Int }
    var body: some View {
        let cal = calendar
        let current = cal.date(from: cal.dateComponents([.year, .month], from: Date())) ?? Date()
        let shown = cal.date(byAdding: .month, value: monthOffset, to: current) ?? current
        let sessions = NativeDays.sessions(records: store.records, timezone: timezone)
        let count = cal.range(of: .day, in: .month, for: shown)?.count ?? 30
        let lead = (cal.component(.weekday, from: shown) - cal.firstWeekday + 7) % 7
        let cells: [Cell] = (0..<lead).map { Cell(id: "blank-\($0)", key: "", number: 0) } + (0..<count).compactMap { offset -> Cell? in
            guard let date = cal.date(byAdding: .day, value: offset, to: shown) else { return nil }
            let key = NativeDate.day(date, timezone: timezone); return Cell(id: key, key: key, number: offset + 1)
        }
        let focus = selected.isEmpty ? today : selected
        VStack(alignment: .leading, spacing: 16) {
            VStack(spacing: 6) {
                HStack {
                    Button { withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { monthOffset -= 1 } } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44) }.accessibilityLabel("上个月")
                    Spacer()
                    Text(NativeDate.label(shown, format: "yyyy年M月", timezone: timezone)).font(.headline)
                    Spacer()
                    Button { withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { monthOffset += 1 } } label: { Image(systemName: "chevron.right").frame(width: 44, height: 44) }.disabled(monthOffset >= 0).accessibilityLabel("下个月")
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 2) {
                    ForEach(["一","二","三","四","五","六","日"], id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary).frame(height: 20) }
                    ForEach(cells) { cell in cellView(cell, sessions[cell.key] ?? [], focus: focus) }
                }
            }.padding(.horizontal, 8).padding(.vertical, 8).background(pineSurface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            Text("外圈活动 · 中圈两次力量 · 圆点体态").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 4)
            dayDetail(focus, sessions[focus] ?? [])
        }
    }
    @ViewBuilder private func cellView(_ cell: Cell, _ list: [NativeDaySession], focus: String) -> some View {
        if cell.key.isEmpty { Color.clear.frame(height: 56) }
        else {
            let future = cell.key > today
            let chosen = cell.key == focus
            let numberColor: Color = chosen ? pine : (future ? .secondary : .primary)
            Button { selected = cell.key } label: {
                VStack(spacing: 2) {
                    Text("\(cell.number)").font(.caption.weight(chosen ? .bold : .regular)).monospacedDigit().foregroundStyle(numberColor)
                    PineDayGlyph(activity: activity(cell.key), halves: NativeDays.halves(list), posture: posture(cell.key, list), future: future, size: 34)
                }
                .frame(maxWidth: .infinity, minHeight: 56)
                .background(chosen ? pineTint : Color.clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(PinePressStyle(scale: 0.97))
            .accessibilityLabel(accessibility(cell.key, list, future: future))
            .accessibilityAddTraits(chosen ? .isSelected : [])
        }
    }
    /// Current week: the server's daily activity (training windows excluded).
    /// Earlier days: Google's total active calories, so a training day can read fuller.
    private func activity(_ key: String) -> Double? {
        guard let goal = store.home["goals"]["dailyActivity"].number, goal > 0 else { return nil }
        if let row = store.home["days"].array.first(where: { $0["date"].text == key }) { return row["activity"].number.map { $0 / goal } }
        return store.home["metrics"].array.first { $0["date"].text == key }?["calories_burned"].number.map { $0 / goal }
    }
    private func posture(_ key: String, _ list: [NativeDaySession]) -> Bool {
        NativeDays.postureDone(list) || store.home["days"].array.contains { $0["date"].text == key && $0["posture"].flag }
    }
    private func accessibility(_ key: String, _ list: [NativeDaySession], future: Bool) -> String {
        let title = dayTitle(key, format: "M月d日")
        if future { return title + "，未来日期" }
        let strength = list.filter { !$0.posture }.count
        return title + "，活动 " + (activity(key).map { "\(Int(($0 * 100).rounded()))%" } ?? "无数据") + "，力量 \(strength) 次，体态" + (posture(key, list) ? "已做" : "未做")
    }
    private func dayDetail(_ key: String, _ list: [NativeDaySession]) -> some View {
        let strength = list.filter { !$0.posture }, practice = list.filter(\.posture)
        let inWeek = store.home["days"].array.first { $0["date"].text == key }
        let kcal = inWeek?["activity"] ?? store.home["metrics"].array.first { $0["date"].text == key }?["calories_burned"] ?? .null
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                PineDayGlyph(activity: activity(key), halves: NativeDays.halves(list), posture: posture(key, list), future: key > today, size: 60)
                VStack(alignment: .leading, spacing: 3) {
                    Text(dayTitle(key, format: "M月d日 EEE")).font(.headline)
                    Text("活动 " + displayNumber(kcal, digits: 0) + " 千卡" + (inWeek == nil && !kcal.isNull ? "（含训练）" : "")).font(.footnote).foregroundStyle(.secondary)
                    Text(strength.isEmpty ? "力量 没有记录" : "力量 \(strength.count) 次").font(.footnote).foregroundStyle(.secondary)
                    Text(practice.isEmpty ? "体态 没有记录" : "体态 已做").font(.footnote).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            if !list.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(list.enumerated()), id: \.element.id) { index, session in
                        if index > 0 { Divider() }
                        NavigationLink { NativeReportView(id: session.id) } label: {
                            HStack(spacing: 10) {
                                Text(session.start.map { NativeDate.label($0, format: "HH:mm", timezone: timezone) } ?? "—").font(.subheadline).monospacedDigit().foregroundStyle(.secondary).frame(width: 44, alignment: .leading)
                                Text(session.title).font(.subheadline).foregroundStyle(.primary).lineLimit(1)
                                Spacer(minLength: 4)
                                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                            }.frame(minHeight: 44).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }
            }
        }.pineCard()
    }
}

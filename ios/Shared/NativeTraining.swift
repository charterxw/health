import Foundation

public enum TrainingError: LocalizedError {
    case invalid(String)
    public var errorDescription: String? { if case .invalid(let text) = self { return text }; return nil }
}

public enum NativeTraining {
    public static func uid() -> JSONValue { .string(UUID().uuidString.lowercased()) }
    public static func timed(_ m: JSONValue) -> Bool { m["tracking"].text == "duration" }
    public static func mobility(_ m: JSONValue) -> Bool { m["training_type"].text == "mobility" || m["exercise_id"].text.hasPrefix("posture-") }
    public static func valid(_ m: JSONValue, _ row: JSONValue) -> Bool {
        let value = row[timed(m) ? "duration_seconds" : "reps"].number
        guard let value, value.isFinite, value >= 1, value.rounded() == value, value <= (timed(m) ? 3600 : 1000) else { return false }
        if timed(m) || m["load_mode"].text == "bodyweight" { return true }
        guard let weight = row["weight"].number else { return false }
        return weight.isFinite && (0...2000).contains(weight)
    }
    public static func done(_ m: JSONValue) -> [JSONValue] { m["sets"].array.filter { !$0["completed_at"].isNull && valid(m, $0) } }
    public static func progress(_ s: JSONValue) -> (done: Int, planned: Int, warmup: Int) {
        let movements = s["exercises"].array
        let posture = !movements.isEmpty && movements.allSatisfy(mobility)
        let counted = posture ? movements : movements.filter { !mobility($0) }
        return (counted.reduce(0) { $0 + done($1).filter { !$0["warmup"].flag }.count },
                counted.reduce(0) { $0 + $1["sets"].array.filter { !$0["warmup"].flag }.count },
                movements.reduce(0) { $0 + done($1).filter { $0["warmup"].flag }.count })
    }
    public static func convert(_ value: JSONValue, from: String, to: String) -> JSONValue {
        guard let weight = value.number else { return .null }
        let next = from == to ? weight : from == "lb" ? weight * 0.45359237 : weight / 0.45359237
        return .number((next * 100).rounded() / 100)
    }
    public static func previous(_ history: [JSONValue], exercise: String, mode: String, before: Date, timezone: String,
                                current: String = "", allowSameDay: Bool = true) -> [JSONValue] {
        for s in history.sorted(by: { $0["started_at"].text > $1["started_at"].text }) {
            guard s.id != current, s["status"].text == "completed" else { continue }
            if let end = NativeDate.parse(s["ended_at"]), end > before { continue }
            let date = s["started_at"].text
            if date.count == 10 {
                let day = NativeDate.day(before, timezone: timezone)
                if allowSameDay ? date > day : date >= day { continue }
            } else if let start = NativeDate.parse(date), start < before { } else { continue }
            let rows = s["exercises"].array.filter { $0["exercise_id"].text == exercise && $0["load_mode"].text == mode }.flatMap { movement in
                done(movement).map { row -> JSONValue in var r = row; r["unit"] = movement["unit"]; r["date"] = s["started_at"]; return r }
            }
            if !rows.isEmpty { return rows }
        }
        return []
    }
    public static func changePlan(_ plan: JSONValue, key: String, value: JSONValue, at now: Date = Date()) -> JSONValue {
        var next = plan; next[key] = value
        if key == "unit", !plan["increment"].isNull { next["increment"] = convert(plan["increment"], from: plan["unit"].text, to: value.text) }
        guard !plan["set_targets"].isNull else { return next }
        if key == "warmup_count", value.isNull { next["set_targets"] = .null; next["targets_updated_at"] = .null; return next }
        var targets = plan["set_targets"].array
        if key == "unit" { targets = targets.map { var row = $0; row["weight"] = convert(row["weight"], from: plan["unit"].text, to: value.text); return row } }
        if key == "target_reps", !value.isNull { for i in targets.indices where i >= plan["warmup_count"].integer { targets[i]["reps"] = value } }
        if key == "set_count" || key == "warmup_count" {
            let oldWarm = min(targets.count, max(0, plan["warmup_count"].integer))
            let warm = Array(targets.prefix(oldWarm)), work = Array(targets.dropFirst(oldWarm))
            let count = max(1, next["set_count"].integer), warmCount = min(count - 1, max(0, next["warmup_count"].integer))
            next["warmup_count"] = .number(Double(warmCount))
            targets = (0..<count).map { i in
                if i < warmCount { return warm.indices.contains(i) ? warm[i] : warm.last ?? ["weight": nil, "reps": 8] }
                let position = i - warmCount
                return work.indices.contains(position) ? work[position] : work.last ?? ["weight": nil, "reps": next["target_reps"].or(8)]
            }
        }
        next["set_targets"] = .array(targets)
        if ["unit", "target_reps", "set_count", "warmup_count"].contains(key) { next["targets_updated_at"] = NativeDate.stamp(now) }
        return next
    }
    public static func newSet(_ hint: JSONValue = [:]) -> JSONValue {
        var row: JSONValue = ["id": uid(), "weight": nil, "reps": nil, "duration_seconds": nil,
                              "completed_at": nil, "warmup": false, "hard_reps": nil]
        for (key, value) in hint.object { row[key] = value }; return row
    }
    public static func movement(_ exercise: JSONValue, plan: JSONValue = [:], previous: [JSONValue] = []) -> JSONValue {
        let unit = plan["unit"].or(previous.first?["unit"] ?? "lb")
        var m: JSONValue = ["id": uid(), "exercise_id": exercise["id"], "name": exercise["name"],
            "equipment": exercise["equipment"].or(""), "weight_note": exercise["weight_note"].or(""),
            "load_mode": exercise["load_mode"].or("external"), "unit": unit,
            "tracking": exercise["tracking"].or("reps"), "training_type": exercise["training_type"].or("strength"),
            "rest_seconds": plan["rest_seconds"].or(90), "effort": nil, "primary_muscles": exercise["primary_muscles"],
            "secondary_muscles": exercise["secondary_muscles"], "prescription": nil, "baseline_at": plan["targets_updated_at"]]
        let count = max(1, min(30, plan["set_count"].isNull ? 3 : plan["set_count"].integer))
        let rows = (0..<count).map { i -> JSONValue in
            let warm = plan["warmup_count"].isNull ? (previous.indices.contains(i) && previous[i]["warmup"].flag) : i < plan["warmup_count"].integer
            let compatible = plan["warmup_count"].isNull ? previous : previous.filter { $0["warmup"].flag == warm }
            let position = !plan["warmup_count"].isNull && !warm ? i - plan["warmup_count"].integer : i
            let preset = plan["set_targets"][i]
            let hint = plan["prefer_targets"].flag ? JSONValue.null : (compatible.indices.contains(position) ? compatible[position] : preset.isNull ? compatible.last ?? .null : .null)
            let weight = m["load_mode"].text == "bodyweight" ? JSONValue.null : !hint["weight"].isNull ? convert(hint["weight"], from: hint["unit"].text, to: unit.text) : preset["weight"]
            return newSet(["weight": (weight.number ?? 0) <= 2000 ? weight : .null,
                "reps": timed(m) ? .null : hint["reps"].or(preset["reps"].or(plan["target_reps"])),
                "duration_seconds": timed(m) ? hint["duration_seconds"].or(plan["target_seconds"]) : .null, "warmup": .bool(warm)])
        }
        m["sets"] = .array(rows); return m
    }
    public static func start(template: JSONValue = .null, catalog: [JSONValue], history: [JSONValue],
                             remaining: JSONValue = .null, now: Date = Date(), timezone: String = TimeZone.current.identifier) throws -> JSONValue {
        var movements: [JSONValue] = []
        for original in template["exercises"].array {
            var plan = original
            if !remaining.isNull {
                guard let rest = remaining.array.first(where: { $0["exercise_id"] == plan["exercise_id"] }), rest["target"].integer > 0 else { continue }
                let count = rest["target"].integer; plan["set_count"] = .number(Double(count)); plan["warmup_count"] = 0
                if !original["set_targets"].isNull {
                    plan["set_targets"] = .array(Array(original["set_targets"].array.dropFirst(original["warmup_count"].integer).suffix(count)))
                    plan["prefer_targets"] = true
                }
            }
            guard let exercise = catalog.first(where: { $0.id == plan["exercise_id"].text }) else { throw TrainingError.invalid("动作库尚未完整加载，请刷新后重试。") }
            let scoped = history.filter { old in
                guard let baseline = NativeDate.parse(plan["targets_updated_at"]), !plan["set_targets"].isNull else { return true }
                return old["template_id"] == template["id"] && (NativeDate.parse(old["started_at"]) ?? .distantPast) >= baseline
            }
            let hints = previous(scoped, exercise: exercise.id, mode: exercise["load_mode"].text, before: now, timezone: timezone)
            var m = movement(exercise, plan: plan, previous: hints)
            if plan["progression"].text == "double", !plan["prefer_targets"].flag,
               plan["set_targets"].isNull || hints.contains(where: { !$0["warmup"].flag }) {
                var config = plan; config["load_mode"] = m["load_mode"]; config["tracking"] = m["tracking"]; config["training_type"] = m["training_type"]
                config["work_sets"] = .number(Double(m["sets"].array.filter { !$0["warmup"].flag }.count))
                m = adopt(m, prescription: prescription(config, history: scoped, before: now, timezone: timezone))
            }
            movements.append(m)
        }
        return ["id": uid(), "template_id": template["id"], "title": template["name"].or("自由力量训练"),
            "started_at": NativeDate.stamp(now), "ended_at": nil, "timezone": .string(timezone), "status": "active",
            "paused_at": nil, "paused_seconds": 0, "rest_until": nil, "rest_set_id": nil, "notes": "",
            "template_notes": template["notes"].or(""), "duration_min": template["duration_min"],
            "duration_max": template["duration_max"], "exercises": .array(movements)]
    }
    public static func adopt(_ movement: JSONValue, prescription: JSONValue) -> JSONValue {
        guard !prescription.isNull else { return movement }
        var m = movement; m["prescription"] = prescription
        m["sets"] = .array(m["sets"].array.map { row in
            guard row["completed_at"].isNull, !row["warmup"].flag else { return row }
            var s = row; let canFill = !prescription["weight"].isNull || m["load_mode"].text == "bodyweight"
            if canFill { s["weight"] = prescription["weight"] }
            if canFill || prescription["action"].text == "establish" { s["reps"] = prescription["reps"] }; return s
        }); return m
    }
    public static func prescription(_ c: JSONValue, history: [JSONValue], before: Date, timezone: String) -> JSONValue {
        guard !timed(c), !mobility(c) else { return .null }
        let low = c["rep_min"].isNull ? 8 : c["rep_min"].integer, high = c["rep_max"].isNull ? 12 : c["rep_max"].integer
        let step = c["increment"].number ?? (c["unit"].text == "kg" ? 2.5 : 5)
        let count = c["work_sets"].isNull ? (c["set_count"].isNull ? 3 : c["set_count"].integer) : c["work_sets"].integer
        guard low >= 1, high >= low, high <= 100, step > 0, step <= 100, count >= 1, count <= 50 else { return .null }
        var r: JSONValue = ["policy": "double", "rep_min": .number(Double(low)), "rep_max": .number(Double(high)),
            "increment": .number(step), "work_sets": .number(Double(count)), "weight": nil, "reps": .number(Double(low)),
            "action": "establish", "reason": "还没有可比的工作组。先选择能稳定完成目标次数的重量。", "basis_date": nil]
        for s in history.sorted(by: { $0["started_at"].text > $1["started_at"].text }) {
            let day = s["started_at"].text
            guard s["status"].text == "completed", (NativeDate.parse(s["ended_at"]) ?? .distantPast) <= before else { continue }
            if day.count == 10 { if day >= NativeDate.day(before, timezone: timezone) { continue } }
            else if (NativeDate.parse(day) ?? .distantFuture) >= before { continue }
            let ms = s["exercises"].array.filter { $0["exercise_id"] == c["exercise_id"] && $0["load_mode"] == c["load_mode"] }
            let work = ms.flatMap { m in m["sets"].array.filter { !$0["warmup"].flag }.map { row -> JSONValue in var v = row; v["unit"] = m["unit"]; return v } }
            let completed = work.filter { !$0["completed_at"].isNull && valid(c, $0) }; guard !completed.isEmpty else { continue }
            r["basis_date"] = s["started_at"]; r["action"] = "hold"
            let weights = completed.map { convert($0["weight"], from: $0["unit"].text, to: c["unit"].text).number }
            let uniform = c["load_mode"].text == "bodyweight" || weights.allSatisfy { value in value != nil && abs(value! - (weights[0] ?? -10000)) < 0.02 }
            r["weight"] = c["load_mode"].text == "bodyweight" || !uniform ? .null : .value(weights[0])
            r["reps"] = .number(Double(min(high, max(low, (completed.map { $0["reps"].integer }.min() ?? low) + 1))))
            if ms.count != 1 || !uniform { r["reason"] = "上次包含不同重量或同动作的多段记录，先沿用各组重量。"; return r }
            let prior = ms[0]["prescription"]
            if work.count != count || (!prior.isNull && (prior["rep_min"].integer != low || prior["rep_max"].integer != high || prior["work_sets"].integer != count)) {
                r["reason"] = "组数或次数目标与上次不同，先完成新目标再判断是否加重。"; return r
            }
            if completed.count != work.count { r["reps"] = .number(Double(low)); r["reason"] = "上次工作组尚未全部完成。保持重量，先完成目标组。"; return r }
            if !completed.allSatisfy({ $0["reps"].integer >= high }) { r["reason"] = .string("还未全部达到 \(high) 次。保持重量，在 \(low)–\(high) 次内推进。"); return r }
            if c["load_mode"].text == "bodyweight" { r["action"] = "reps"; r["reps"] = .number(Double(high)); r["reason"] = "各组已达上限，可维持次数或手动调整区间。"; return r }
            let priorWeight = r["weight"].number ?? 0
            let next = ((c["load_mode"].text == "assistance" ? max(0, priorWeight - step) : priorWeight + step) * 100).rounded() / 100
            if next == priorWeight || next > 2000 { r["action"] = "limit"; r["reps"] = .number(Double(high)); r["reason"] = "已达记重范围边界，保持本次重量。"; return r }
            r["action"] = c["load_mode"].text == "assistance" ? "less_assistance" : "increase"
            r["weight"] = .number(next); r["reps"] = .number(Double(low))
            r["reason"] = .string("全部工作组达到 \(high) 次，建议\(c["load_mode"].text == "assistance" ? "减少辅助量" : "增加重量")至 \(next) \(c["unit"].text)，次数回到 \(low) 次。")
            return r
        }; return r
    }
    public static func pause(_ session: JSONValue, at now: Date = Date()) -> JSONValue {
        var s = session
        if let paused = NativeDate.parse(s["paused_at"]) {
            let gap = max(0, now.timeIntervalSince(paused)); s["paused_seconds"] = .number((s["paused_seconds"].number ?? 0) + gap)
            if let rest = NativeDate.parse(s["rest_until"]) { s["rest_until"] = NativeDate.stamp(rest.addingTimeInterval(gap)) }
            s["paused_at"] = .null
        } else { s["paused_at"] = NativeDate.stamp(now) }; return s
    }
    public static func finish(_ session: JSONValue, status: String = "completed", at now: Date = Date()) -> JSONValue {
        var s = session["paused_at"].isNull ? session : pause(session, at: now)
        s["status"] = .string(status); s["ended_at"] = NativeDate.stamp(now); s["rest_until"] = .null; s["rest_set_id"] = .null; return s
    }
    public static func toggle(_ session: JSONValue, movement mi: Int, set si: Int, at now: Date = Date()) throws -> JSONValue {
        var s = session; let m = s["exercises"][mi]; let row = m["sets"][si]
        guard !m.isNull, !row.isNull else { throw TrainingError.invalid("这组记录已更改，请重新打开。") }
        guard s["paused_at"].isNull else { throw TrainingError.invalid("请先继续训练，再记录完成。") }
        if row["completed_at"].isNull {
            guard valid(m, row) else { throw TrainingError.invalid(timed(m) ? "请填写 1–3600 秒。" : "请填写有效的重量和次数。") }
            s["exercises"][mi]["sets"][si]["completed_at"] = NativeDate.stamp(now)
            let rest = row["warmup"].flag ? min(60, m["rest_seconds"].integer) : m["rest_seconds"].integer
            s["rest_until"] = rest > 0 ? NativeDate.stamp(now.addingTimeInterval(Double(rest))) : .null
            s["rest_set_id"] = rest > 0 ? row["id"] : .null
        } else {
            s["exercises"][mi]["sets"][si]["completed_at"] = .null
            if s["rest_set_id"] == row["id"] { s["rest_until"] = .null; s["rest_set_id"] = .null }
        }; return s
    }
    /// Where to resume: the movement of the latest completed set while it still has
    /// open sets, otherwise the next movement with open sets.
    public static func resumeIndex(_ s: JSONValue) -> Int {
        let ms = s["exercises"].array
        guard !ms.isEmpty else { return 0 }
        let open = ms.map { m in m["sets"].array.contains { $0["completed_at"].isNull } }
        var latest: (index: Int, at: Date)?
        for (i, m) in ms.enumerated() {
            for row in m["sets"].array { if let at = NativeDate.parse(row["completed_at"]), at > (latest?.at ?? .distantPast) { latest = (i, at) } }
        }
        guard let last = latest?.index else { return open.firstIndex(of: true) ?? 0 }
        if open[last] { return last }
        return (last + 1 ..< ms.count).first { open[$0] } ?? open.firstIndex(of: true) ?? last
    }
    public static func snapshot(_ s: JSONValue, movement index: Int) -> WorkoutSnapshot? {
        guard s["status"].text == "active", let start = NativeDate.parse(s["started_at"]), Date().timeIntervalSince(start) < 7 * 86400 else { return nil }
        let ms = s["exercises"].array; let i = min(max(0, index), max(0, ms.count - 1)); let m = ms.indices.contains(i) ? ms[i] : .null
        let rows = m["sets"].array; let next = rows.firstIndex { $0["completed_at"].isNull }.map { $0 + 1 } ?? rows.count
        return WorkoutSnapshot(protocolVersion: 1, sessionID: s.id, title: s["title"].text, startedAt: start,
            pausedAt: NativeDate.parse(s["paused_at"]), pausedSeconds: s["paused_seconds"].number ?? 0,
            restUntil: NativeDate.parse(s["rest_until"]), movementName: m["name"].text, movementIndex: ms.isEmpty ? 0 : i + 1,
            movementCount: ms.count, completedSets: ms.reduce(0) { $0 + done($1).count },
            plannedSets: ms.reduce(0) { $0 + $1["sets"].array.count }, currentSet: next, movementSetCount: rows.count)
    }
}

public enum NativeReview {
    public static func fallback(_ session: JSONValue, evidence: JSONValue = .null) -> JSONValue {
        let ms=session["exercises"].array.filter{!NativeTraining.mobility($0) && !NativeTraining.timed($0)}
        let facts=evidence["facts"].array
        let nextFact=facts.first{$0.id==evidence["next_focus"].text}
        let focus=ms.first{nextFact?["text"].text.hasPrefix($0["name"].text) == true} ?? ms.first{!NativeTraining.done($0).filter{!$0["warmup"].flag}.isEmpty}
        let progress=NativeTraining.progress(session)
        guard let m=focus else{return ["today":["text":.string("完成 \(progress.done)/\(progress.planned) 练习组。")],"trend":["text":"本次实际记录已保留。"],"next":["text":"保持舒适、稳定的活动范围。"]]}
        let work=m["sets"].array.filter{!$0["warmup"].flag},done=NativeTraining.done(m).filter{!$0["warmup"].flag}
        func n(_ value:JSONValue)->String { value.number.map{String(format:"%g",$0)} ?? "—" }
        func load(_ row:JSONValue)->String { m["load_mode"].text=="bodyweight" ? "自重" : (m["load_mode"].text=="assistance" ? "辅助 " : "")+n(row["weight"])+" "+m["unit"].text }
        let today=m["name"].text+"："+done.map{load($0)+" × "+n($0["reps"])+" 次"}.joined(separator:"；")+"。"
        let trend=facts.first{$0["kind"].text=="trend"}?["text"].text ?? facts.first{$0["kind"].text=="comparison"}?["text"].text ?? (done.count>1 ? m["name"].text+"首组 "+n(done.first!["reps"])+" 次，末组 "+n(done.last!["reps"])+" 次。" : "本次记录作为下一次同模板的对照。")
        var next=nextFact?["text"].text ?? ""
        if next.isEmpty {
            if let i=work.firstIndex(where:{$0["completed_at"].isNull}) { next=m["name"].text+"下次先完成第 \(i+1) 组"+(NativeTraining.valid(m,work[i]) ? "："+load(work[i])+" × "+n(work[i]["reps"])+" 次。" : "。") }
            else if let i=done.lastIndex(where:{$0["hard_reps"].integer>0 && $0["hard_reps"].integer <= $0["reps"].integer}) { next=m["name"].text+"第 \(i+1) 组自报吃力，下次先稳住 "+load(done[i])+" × "+n(done[i]["reps"])+" 次。" }
            else if let row=done.min(by:{$0["reps"].integer<$1["reps"].integer}) { next=m["name"].text+"先保持 "+load(row)+"，动作稳定且有余力时尝试 \(min(1000,row["reps"].integer+1,m["prescription"]["rep_max"].isNull ? 1000 : m["prescription"]["rep_max"].integer)) 次。" }
        }
        return ["today":["text":.string(today)],"trend":["text":.string(trend)],"next":["text":.string(next)]]
    }
}

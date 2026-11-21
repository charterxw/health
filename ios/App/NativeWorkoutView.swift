import SwiftUI

struct SetSelection: Identifiable { let id: String; let movementID: String }
struct NativeWorkoutView: View {
    @Environment(NativeStore.self) var store
    @PineReducedMotion private var reduceMotion
    @State private var finish = false
    @State private var discard = false
    @State private var adding = false
    @State private var options = false
    @State private var setSelection: SetSelection?
    @State private var editingSet: SetSelection?
    @State private var editingMovement = false
    @State private var replacing = false
    @State private var showExercise = false
    @State private var lastEdited: String?
    @State private var completedTick = 0
    /// "Better than last time" after a set, shown for a moment.
    @State private var cheer: String?
    @State private var cheerTick = 0
    @State private var extendTick = 0
    /// The rest clock just ran out on its own: a gold ring swells once.
    @State private var restFlash = 0
    @State private var flashing = false
    private var record: NativeRecord? { store.active }
    private var session: JSONValue { record?.session ?? .null }
    private var movements: [JSONValue] { session["exercises"].array }
    private var mi: Int { min(store.movementIndex, max(0, movements.count - 1)) }
    private var movement: JSONValue { session["exercises"][mi] }
    private var sets: [JSONValue] { movement["sets"].array }
    /// The set being recorded: the first unfinished one of this movement.
    private var current: Int? { sets.firstIndex { $0["completed_at"].isNull } }
    private var paused: Bool { !session["paused_at"].isNull }
    var body: some View {
        NavigationStack {
            Group {
                if record != nil {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        ScrollView { content(now: context.date).padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 24) }
                            .safeAreaInset(edge: .bottom) { bottomBar(now: context.date) }
                            .onChange(of: restRemaining(context.date) != nil) { was, now in
                                // Ran out by itself (not skipped): rest_until is still set.
                                if was, !now, !paused, !session["rest_until"].isNull { restFlash += 1 }
                            }
                            .overlay(alignment: .top) {
                                if let cheer {
                                    HStack(spacing: 8) {
                                        Image(systemName: "sparkles").foregroundStyle(pineGold)
                                        Text(cheer).font(.subheadline.weight(.semibold))
                                    }
                                    .padding(.horizontal, 16).padding(.vertical, 10)
                                    .background(.regularMaterial, in: Capsule())
                                    .shadow(color: .black.opacity(0.1), radius: 10, y: 3)
                                    .padding(.top, 6)
                                    .transition(.move(edge: .top).combined(with: .opacity))
                                    .accessibilityAddTraits(.updatesFrequently)
                                }
                            }
                    }
                } else {
                    VStack(spacing: 16) { PineEmpty(title: "没有进行中的训练", symbol: "checkmark.circle"); Button("返回") { store.workoutPresented = false } }
                }
            }
            .background(pineCanvas)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("收起", systemImage: "chevron.down") { store.workoutPresented = false }.labelStyle(.iconOnly) }
                ToolbarItem(placement: .principal) { header }
                ToolbarItem(placement: .topBarTrailing) { Button("结束") { finish = true }.fontWeight(.semibold).disabled(record == nil) }
            }
            .sensoryFeedback(.success, trigger: completedTick)
            .sensoryFeedback(.impact(weight: .light), trigger: extendTick)
            .sensoryFeedback(.impact(weight: .medium), trigger: restFlash)
            .task(id: restFlash) {
                guard restFlash > 0, !reduceMotion else { return }
                flashing = true
                try? await Task.sleep(for: .seconds(0.9))
                flashing = false
            }
            .task(id: cheerTick) {
                guard cheer != nil else { return }
                try? await Task.sleep(for: .seconds(2.4))
                withAnimation(.easeOut(duration: 0.25)) { cheer = nil }
            }
            .alert("完成这场训练？", isPresented: $finish) {
                Button("继续记录", role: .cancel) { }
                Button("完成并保存") { if let id = record?.id { store.finish(id) } }
            } message: { let p = NativeTraining.progress(session); Text("已完成 \(p.done)/\(p.planned) 工作组，热身 \(p.warmup) 组。未完成的组不会计入记录。") }
            .confirmationDialog("放弃这场训练？", isPresented: $discard, titleVisibility: .visible) { Button("放弃训练", role: .destructive) { if let id = record?.id { store.finish(id, discard: true) } } }
            .sheet(isPresented: $adding) { NavigationStack { NativeExerciseLibrary { exercise in
                mutate { s in s["exercises"] = .array(s["exercises"].array + [NativeTraining.movement(exercise)]) }; store.selectMovement(session["exercises"].array.count - 1); adding = false
            } } }
            .sheet(isPresented: $replacing) { NavigationStack { NativeExerciseLibrary { exercise in replace(exercise); replacing = false } } }
            .sheet(isPresented: $options) { workoutOptions }
            .sheet(isPresented: $editingMovement) { movementOptions }
            .sheet(isPresented: $showExercise) { NavigationStack { NativeExerciseDetail(exercise: store.exercises.first { $0.id == movement["exercise_id"].text } ?? movement).toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showExercise = false } } } } }
            .sheet(item: $setSelection) { selection in NativeSetOptions(sessionID: session.id, selection: selection) }
            .sheet(item: $editingSet) { selection in NativeSetValues(sessionID: session.id, selection: selection).presentationDetents([.medium]) }
        }
    }

    // MARK: Header
    private var header: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let end = NativeDate.parse(session["paused_at"]) ?? context.date
            let seconds = max(0, end.timeIntervalSince(NativeDate.parse(session["started_at"]) ?? end) - (session["paused_seconds"].number ?? 0))
            let p = NativeTraining.progress(session)
            VStack(spacing: 0) {
                Text(WorkoutSnapshot.clock(seconds)).font(.headline).monospacedDigit()
                Text(paused ? "已暂停" : "\(p.done) / \(p.planned) 组").font(.caption2).foregroundStyle(.secondary)
            }.accessibilityElement(children: .combine).accessibilityLabel("训练用时 " + WorkoutSnapshot.clock(seconds) + (paused ? "，已暂停" : "，已完成 \(p.done) 组，共 \(p.planned) 组"))
        }
    }

    // MARK: Content
    @ViewBuilder private func content(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if paused { PineBanner(text: "训练已暂停，计时与休息倒计时保持不变。").padding(.bottom, 12) }
            if let message = store.message { PineBanner(text: message).padding(.bottom, 12) }
            if let row = record, row.blocked != nil { NativeConflictView(record: row).padding(.bottom, 12) }
            if movement.isNull {
                PineEmpty(title: "添加第一个动作", symbol: "dumbbell", detail: "从动作库选择，开始记录这场训练。")
                Button("添加动作", systemImage: "plus") { adding = true }.buttonStyle(.bordered).frame(maxWidth: .infinity)
            } else {
                movementHeader
                // The finished set gives way to the rest clock, and the next set
                // rises in from below.
                if let rest = restRemaining(now) { restPanel(remaining: rest).padding(.top, 20).transition(.opacity.combined(with: .scale(scale: 0.97))) }
                else {
                    setPanel.padding(.top, 18).id("set-\(mi)-\(current ?? -1)")
                        .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity))
                        .overlay(alignment: .top) { if flashing { PineRingFlash().padding(.top, 2).transition(.identity) } }
                }
            }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.86), value: "\(mi)-\(current ?? -1)-\(restRemaining(now) != nil)")
    }
    private func restRemaining(_ now: Date) -> TimeInterval? {
        guard !paused, let until = NativeDate.parse(session["rest_until"]) else { return nil }
        let remaining = until.timeIntervalSince(now)
        return remaining > 0 ? remaining : nil
    }
    private var movementHeader: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Menu {
                    ForEach(Array(movements.enumerated()), id: \.offset) { index, item in
                        Button("\(index + 1). " + item["name"].text) { store.selectMovement(index); lastEdited = nil }
                    }
                    Divider()
                    Button("添加动作", systemImage: "plus") { adding = true }.disabled(movements.count >= 40)
                } label: {
                    Label("动作 \(mi + 1) / \(movements.count)", systemImage: "list.bullet").font(.footnote).foregroundStyle(.secondary)
                        .padding(.horizontal, 12).frame(height: 32).background(pineSurface, in: Capsule())
                }
                Spacer()
                Menu {
                    Button("动作设置", systemImage: "slider.horizontal.3") { editingMovement = true }
                    Button("动作要领与历史", systemImage: "info.circle") { showExercise = true }
                    Button(paused ? "继续训练" : "暂停训练", systemImage: paused ? "play" : "pause") { mutate { $0 = NativeTraining.pause($0) } }
                    Button("训练选项", systemImage: "ellipsis.circle") { options = true }
                } label: { Image(systemName: "ellipsis").font(.body.weight(.semibold)).frame(width: 44, height: 44).background(pineSurface, in: Circle()) }
                    .accessibilityLabel("更多操作")
            }
            Text(movement["name"].text).font(.title.weight(.semibold)).padding(.top, 10)
            if !previousText.isEmpty { Text(previousText).font(.subheadline).foregroundStyle(.secondary).padding(.top, 4) }
            if NativeTraining.isStepUp(movement["prescription"]) {
                // Progress made visible: last time every set reached the top of the range.
                Label((movement["prescription"]["action"].text == "less_assistance" ? "该减辅助了 · " : "该加重了 · ") + displayNumber(movement["prescription"]["weight"]) + " " + unitLabel(movement), systemImage: "arrow.up.circle.fill")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 6).background(pine, in: Capsule()).padding(.top, 8)
            }
            if !NativeTraining.isStepUp(movement["prescription"]), stalled >= 3 {
                // No new best for three sessions: suggest a reset or a swap.
                VStack(alignment: .leading, spacing: 4) {
                    Label("连续 \(stalled) 次没进步", systemImage: "pause.circle").font(.subheadline.weight(.semibold))
                    Text("可以把重量减约 10%，每组做到区间上限再加回来；或在右上角 ⋯ → 动作设置里换成同部位的替代动作。").font(.footnote).foregroundStyle(.secondary)
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(pineTint, in: RoundedRectangle(cornerRadius: 14, style: .continuous)).padding(.top, 8)
            }
            if !movement["prescription"]["reason"].text.isEmpty { Text(movement["prescription"]["reason"].text).font(.footnote).foregroundStyle(pine).padding(.top, 6) }
        }
    }
    /// Sessions since this lift's last new best, before today's workout.
    private var stalled: Int {
        guard !NativeTraining.timed(movement), !NativeTraining.mobility(movement) else { return 0 }
        return NativeDays.stallCount(exerciseID: movement["exercise_id"].text, loadMode: movement["load_mode"].text, history: store.history,
                                     before: NativeDate.parse(session["started_at"]) ?? Date())
    }
    private var previousText: String {
        let hints = store.previousSets(exercise: movement["exercise_id"].text, mode: movement["load_mode"].text,
            before: session["started_at"], timezone: session["timezone"].text, current: session.id).filter { !$0["warmup"].flag }
        guard !hints.isEmpty else { return "" }
        let texts = hints.map { prior -> String in var row = prior; row["weight"] = NativeTraining.convert(prior["weight"], from: prior["unit"].text, to: movement["unit"].text); return loadText(movement, row) }
        return Set(texts).count == 1 ? "上次 " + texts[0] + "，\(texts.count) 组" : "上次 " + texts.joined(separator: " / ")
    }
    private func setName(_ index: Int) -> String {
        guard sets.indices.contains(index) else { return "" }
        if sets[index]["warmup"].flag { return "热身组" }
        return "第 \(sets.prefix(index + 1).filter { !$0["warmup"].flag }.count) 组"
    }

    // MARK: Recording one set
    @ViewBuilder private var setPanel: some View {
        if let ci = current {
            let row = sets[ci]
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(setName(ci)).font(.headline)
                    Spacer()
                    HStack(spacing: 5) {
                        ForEach(Array(sets.enumerated()), id: \.element.id) { index, item in
                            Capsule().fill(!item["completed_at"].isNull ? pine : index == ci ? pine.opacity(0.4) : pineTrack).frame(width: 18, height: 6)
                        }
                    }.accessibilityHidden(true)
                }.padding(.bottom, 8)
                if movement["load_mode"].text != "bodyweight", !NativeTraining.timed(movement) {
                    valueRow(ci, key: "weight", unit: (movement["load_mode"].text == "assistance" ? "辅助 " : "") + unitLabel(movement), step: weightStep, maximum: 2000, decimal: true)
                }
                let key = NativeTraining.timed(movement) ? "duration_seconds" : "reps"
                valueRow(ci, key: key, unit: NativeTraining.timed(movement) ? "秒" : "次", step: NativeTraining.timed(movement) ? 5 : 1, maximum: NativeTraining.timed(movement) ? 3600 : 1000, decimal: false)
                if !NativeTraining.timed(movement), !NativeTraining.mobility(movement) {
                    Button { setSelection = SetSelection(id: row.id, movementID: movement.id) } label: {
                        Label(row["hard_reps"].isNull ? "最后几次很吃力？" : "吃力 \(row["hard_reps"].integer) 次 · 修改", systemImage: "exclamationmark.circle").font(.subheadline).foregroundStyle(.secondary).frame(minHeight: 44)
                    }.buttonStyle(.plain)
                }
            }.pineCard()
            otherSets(except: ci).padding(.top, 12)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Label("这个动作完成了", systemImage: "checkmark.circle").font(.headline).foregroundStyle(pine)
                Text(mi + 1 < movements.count ? "接下来是" + movements[mi + 1]["name"].text + "。" : "所有动作都完成了，可以结束训练。").font(.subheadline).foregroundStyle(.secondary)
                Button("再加一组", systemImage: "plus") { appendSet() }.font(.subheadline).frame(minHeight: 44).disabled(sets.count >= 50)
            }.pineCard()
            otherSets(except: nil).padding(.top, 12)
        }
    }
    private var weightStep: Double {
        if let increment = movement["prescription"]["increment"].number, increment > 0 { return increment }
        return movement["unit"].text == "kg" ? 2.5 : 5
    }
    private func valueRow(_ si: Int, key: String, unit: String, step: Double, maximum: Double, decimal: Bool) -> some View {
        let value = sets[si][key]
        return HStack(spacing: 8) {
            Button { editingSet = SetSelection(id: sets[si].id, movementID: movement.id) } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(displayNumber(value, digits: 2)).font(.system(size: 44, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(.primary)
                        .contentTransition(reduceMotion ? .identity : .numericText(value: value.number ?? 0))
                    Text(unit).font(.subheadline).foregroundStyle(.secondary)
                }
            }.buttonStyle(.plain).accessibilityLabel(unit + " " + displayNumber(value, digits: 2) + "，点按直接输入")
            Spacer(minLength: 8)
            HStack(spacing: 0) {
                Button { adjust(si, key: key, by: -step, maximum: maximum, decimal: decimal) } label: { Image(systemName: "minus").frame(width: 58, height: 44) }
                    .accessibilityLabel("减少 " + displayNumber(.number(step), digits: 2))
                Divider().frame(height: 20)
                Button { adjust(si, key: key, by: step, maximum: maximum, decimal: decimal) } label: { Image(systemName: "plus").frame(width: 58, height: 44) }
                    .accessibilityLabel("增加 " + displayNumber(.number(step), digits: 2))
            }.font(.body.weight(.semibold)).foregroundStyle(.primary).background(Color(uiColor: .tertiarySystemFill), in: Capsule())
                .sensoryFeedback(.selection, trigger: value)
        }.frame(minHeight: 72).overlay(alignment: .top) { Divider() }
    }
    private func adjust(_ si: Int, key: String, by delta: Double, maximum: Double, decimal: Bool) {
        let minimum: Double = key == "weight" ? 0 : 1
        var next = (sets[si][key].number ?? (key == "weight" ? 0 : minimum - delta)) + delta
        next = min(maximum, max(minimum, decimal ? (next * 100).rounded() / 100 : next.rounded()))
        editSet(si, key: key, value: .number(next))
    }
    private func otherSets(except ci: Int?) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(sets.enumerated()).filter { $0.offset != ci }, id: \.element.id) { index, row in
                Button { setSelection = SetSelection(id: row.id, movementID: movement.id) } label: {
                    HStack(spacing: 10) {
                        Text(setName(index)).frame(maxWidth: .infinity, alignment: .leading)
                        Text(loadText(movement, row)).monospacedDigit()
                        Image(systemName: row["completed_at"].isNull ? "circle" : "checkmark").font(.subheadline.weight(.semibold))
                            .foregroundStyle(row["completed_at"].isNull ? Color.secondary.opacity(0.4) : pine).frame(width: 20)
                    }.foregroundStyle(.secondary).padding(.horizontal, 16).frame(minHeight: 48).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel(setName(index) + "，" + loadText(movement, row) + (row["completed_at"].isNull ? "，未完成" : "，已完成"))
                if index != sets.indices.last, !(ci == sets.count - 1 && index == sets.count - 2) { Divider().padding(.leading, 16) }
            }
            Button { appendSet() } label: { Label("添加一组", systemImage: "plus").font(.subheadline).frame(maxWidth: .infinity, minHeight: 44) }
                .disabled(sets.count >= 50).overlay(alignment: .top) { Divider().padding(.leading, 16) }
        }.background(pineSurface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    // MARK: Rest
    private func restPanel(remaining: TimeInterval) -> some View {
        let total = max(remaining, Double(max(1, movement["rest_seconds"].integer)))
        let doneIndex = sets.lastIndex { !$0["completed_at"].isNull }
        // The last three seconds turn gold and tick, each with a light tap.
        let second = Int(ceil(remaining)), final = second <= 3
        return VStack(spacing: 18) {
            if let doneIndex { Text(setName(doneIndex) + "完成").font(.subheadline).foregroundStyle(.secondary) }
            ZStack {
                Circle().stroke(pineTrack, lineWidth: 14)
                Circle().trim(from: 0, to: remaining / total).stroke(final ? pineGold : pine, style: StrokeStyle(lineWidth: 14, lineCap: .round)).rotationEffect(.degrees(-90))
                    .animation(reduceMotion ? nil : .linear(duration: 1), value: remaining)
                    .animation(.easeInOut(duration: 0.3), value: final)
                VStack(spacing: 4) {
                    Text("休息").font(.subheadline).foregroundStyle(.secondary)
                    Text(WorkoutSnapshot.clock(ceil(remaining))).font(.system(size: 60, weight: .semibold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(final ? pineGold : .primary)
                        .keyframeAnimator(initialValue: 1.0, trigger: second) { text, scale in text.scaleEffect(scale) } keyframes: { _ in
                            KeyframeTrack {
                                SpringKeyframe(final && !reduceMotion ? 1.14 : 1.0, duration: 0.12)
                                SpringKeyframe(1.0, duration: 0.4)
                            }
                        }
                    Button("+30 秒") { extendRest() }.font(.subheadline.weight(.semibold)).padding(.horizontal, 14).frame(height: 36)
                        .background(Color(uiColor: .tertiarySystemFill), in: Capsule()).buttonStyle(.plain)
                }
            }.frame(width: 240, height: 240)
                .keyframeAnimator(initialValue: 1.0, trigger: extendTick) { ring, scale in ring.scaleEffect(scale) } keyframes: { _ in
                    KeyframeTrack {
                        SpringKeyframe(reduceMotion ? 1.0 : 1.06, duration: 0.14)
                        SpringKeyframe(1.0, duration: 0.35)
                    }
                }
                .sensoryFeedback(.impact(weight: .light, intensity: 0.8), trigger: second) { _, next in next <= 3 && next > 0 }
                .accessibilityElement(children: .combine).accessibilityLabel("组间休息，剩余 " + WorkoutSnapshot.clock(ceil(remaining)))
            if let ci = current {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("下一组 · " + setName(ci)).font(.footnote).foregroundStyle(.secondary)
                        Text(loadText(movement, sets[ci])).font(.title3.weight(.semibold)).monospacedDigit()
                    }
                    Spacer()
                    Button("调整") { editingSet = SetSelection(id: sets[ci].id, movementID: movement.id) }.font(.subheadline.weight(.semibold)).frame(minHeight: 44)
                }.pineCard()
            }
            Text("锁屏和灵动岛会继续倒计时。").font(.footnote).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity)
    }
    private func extendRest() {
        extendTick += 1
        mutate { s in
            guard let until = NativeDate.parse(s["rest_until"]) else { return }
            s["rest_until"] = NativeDate.stamp(min(until.addingTimeInterval(30), Date().addingTimeInterval(600)))
        }
    }

    // MARK: Primary action
    private func bottomBar(now: Date) -> some View {
        let resting = restRemaining(now) != nil
        return VStack(spacing: 4) {
            if !resting, current == nil || current == 0, mi + 1 < movements.count {
                Button { store.selectMovement(mi + 1); lastEdited = nil } label: {
                    HStack(spacing: 4) { Text("下一个：" + movements[mi + 1]["name"].text); Image(systemName: "chevron.right").font(.caption.weight(.semibold)) }.font(.subheadline).foregroundStyle(.secondary).frame(minHeight: 40)
                }.buttonStyle(.plain)
            }
            primaryButton(resting: resting, final: (restRemaining(now) ?? 99) <= 3)
        }.padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 4)
            .background(LinearGradient(colors: [pineCanvas.opacity(0), pineCanvas], startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.35)))
    }
    @ViewBuilder private func primaryButton(resting: Bool, final: Bool) -> some View {
        if resting, let ci = current {
            // Breathes in the last seconds of rest: time to pick the weight up.
            Button { mutate { $0["rest_until"] = .null; $0["rest_set_id"] = .null } } label: {
                Text("开始" + setName(ci)).primaryLabel()
                    .phaseAnimator(final && !reduceMotion ? [1.0, 1.035] : [1.0]) { label, scale in
                        label.scaleEffect(scale).shadow(color: pine.opacity(scale > 1 ? 0.35 : 0), radius: 12)
                    } animation: { _ in .easeInOut(duration: 0.5) }
            }
                .buttonStyle(PinePressStyle(scale: 0.98))
        } else if let ci = current {
            Button { complete(ci) } label: { Label("完成" + setName(ci), systemImage: "checkmark").primaryLabel() }
                .buttonStyle(PinePressStyle(scale: 0.98)).disabled(paused || store.storageFailed || !NativeTraining.valid(movement, sets[ci]))
                .accessibilityIdentifier("set-\(ci)-complete")
        } else if mi + 1 < movements.count {
            Button { store.selectMovement(mi + 1); lastEdited = nil } label: { Text("下一个动作").primaryLabel() }.buttonStyle(PinePressStyle(scale: 0.98))
        } else {
            // Everything is done: hold to save, no extra alert.
            PineHoldButton(title: "按住完成训练") { if let id = record?.id { store.finish(id) } }
        }
    }
    private func complete(_ ci: Int) {
        let better = improvement(ci)
        mutate { s in s = try NativeTraining.toggle(s, movement: mi, set: ci) }
        if !(session["exercises"][mi]["sets"][ci]["completed_at"].isNull) {
            completedTick += 1
            if let better {
                withAnimation(reduceMotion ? nil : .spring(response: 0.45, dampingFraction: 0.7)) { cheer = better }
                cheerTick += 1
            }
        }
    }
    /// The same work set last time, and what this one improved on it.
    private func improvement(_ ci: Int) -> String? {
        guard sets.indices.contains(ci), !sets[ci]["warmup"].flag, !NativeTraining.mobility(movement) else { return nil }
        let hints = store.previousSets(exercise: movement["exercise_id"].text, mode: movement["load_mode"].text,
            before: session["started_at"], timezone: session["timezone"].text, current: session.id).filter { !$0["warmup"].flag }
        let workIndex = sets.prefix(ci).filter { !$0["warmup"].flag }.count
        guard hints.indices.contains(workIndex) else { return nil }
        let row = sets[ci], prior = hints[workIndex]
        if NativeTraining.timed(movement) {
            let delta = row["duration_seconds"].integer - prior["duration_seconds"].integer
            return delta > 0 ? "比上次多 \(delta) 秒" : nil
        }
        let reps = row["reps"].integer - prior["reps"].integer
        if movement["load_mode"].text == "bodyweight" { return reps > 0 ? "比上次多 \(reps) 次" : nil }
        guard let weight = row["weight"].number, let before = NativeTraining.convert(prior["weight"], from: prior["unit"].text, to: movement["unit"].text).number else { return nil }
        let unit = unitLabel(movement)
        if movement["load_mode"].text == "assistance" {
            if weight < before - 0.01 { return "辅助比上次少 " + displayNumber(.number(before - weight)) + " " + unit }
        } else if weight > before + 0.01 {
            return "比上次重 " + displayNumber(.number(weight - before)) + " " + unit
        }
        return abs(weight - before) < 0.01 && reps > 0 ? "比上次多 \(reps) 次" : nil
    }
    private var workoutOptions: some View {
        NavigationStack {
            Form {
                Section("本次训练") {
                    NativeTitleField(title: session["title"].text) { text in mutate { $0["title"] = .string(text) } }
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

/// Edits a local draft so the name can be cleared and retyped; saves a valid,
/// non-empty name on return, focus loss or when the sheet closes.
struct NativeTitleField: View {
    let title: String
    let save: (String) -> Void
    @State private var draft = ""
    @FocusState private var focused: Bool
    var body: some View {
        TextField("名称", text: $draft).focused($focused).submitLabel(.done)
            .onAppear { draft = title }
            .onSubmit(commit)
            .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
            .onDisappear(perform: commit)
    }
    private func commit() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 100 else { draft = title; return }
        if text != title { save(text) }
    }
}

private extension View {
    /// The one filled action per screen: full width, thumb-reachable.
    func primaryLabel() -> some View {
        font(.headline).foregroundStyle(.white).frame(maxWidth: .infinity, minHeight: 56).background(pine, in: Capsule())
    }
}

/// Direct numeric entry for one set, reached by tapping its large value.
struct NativeSetValues: View {
    @Environment(NativeStore.self) var store
    @Environment(\.dismiss) private var dismiss
    let sessionID: String
    let selection: SetSelection
    private var session: JSONValue { store.recordDocuments[sessionID]?.session ?? .null }
    private var mi: Int? { session["exercises"].array.firstIndex { $0.id == selection.movementID } }
    private var movement: JSONValue { mi.map { session["exercises"][$0] } ?? .null }
    private var si: Int? { movement["sets"].array.firstIndex { $0.id == selection.id } }
    private var row: JSONValue { si.map { movement["sets"][$0] } ?? .null }
    var body: some View {
        NavigationStack {
            Form {
                Section(movement["name"].text) {
                    if movement["load_mode"].text != "bodyweight", !NativeTraining.timed(movement) {
                        HStack { Text("重量 / " + unitLabel(movement)); Spacer(); NativeNumberField(label: "重量", value: row["weight"], decimal: true) { assign("weight", $0) }.frame(width: 120) }
                    }
                    let timed = NativeTraining.timed(movement)
                    HStack { Text(timed ? "秒数" : "次数"); Spacer(); NativeNumberField(label: timed ? "秒数" : "次数", value: row[timed ? "duration_seconds" : "reps"], maximum: timed ? 3600 : 1000, minimum: 1) { assign(timed ? "duration_seconds" : "reps", $0) }.frame(width: 120) }
                }
            }.navigationTitle("输入数值").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }
    private func assign(_ key: String, _ value: JSONValue) {
        guard let mi, let si else { return }
        store.update(sessionID) { s in
            s["exercises"][mi]["sets"][si][key] = value
            if !NativeTraining.valid(s["exercises"][mi], s["exercises"][mi]["sets"][si]) {
                s["exercises"][mi]["sets"][si]["completed_at"] = .null
                if s["rest_set_id"] == s["exercises"][mi]["sets"][si]["id"] { s["rest_set_id"] = .null; s["rest_until"] = .null }
            }
        }
    }
}

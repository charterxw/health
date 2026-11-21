import SwiftUI

struct SetSelection: Identifiable, Equatable { let id: String; let movementID: String }
struct NativeWorkoutView: View {
    @Environment(NativeStore.self) var store
    @PineReducedMotion private var reduceMotion
    @State private var finish = false
    @State private var discard = false
    /// Nothing is checked off yet: leaving offers to drop the workout instead of saving it empty.
    @State private var emptyExit = false
    @State private var emptyExitCollapses = false
    @State private var adding = false
    @State private var options = false
    @State private var editingSet: SetSelection?
    @State private var editingMovement = false
    @State private var reordering = false
    @State private var editingNote = false
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
    /// When the rest state was last evaluated. It is refreshed when the rest changes and
    /// when it runs out, so the screen redraws at those moments rather than every second;
    /// only the clocks themselves tick.
    @State private var clock = Date()
    /// The set just checked off, offered for undo for a few seconds.
    @State private var undoable: SetSelection?
    private var record: NativeRecord? { store.active }
    private var session: JSONValue { record?.session ?? .null }
    private var movements: [JSONValue] { session["exercises"].array }
    private var mi: Int { min(store.movementIndex, max(0, movements.count - 1)) }
    private var movement: JSONValue { session["exercises"][mi] }
    private var sets: [JSONValue] { movement["sets"].array }
    /// The set being recorded: the first unfinished one of this movement.
    private var current: Int? { sets.firstIndex { $0["completed_at"].isNull } }
    private var paused: Bool { !session["paused_at"].isNull }
    private var restUntil: Date? { paused ? nil : NativeDate.parse(session["rest_until"]) }
    private var resting: Bool { restUntil.map { $0 > clock } ?? false }
    private var restKey: String { session.id + "|" + session["rest_until"].text + (paused ? "|paused" : "") }
    private var anyCompleted: Bool { movements.contains { $0["sets"].array.contains { !$0["completed_at"].isNull } } }
    var body: some View {
        NavigationStack {
            Group {
                if record != nil {
                    ScrollView { content.padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 24) }
                        .safeAreaInset(edge: .bottom) { bottomBar }
                        .overlay(alignment: .top) { cheerBanner }
                } else {
                    VStack(spacing: 16) { PineEmpty(title: "没有进行中的训练", symbol: "checkmark.circle"); Button("返回") { store.workoutPresented = false } }
                }
            }
            .background(pineCanvas)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("收起", systemImage: "chevron.down") {
                        if record != nil, !anyCompleted { emptyExitCollapses = true; emptyExit = true } else { store.workoutPresented = false }
                    }.labelStyle(.iconOnly)
                }
                ToolbarItem(placement: .principal) { header }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("结束") { if anyCompleted { finish = true } else { emptyExitCollapses = false; emptyExit = true } }
                        .fontWeight(.semibold).disabled(record == nil)
                }
            }
            .sensoryFeedback(.success, trigger: completedTick)
            .sensoryFeedback(.impact(weight: .light), trigger: extendTick)
            .sensoryFeedback(.impact(weight: .medium), trigger: restFlash)
            .task(id: restKey) { await watchRest() }
            .task(id: restFlash) {
                guard restFlash > 0, !reduceMotion else { return }
                flashing = true
                try? await Task.sleep(for: .seconds(0.9))
                flashing = false
            }
            .task(id: cheerTick) {
                guard cheer != nil else { return }
                do { try await Task.sleep(for: .seconds(2.4)) } catch { return }
                withAnimation(.easeOut(duration: 0.25)) { cheer = nil }
            }
            .task(id: undoable?.id) {
                guard undoable != nil else { return }
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                withAnimation(.easeOut(duration: 0.2)) { undoable = nil }
            }
            .alert("完成这场训练？", isPresented: $finish) {
                Button("继续记录", role: .cancel) { }
                Button("完成并保存") { if let id = record?.id { store.finish(id) } }
            } message: { let p = NativeTraining.progress(session); Text("已完成 \(p.done)/\(p.planned) 工作组，热身 \(p.warmup) 组。未完成的组不会计入记录。") }
            .confirmationDialog(emptyExitCollapses ? "还没有记录任何一组" : "还没有完成任何一组", isPresented: $emptyExit, titleVisibility: .visible) {
                if emptyExitCollapses { Button("收起，稍后继续") { store.workoutPresented = false } }
                Button("放弃这次训练", role: .destructive) { if let id = record?.id { store.finish(id, discard: true) } }
                Button(emptyExitCollapses ? "取消" : "继续记录", role: .cancel) { }
            } message: {
                Text(emptyExitCollapses ? "收起后可以从“继续训练”回来；放弃则不会留下记录。" : "放弃后不会留下空记录。")
            }
            .confirmationDialog("放弃这场训练？", isPresented: $discard, titleVisibility: .visible) { Button("放弃训练", role: .destructive) { if let id = record?.id { store.finish(id, discard: true) } } }
            .sheet(isPresented: $adding) { NavigationStack { NativeExerciseLibrary { exercise in
                mutate { s in s["exercises"] = .array(s["exercises"].array + [NativeTraining.movement(exercise)]) }; store.selectMovement(session["exercises"].array.count - 1); adding = false
            } } }
            .sheet(isPresented: $options) { workoutOptions }
            .sheet(isPresented: $editingMovement) { movementOptions }
            .sheet(isPresented: $reordering) { reorderSheet }
            .sheet(isPresented: $editingNote) {
                NativeSetupNoteEditor(exerciseID: movement["exercise_id"].text, name: movement["name"].text).presentationDetents([.medium])
            }
            .sheet(isPresented: $showExercise) { NavigationStack { NativeExerciseDetail(exercise: catalogExercise).toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showExercise = false } } } } }
            .sheet(item: $editingSet) { selection in NativeSetEditor(sessionID: session.id, selection: selection).presentationDetents([.medium, .large]) }
        }
    }
    private var catalogExercise: JSONValue { store.exercises.first { $0.id == movement["exercise_id"].text } ?? movement }

    /// Sleeps until the rest runs out, then redraws once; skipping or extending restarts it.
    private func watchRest() async {
        clock = Date()
        guard let until = restUntil else { return }
        let wait = until.timeIntervalSince(Date())
        guard wait > 0 else { return }
        do { try await Task.sleep(for: .seconds(wait)) } catch { return }
        clock = Date()
        // Ran out by itself (not skipped): rest_until is still set.
        if restUntil != nil { restFlash += 1 }
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
    @ViewBuilder private var cheerBanner: some View {
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

    // MARK: Content
    @ViewBuilder private var content: some View {
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
                if resting, let until = restUntil { restPanel(until: until).padding(.top, 20).transition(.opacity.combined(with: .scale(scale: 0.97))) }
                else {
                    setPanel.padding(.top, 18).id("set-\(mi)-\(current ?? -1)")
                        .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity))
                        .overlay(alignment: .top) { if flashing { PineRingFlash().padding(.top, 2).transition(.identity) } }
                }
            }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.86), value: "\(mi)-\(current ?? -1)-\(resting)")
    }
    private var movementHeader: some View {
        let note = store.setupNote(movement["exercise_id"].text)
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Menu {
                    // Each move with how far it has got, so moves skipped for a busy machine are easy to find.
                    ForEach(Array(movements.enumerated()), id: \.offset) { index, item in
                        let rows = item["sets"].array
                        let finished = rows.filter { !$0["completed_at"].isNull }.count
                        Button { store.selectMovement(index); lastEdited = nil } label: {
                            let name = item["name"].text
                            Label("\(index + 1). \(name) · \(finished)/\(rows.count)",
                                  systemImage: !rows.isEmpty && finished == rows.count ? "checkmark.circle.fill" : finished > 0 ? "circle.lefthalf.filled" : "circle")
                        }
                    }
                    Divider()
                    Button("调整顺序", systemImage: "arrow.up.arrow.down") { reordering = true }.disabled(movements.count < 2)
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
            if !NativeTraining.mobility(movement) {
                // The lifter's standing setup for this machine, kept across workouts.
                Button { editingNote = true } label: {
                    Label(note.isEmpty ? "添加器械设置备注" : note, systemImage: note.isEmpty ? "plus.circle" : "note.text")
                        .font(.footnote.weight(note.isEmpty ? .regular : .semibold)).foregroundStyle(note.isEmpty ? Color.secondary : pine)
                        .multilineTextAlignment(.leading).frame(minHeight: 32, alignment: .leading)
                }.buttonStyle(.plain).padding(.top, 2)
                    .accessibilityLabel(note.isEmpty ? "添加器械设置备注" : "器械设置备注：" + note + "，点按修改")
            }
            if !previousText.isEmpty { Text(previousText).font(.subheadline).foregroundStyle(.secondary).padding(.top, 2) }
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
        return store.stallCount(exerciseID: movement["exercise_id"].text, loadMode: movement["load_mode"].text,
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
                fillFollowingButton(ci)
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
    /// After a real change to the current set, offers the same values for the open sets
    /// of the same kind below it; it disappears once they match.
    @ViewBuilder private func fillFollowingButton(_ ci: Int) -> some View {
        let targets = followingDifferent(ci)
        if lastEdited == sets[ci].id, !targets.isEmpty {
            Button { fillFollowing(ci) } label: {
                Label("后面 \(targets.count) 组也改成 " + loadText(movement, sets[ci]), systemImage: "arrow.down.to.line")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(pine)
                    .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).overlay(alignment: .top) { Divider() }.transition(.opacity)
                .accessibilityIdentifier("fill-following")
        }
    }
    private func followingDifferent(_ si: Int) -> [Int] {
        guard sets.indices.contains(si) else { return [] }
        let source = sets[si]
        return sets.indices.filter { i in
            i > si && sets[i]["completed_at"].isNull && sets[i]["warmup"].flag == source["warmup"].flag
                && ["weight", "reps", "duration_seconds"].contains { sets[i][$0] != source[$0] }
        }
    }
    private func fillFollowing(_ si: Int) {
        let targets = followingDifferent(si), source = sets[si], index = mi
        guard !targets.isEmpty else { return }
        mutate { s in for i in targets { for key in ["weight", "reps", "duration_seconds"] { s["exercises"][index]["sets"][i][key] = source[key] } } }
    }
    private func otherSets(except ci: Int?) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(sets.enumerated()).filter { $0.offset != ci }, id: \.element.id) { index, row in
                Button { editingSet = SetSelection(id: row.id, movementID: movement.id) } label: {
                    HStack(spacing: 10) {
                        Text(setName(index)).frame(maxWidth: .infinity, alignment: .leading)
                        if row["hard_reps"].integer > 0 { Text("吃力 \(row["hard_reps"].integer)").font(.caption) }
                        Text(loadText(movement, row)).monospacedDigit()
                        Image(systemName: row["completed_at"].isNull ? "circle" : "checkmark").font(.subheadline.weight(.semibold))
                            .foregroundStyle(row["completed_at"].isNull ? Color.secondary.opacity(0.4) : pine).frame(width: 20)
                    }.foregroundStyle(.secondary).padding(.horizontal, 16).frame(minHeight: 48).contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .accessibilityLabel(setName(index) + "，" + loadText(movement, row) + (row["completed_at"].isNull ? "，未完成" : "，已完成"))
                    .accessibilityHint("点按修改数值或完成状态")
                if index != sets.indices.last, !(ci == sets.count - 1 && index == sets.count - 2) { Divider().padding(.leading, 16) }
            }
            Button { appendSet() } label: { Label("添加一组", systemImage: "plus").font(.subheadline).frame(maxWidth: .infinity, minHeight: 44) }
                .disabled(sets.count >= 50).overlay(alignment: .top) { Divider().padding(.leading, 16) }
        }.background(pineSurface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    // MARK: Rest
    /// The countdown, the set just done (to correct it or say how hard it was), the next
    /// set, and the whole list, so nothing waits for the rest to end.
    private func restPanel(until: Date) -> some View {
        let restSet = session["rest_set_id"].text
        let doneIndex = sets.firstIndex(where: { $0.id == restSet }) ?? sets.lastIndex(where: { !$0["completed_at"].isNull })
        let planned = doneIndex.map { sets[$0]["warmup"].flag ? min(60, movement["rest_seconds"].integer) : movement["rest_seconds"].integer } ?? movement["rest_seconds"].integer
        return VStack(spacing: 16) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                restRing(remaining: max(0, until.timeIntervalSince(context.date)), total: Double(max(1, planned)))
            }
            if let doneIndex { justDone(doneIndex) }
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
            otherSets(except: nil)
            Text("锁屏和灵动岛会继续倒计时。").font(.footnote).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity)
    }
    private func restRing(remaining: TimeInterval, total: TimeInterval) -> some View {
        let full = max(remaining, total)
        // The last three seconds turn gold and tick, each with a light tap.
        let second = Int(ceil(remaining)), final = second <= 3
        return ZStack {
            Circle().stroke(pineTrack, lineWidth: 14)
            Circle().trim(from: 0, to: remaining / full).stroke(final ? pineGold : pine, style: StrokeStyle(lineWidth: 14, lineCap: .round)).rotationEffect(.degrees(-90))
                .animation(reduceMotion ? nil : .linear(duration: 1), value: remaining)
                .animation(.easeInOut(duration: 0.3), value: final)
            VStack(spacing: 4) {
                Text("休息").font(.subheadline).foregroundStyle(.secondary)
                Text(WorkoutSnapshot.clock(ceil(remaining))).font(.system(size: 56, weight: .semibold, design: .rounded)).monospacedDigit()
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
        }.frame(width: 210, height: 210)
            .keyframeAnimator(initialValue: 1.0, trigger: extendTick) { ring, scale in ring.scaleEffect(scale) } keyframes: { _ in
                KeyframeTrack {
                    SpringKeyframe(reduceMotion ? 1.0 : 1.06, duration: 0.14)
                    SpringKeyframe(1.0, duration: 0.35)
                }
            }
            .sensoryFeedback(.impact(weight: .light, intensity: 0.8), trigger: second) { _, next in next <= 3 && next > 0 }
            .accessibilityElement(children: .combine).accessibilityLabel("组间休息，剩余 " + WorkoutSnapshot.clock(ceil(remaining)))
    }
    private func justDone(_ di: Int) -> some View {
        let row = sets[di]
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(setName(di) + "完成").font(.footnote).foregroundStyle(.secondary)
                    Text(loadText(movement, row)).font(.title3.weight(.semibold)).monospacedDigit()
                }
                Spacer()
                Button("修改") { editingSet = SetSelection(id: row.id, movementID: movement.id) }.font(.subheadline.weight(.semibold)).frame(minHeight: 44)
                    .accessibilityLabel("修改" + setName(di))
            }
            if !NativeTraining.timed(movement), !NativeTraining.mobility(movement), !row["warmup"].flag { effortChips(di) }
        }.pineCard()
    }
    /// One tap for how the last reps felt, stored as the number of hard final reps.
    private func effortChips(_ si: Int) -> some View {
        let row = sets[si], reps = max(1, row["reps"].integer)
        let picked: Int? = row["hard_reps"].isNull ? nil : min(3, row["hard_reps"].integer)
        let values = [0, 1, 2, 3].filter { $0 <= reps }
        return VStack(alignment: .leading, spacing: 6) {
            Text("最后几次吃力吗？").font(.caption).foregroundStyle(.secondary)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) { ForEach(values, id: \.self) { effortChip($0, si: si, picked: picked) } }
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) { ForEach(Array(values.prefix(2)), id: \.self) { effortChip($0, si: si, picked: picked) } }
                    HStack(spacing: 6) { ForEach(Array(values.dropFirst(2)), id: \.self) { effortChip($0, si: si, picked: picked) } }
                }
            }
        }
    }
    private func effortChip(_ value: Int, si: Int, picked: Int?) -> some View {
        let selected = picked == value
        let title = value == 0 ? "不吃力" : value == 3 ? "3 次以上" : "最后 \(value) 次"
        return Button { setHard(si, selected ? nil : value) } label: {
            Text(title).font(.footnote.weight(.semibold)).lineLimit(1).fixedSize()
                .padding(.horizontal, 12).frame(minHeight: 36)
                .foregroundStyle(selected ? Color.white : pine)
                .background(selected ? pine : pineTint, in: Capsule())
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }
    private func setHard(_ si: Int, _ value: Int?) {
        let index = mi
        mutate { s in
            let reps = s["exercises"][index]["sets"][si]["reps"].integer
            s["exercises"][index]["sets"][si]["hard_reps"] = value.map { JSONValue.number(Double(min($0, max(0, reps)))) } ?? .null
        }
    }
    private func extendRest() {
        extendTick += 1
        mutate { s in
            guard let until = NativeDate.parse(s["rest_until"]) else { return }
            s["rest_until"] = NativeDate.stamp(min(until.addingTimeInterval(30), Date().addingTimeInterval(600)))
        }
    }

    // MARK: Primary action
    private var bottomBar: some View {
        VStack(spacing: 4) {
            if let undo = undoable, let label = undoLabel(undo) {
                Button { undoCompletion(undo) } label: {
                    Label(label, systemImage: "arrow.uturn.backward").font(.subheadline.weight(.semibold)).foregroundStyle(pine).frame(minHeight: 40)
                }.buttonStyle(.plain).transition(.opacity)
            } else if !resting, current == nil || current == 0, mi + 1 < movements.count {
                Button { store.selectMovement(mi + 1); lastEdited = nil } label: {
                    HStack(spacing: 4) { Text("下一个：" + movements[mi + 1]["name"].text); Image(systemName: "chevron.right").font(.caption.weight(.semibold)) }.font(.subheadline).foregroundStyle(.secondary).frame(minHeight: 40)
                }.buttonStyle(.plain)
            }
            primaryButton
        }.padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 4)
            .background(LinearGradient(colors: [pineCanvas.opacity(0), pineCanvas], startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.35)))
    }
    @ViewBuilder private var primaryButton: some View {
        if resting, let ci = current, let until = restUntil {
            // Breathes in the last seconds of rest: time to pick the weight up.
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let final = until.timeIntervalSince(context.date) <= 3
                Button { mutate { $0["rest_until"] = .null; $0["rest_set_id"] = .null } } label: {
                    Text("开始" + setName(ci)).primaryLabel()
                        .phaseAnimator(final && !reduceMotion ? [1.0, 1.035] : [1.0]) { label, scale in
                            label.scaleEffect(scale).shadow(color: pine.opacity(scale > 1 ? 0.35 : 0), radius: 12)
                        } animation: { _ in .easeInOut(duration: 0.5) }
                }.buttonStyle(PinePressStyle(scale: 0.98))
            }
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
        let better = improvement(ci), setID = sets[ci].id, movementID = movement.id, index = mi
        mutate { s in s = try NativeTraining.toggle(s, movement: index, set: ci) }
        if !(session["exercises"][index]["sets"][ci]["completed_at"].isNull) {
            completedTick += 1; lastEdited = nil
            withAnimation(.easeOut(duration: 0.2)) { undoable = SetSelection(id: setID, movementID: movementID) }
            if let better {
                withAnimation(reduceMotion ? nil : .spring(response: 0.45, dampingFraction: 0.7)) { cheer = better }
                cheerTick += 1
            }
        }
    }
    private func undoLabel(_ undo: SetSelection) -> String? {
        guard undo.movementID == movement.id, let si = sets.firstIndex(where: { $0.id == undo.id }), !sets[si]["completed_at"].isNull else { return nil }
        return "撤销" + setName(si)
    }
    /// Unchecks the set just completed and drops its rest, as if the tap never happened.
    private func undoCompletion(_ undo: SetSelection) {
        let index = mi
        guard undo.movementID == movement.id, let si = sets.firstIndex(where: { $0.id == undo.id }), !sets[si]["completed_at"].isNull else { undoable = nil; return }
        mutate { s in s = try NativeTraining.toggle(s, movement: index, set: si) }
        withAnimation(.easeOut(duration: 0.2)) { undoable = nil; cheer = nil }
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

    // MARK: Sheets
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
    /// One sheet for the move: its settings, with technique and replacement pushed inside
    /// it rather than opened as a second sheet.
    private var movementOptions: some View {
        NavigationStack {
            Form {
                Section(movement["name"].text) {
                    Picker("重量单位", selection: Binding(get: { movement["unit"].text }, set: changeUnit)) { Text("磅").tag("lb"); Text("公斤").tag("kg") }
                    HStack { Text("休息 / 秒"); NativeNumberField(label: "休息秒数", value: movement["rest_seconds"], maximum: 600) { value in mutate { $0["exercises"][mi]["rest_seconds"] = value.or(0) } } }
                    Picker("动作感受", selection: Binding(get: { movement["effort"].text }, set: { value in mutate { $0["exercises"][mi]["effort"] = value.isEmpty ? .null : .string(value) } })) { Text("未记录").tag(""); Text("轻松").tag("easy"); Text("适中").tag("normal"); Text("吃力").tag("hard") }
                }
                Section {
                    NavigationLink("动作要领与历史") { NativeExerciseDetail(exercise: catalogExercise) }
                    NavigationLink("替换未完成部分") { NativeExerciseLibrary { exercise in replace(exercise); editingMovement = false } }
                        .disabled(movement["sets"].array.allSatisfy { !$0["completed_at"].isNull })
                }
            }.navigationTitle("动作设置").toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { editingMovement = false } } }
        }
    }
    private var reorderSheet: some View {
        NavigationStack {
            List {
                ForEach(movements, id: \.id) { item in
                    let rows = item["sets"].array
                    let finished = rows.filter { !$0["completed_at"].isNull }.count
                    HStack {
                        Text(item["name"].text)
                        Spacer()
                        Text("\(finished)/\(rows.count) 组").font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
                    }
                }.onMove { from, to in move(from: from, to: to) }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("调整顺序").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { reordering = false } } }
        }
    }
    /// Reorders the moves and keeps the one being recorded selected.
    private func move(from: IndexSet, to: Int) {
        let currentID = movement.id
        mutate { s in var rows = s["exercises"].array; rows.move(fromOffsets: from, toOffset: to); s["exercises"] = .array(rows) }
        if let index = session["exercises"].array.firstIndex(where: { $0.id == currentID }) { store.selectMovement(index) }
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

/// Everything about one set in one sheet: its numbers, how hard it was, warmup, whether
/// it counts as done, and deletion. Changes apply as they are made.
struct NativeSetEditor: View {
    @Environment(NativeStore.self) var store
    @Environment(\.dismiss) private var dismiss
    let sessionID: String
    let selection: SetSelection
    @State private var confirming = false
    private var session: JSONValue { store.recordDocuments[sessionID]?.session ?? .null }
    private var mi: Int? { session["exercises"].array.firstIndex { $0.id == selection.movementID } }
    private var movement: JSONValue { mi.map { session["exercises"][$0] } ?? .null }
    private var si: Int? { movement["sets"].array.firstIndex { $0.id == selection.id } }
    private var row: JSONValue { si.map { movement["sets"][$0] } ?? .null }
    private var paused: Bool { !session["paused_at"].isNull }
    private var title: String {
        guard let si else { return "组次" }
        if row["warmup"].flag { return "热身组" }
        return "第 \(movement["sets"].array.prefix(si + 1).filter { !$0["warmup"].flag }.count) 组"
    }
    var body: some View {
        NavigationStack {
            Form {
                if row.isNull {
                    Text("这组记录已经不在了。").foregroundStyle(.secondary)
                } else {
                    let timed = NativeTraining.timed(movement)
                    Section {
                        if movement["load_mode"].text != "bodyweight", !timed {
                            HStack { Text("重量 / " + unitLabel(movement)); Spacer(); NativeNumberField(label: "重量", value: row["weight"], decimal: true) { assign("weight", $0) }.frame(width: 120) }
                        }
                        HStack { Text(timed ? "秒数" : "次数"); Spacer(); NativeNumberField(label: timed ? "秒数" : "次数", value: row[timed ? "duration_seconds" : "reps"], maximum: timed ? 3600 : 1000, minimum: 1) { assign(timed ? "duration_seconds" : "reps", $0) }.frame(width: 120) }
                    } header: { Text(movement["name"].text) }
                    if !timed, !NativeTraining.mobility(movement) {
                        Section {
                            HStack { Text("最后几次明显吃力"); Spacer(); NativeNumberField(label: "吃力次数", value: row["hard_reps"], maximum: Double(max(0, row["reps"].integer))) { assign("hard_reps", $0) }.frame(width: 120) }
                        } footer: { Text("填 0 表示没有明显吃力，留空不记录。") }
                    }
                    Section { Toggle("热身组", isOn: Binding(get: { row["warmup"].flag }, set: { value in assign("warmup", .bool(value)) })) }
                    Section {
                        Button(row["completed_at"].isNull ? "标记为已完成" : "标记为未完成", systemImage: row["completed_at"].isNull ? "checkmark.circle" : "arrow.uturn.backward") { toggle() }
                            .disabled(paused || (row["completed_at"].isNull && !NativeTraining.valid(movement, row)))
                        Button("删除本组", role: .destructive) { confirming = true }
                    } footer: { if paused { Text("训练已暂停，继续训练后才能更改完成状态。") } }
                }
            }
            .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .confirmationDialog("删除这组实际记录？", isPresented: $confirming, titleVisibility: .visible) { Button("确认删除本组", role: .destructive) { remove() } } message: { Text(movement["sets"].array.count == 1 ? "这是最后一组，删除后也会移除此动作。" : "已完成的组也会从本次记录中移除。") }
        }
    }
    private func assign(_ key: String, _ value: JSONValue) {
        guard let mi, let si else { return }
        store.update(sessionID) { s in
            s["exercises"][mi]["sets"][si][key] = value
            let entry = s["exercises"][mi]["sets"][si]
            if key == "reps", !entry["hard_reps"].isNull, entry["hard_reps"].integer > value.integer { s["exercises"][mi]["sets"][si]["hard_reps"] = .null }
            // A value that no longer makes a valid set takes the set out of the record.
            if !NativeTraining.valid(s["exercises"][mi], s["exercises"][mi]["sets"][si]) {
                s["exercises"][mi]["sets"][si]["completed_at"] = .null
                if s["rest_set_id"] == s["exercises"][mi]["sets"][si]["id"] { s["rest_set_id"] = .null; s["rest_until"] = .null }
            }
        }
    }
    private func toggle() {
        guard let mi, let si else { return }
        store.update(sessionID) { s in s = try NativeTraining.toggle(s, movement: mi, set: si) }
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

/// The lifter's standing note for one exercise, such as a seat setting or grip width.
struct NativeSetupNoteEditor: View {
    @Environment(NativeStore.self) var store
    @Environment(\.dismiss) private var dismiss
    let exerciseID: String
    let name: String
    @State private var text = ""
    @State private var busy = false
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("例如：座椅第 4 档，握把最宽处", text: $text, axis: .vertical).lineLimit(2...4)
                } header: { Text(name) } footer: { Text("每次做这个动作，都会显示在动作名下方。最多 200 字，清空即删除。") }
                if let error { Section { Text(error).foregroundStyle(.red) } }
            }
            .navigationTitle("器械设置备注").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("保存") { save() }.disabled(busy || text.count > 200 || store.isDesignPreview) }
            }
            .onAppear { text = store.setupNote(exerciseID) }
        }
    }
    private func save() {
        busy = true; error = nil
        Task {
            do { try await store.saveSetupNote(exerciseID, note: text); dismiss() }
            catch { self.error = error.localizedDescription }
            busy = false
        }
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

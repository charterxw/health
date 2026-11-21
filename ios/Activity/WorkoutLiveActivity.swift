import ActivityKit
import SwiftUI
import WidgetKit

// The home-screen widget needs an App Group, which free sideloading does not
// provision; it is only in builds made with the app_group input (PINE_WIDGET).
@main
struct HealthWorkoutWidgets: WidgetBundle {
    var body: some Widget {
        WorkoutLiveActivity()
        #if PINE_WIDGET
        PineTodayWidget()
        #endif
    }
}

struct WorkoutLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: WorkoutAttributes.self) { context in
            let info = ActivityDisplay(workout: context.state.workout, stale: context.isStale)
            WorkoutCard(info: info)
                .widgetURL(HealthRoute.deepLink(context.attributes.sessionID))
                .activitySystemActionForegroundColor(info.tint)
        } dynamicIsland: { context in
            let info = ActivityDisplay(workout: context.state.workout, stale: context.isStale)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(info.islandLabel, systemImage: info.symbol)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(info.tint)
                        .lineLimit(1)
                        .padding(.leading, 5)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    ActivityClock(info: info)
                        .font(.title3.weight(.semibold))
                        .padding(.trailing, 5)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        if info.isRest, let next = info.workout.nextSet {
                            Text("下一组 · " + next).font(.subheadline.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.8)
                        }
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(info.workout.movementName).font(.headline).lineLimit(1)
                            Spacer(minLength: 0)
                            Text(info.setCount).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                                .monospacedDigit().fixedSize()
                        }
                        WorkoutProgress(info: info)
                    }
                    .padding(.horizontal, 9)
                    .padding(.bottom, 4)
                    .accessibilityElement(children: .combine)
                }
            } compactLeading: {
                Image(systemName: info.symbol).foregroundStyle(info.tint)
                    .accessibilityLabel(info.label)
            } compactTrailing: {
                ActivityClock(info: info)
                    .font(.caption.weight(.semibold))
                    .frame(maxWidth: 49, alignment: .trailing)
            } minimal: {
                Image(systemName: info.symbol).foregroundStyle(info.tint)
                    .accessibilityLabel(info.label)
            }
            .widgetURL(HealthRoute.deepLink(context.attributes.sessionID))
            .keylineTint(info.tint)
        }
    }
}

private struct ActivityDisplay {
    let workout: WorkoutSnapshot
    let phase: WorkoutSnapshot.ActivityPhase

    init(workout: WorkoutSnapshot, stale: Bool) {
        self.workout = workout
        self.phase = workout.activityPhase(stale: stale)
    }

    var isRest: Bool { phase == .resting || phase == .pausedRest }
    var tint: Color {
        switch phase {
        case .resting, .pausedRest: return .orange
        case .restFinished: return .green
        case .paused, .stale: return .secondary
        case .training: return .blue
        }
    }
    var symbol: String {
        switch phase {
        case .resting: return "timer"
        case .paused, .pausedRest: return "pause.fill"
        case .restFinished: return "checkmark"
        case .stale: return "arrow.clockwise"
        case .training: return "dumbbell.fill"
        }
    }
    var label: String {
        switch phase {
        case .resting: return "组间休息"
        case .pausedRest: return "休息已暂停"
        case .paused: return "训练已暂停"
        case .restFinished: return "休息结束"
        case .stale: return "打开以更新"
        case .training: return "训练中"
        }
    }
    var setCount: String { "\(workout.completedSets)/\(workout.plannedSets) 组" }
    var islandLabel: String {
        switch phase {
        case .resting: return "休息"
        case .restFinished: return "下一组"
        case .paused, .pausedRest: return "已暂停"
        case .stale: return "待更新"
        case .training: return "训练"
        }
    }
}

private struct WorkoutCard: View {
    let info: ActivityDisplay

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label(info.label, systemImage: info.symbol)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(info.tint)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(info.workout.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 5) {
                    if info.isRest, let next = info.workout.nextSet {
                        Text("下一组").font(.caption2.weight(.semibold)).foregroundStyle(info.tint)
                        Text(next).font(.headline).lineLimit(1).minimumScaleFactor(0.8)
                    } else {
                        Text(info.workout.movementName).font(.headline).lineLimit(1)
                    }
                    Text(info.workout.movementSetCount > 0
                         ? "第 \(info.workout.currentSet)/\(info.workout.movementSetCount) 组 · 共完成 \(info.setCount)"
                         : "共完成 \(info.setCount)")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 2) {
                    ActivityClock(info: info).font(.system(.title, design: .rounded, weight: .semibold))
                    Text(info.isRest ? "休息剩余" : "训练用时").font(.caption2).foregroundStyle(.secondary)
                }
            }
            WorkoutProgress(info: info)
        }
        .padding(15)
        .accessibilityElement(children: .combine)
    }
}

private struct WorkoutProgress: View {
    let info: ActivityDisplay

    var body: some View {
        if info.workout.plannedSets > 0 {
            ProgressView(value: Double(info.workout.completedSets), total: Double(info.workout.plannedSets))
                .tint(info.tint)
                .accessibilityLabel("训练进度")
                .accessibilityValue(info.setCount)
        }
    }
}

private struct ActivityClock: View {
    let info: ActivityDisplay

    var body: some View {
        Group {
            if info.phase == .pausedRest {
                Text(WorkoutSnapshot.clock(info.workout.restRemaining()))
            } else if info.phase == .resting, let end = info.workout.restUntil {
                Text(timerInterval: info.workout.startedAt...max(end, info.workout.startedAt), countsDown: true, showsHours: false)
            } else if info.workout.pausedAt != nil {
                Text(WorkoutSnapshot.clock(info.workout.elapsed()))
            } else if info.phase == .stale {
                Text("—")
            } else {
                Text(info.workout.effectiveStartedAt, style: .timer)
            }
        }
        .monospacedDigit()
        .lineLimit(1)
        .minimumScaleFactor(0.75)
        .multilineTextAlignment(.trailing)
        .foregroundStyle(info.isRest ? info.tint : .primary)
        .accessibilityHint(info.isRest ? "休息剩余时间" : "训练用时")
    }
}

// MARK: Home-screen widget

private let widgetPine = Color(red: 0x2F / 255, green: 0x6B / 255, blue: 0x4C / 255)
private let widgetPineDark = Color(red: 0x7C / 255, green: 0xC4 / 255, blue: 0x9C / 255)

struct PineTodayEntry: TimelineEntry {
    let date: Date
    let snapshot: PineWidgetSnapshot?
}

struct PineTodayProvider: TimelineProvider {
    func placeholder(in context: Context) -> PineTodayEntry {
        PineTodayEntry(date: .now, snapshot: PineWidgetSnapshot(date: "", activity: 0.6, halves: [1, 0.5], posture: false, next: "A · 公司", detail: "肩宽 · 三头"))
    }
    func getSnapshot(in context: Context, completion: @escaping (PineTodayEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : PineTodayEntry(date: .now, snapshot: PineWidgetStore.read()))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<PineTodayEntry>) -> Void) {
        // The app reloads the widget when its data changes; this is a fallback.
        completion(Timeline(entries: [PineTodayEntry(date: .now, snapshot: PineWidgetStore.read())], policy: .after(.now.addingTimeInterval(1800))))
    }
}

/// The app's three-ring glyph, redrawn for the widget process.
private struct WidgetGlyph: View {
    let snapshot: PineWidgetSnapshot
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        GeometryReader { proxy in
            let unit = min(proxy.size.width, proxy.size.height) / 88
            let ink = scheme == .dark ? widgetPineDark : widgetPine
            let track = ink.opacity(0.18)
            ZStack {
                Circle().stroke(track, lineWidth: 8 * unit).frame(width: 72 * unit, height: 72 * unit)
                Circle().trim(from: 0, to: min(1, snapshot.activity ?? 0)).stroke(ink, style: StrokeStyle(lineWidth: 8 * unit, lineCap: .round))
                    .rotationEffect(.degrees(-90)).frame(width: 72 * unit, height: 72 * unit)
                Circle().stroke(track, lineWidth: 7 * unit).frame(width: 42 * unit, height: 42 * unit)
                ForEach(0..<min(2, snapshot.halves.count), id: \.self) { index in
                    Circle().trim(from: 0.25, to: 0.25 + 0.5 * min(1, snapshot.halves[index]))
                        .stroke(ink, style: StrokeStyle(lineWidth: 7 * unit, lineCap: .butt))
                        .rotationEffect(.degrees(index == 0 ? 0 : 180)).frame(width: 42 * unit, height: 42 * unit)
                }
                Circle().fill(snapshot.posture ? ink : track).frame(width: 18 * unit, height: 18 * unit)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct PineTodayWidgetView: View {
    let entry: PineTodayEntry
    @Environment(\.widgetFamily) private var family
    var body: some View {
        Group {
            if let snapshot = entry.snapshot {
                switch family {
                case .accessoryCircular:
                    WidgetGlyph(snapshot: snapshot).padding(2)
                case .systemMedium:
                    HStack(spacing: 16) {
                        WidgetGlyph(snapshot: snapshot).frame(width: 110)
                        VStack(alignment: .leading, spacing: 6) {
                            goal("活动", done: (snapshot.activity ?? 0) >= 1, value: snapshot.activity.map { "\(Int(($0 * 100).rounded()))%" } ?? "—")
                            goal("力量", done: snapshot.halves.count >= 2 && snapshot.halves.prefix(2).allSatisfy { $0 >= 1 }, value: snapshot.halves.isEmpty ? "休息" : "\(snapshot.halves.filter { $0 >= 1 }.count)/\(max(snapshot.halves.count, 1))")
                            goal("体态", done: snapshot.posture, value: snapshot.posture ? "已做" : "待做")
                            Spacer(minLength: 0)
                            Text("下一次 · " + snapshot.next).font(.caption.weight(.semibold)).lineLimit(1)
                        }
                    }
                default:
                    VStack(alignment: .leading, spacing: 6) {
                        WidgetGlyph(snapshot: snapshot).frame(height: 84)
                        Text(snapshot.next).font(.caption.weight(.semibold)).lineLimit(1)
                        Text(snapshot.detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "figure.strengthtraining.traditional").font(.title2)
                    Text("打开 Pine 查看").font(.caption)
                }.foregroundStyle(.secondary)
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
        .widgetURL(URL(string: "healthfp://today"))
    }
    private func goal(_ title: String, done: Bool, value: String) -> some View {
        HStack {
            Text(title).font(.subheadline.weight(.semibold))
            Spacer()
            Text(value).font(.subheadline).monospacedDigit().foregroundStyle(done ? widgetPine : .secondary)
            if done { Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(widgetPine) }
        }
    }
}

struct PineTodayWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "PineToday", provider: PineTodayProvider()) { entry in PineTodayWidgetView(entry: entry) }
            .configurationDisplayName("Pine 今日")
            .description("今天的三项目标和下一次训练。")
            .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular])
    }
}

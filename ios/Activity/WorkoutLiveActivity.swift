import ActivityKit
import SwiftUI
import WidgetKit

@main
struct HealthWorkoutWidgets: WidgetBundle {
    var body: some Widget { WorkoutLiveActivity() }
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
                    Text(info.workout.movementName).font(.headline).lineLimit(1)
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

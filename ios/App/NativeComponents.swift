import SwiftUI
import UIKit
import Charts

/// One brand hue for actions, selection and completion. Differences between
/// goals are carried by shape and position, never by extra hues.
private func pineDynamic(_ light: UInt32, _ dark: UInt32) -> Color {
    func color(_ hex: UInt32) -> UIColor {
        UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
    return Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? color(dark) : color(light) })
}
let pine = pineDynamic(0x2F6B4C, 0x7CC49C)
/// Unfilled parts of a goal glyph.
let pineTrack = pineDynamic(0xE1E8E3, 0x2C3631)
/// Future days: drawn but clearly not yet due.
let pineFaint = pineDynamic(0xEEF0EE, 0x1E2420)
/// Selected-day and selected-row backgrounds.
let pineTint = pineDynamic(0xEEF3EF, 0x1F2B24)
let pineCanvas = pineDynamic(0xF4F5F1, 0x000000)
let pineSurface = pineDynamic(0xFFFFFF, 0x1A1D1B)
/// Warm gold, only for celebrations (sparks, records, the round's medal).
let pineGold = pineDynamic(0xC8962E, 0xE6BC5C)
let activityColor = pine
let strengthColor = pine
let postureColor = pine

/// The day's three goals in one mark: outer ring = daily activity (continuous),
/// middle ring = the day's two strength sessions as left and right halves that
/// join into one full circle, centre dot = posture practice.
struct PineDayGlyph: View {
    var activity: Double?
    var halves: [Double] = []
    var posture = false
    var future = false
    var size: CGFloat = 36
    /// Draw in from empty the first time it appears (rings sweep, the dot pops);
    /// `delay` staggers a row of glyphs.
    var animated = false
    var delay: Double = 0
    @State private var shown = false
    @PineReducedMotion private var reduceMotion
    var body: some View {
        let unit = size / 88
        let base = future ? pineFaint : pineTrack
        let grow: Double = !animated || shown || reduceMotion ? 1 : 0
        ZStack {
            Circle().stroke(base, lineWidth: 8 * unit).frame(width: 72 * unit, height: 72 * unit)
            if !future, let activity, activity > 0 {
                Circle().trim(from: 0, to: min(1, activity) * grow)
                    .stroke(pine, style: StrokeStyle(lineWidth: 8 * unit, lineCap: .round))
                    .rotationEffect(.degrees(-90)).frame(width: 72 * unit, height: 72 * unit)
                if activity > 1 && grow > 0 {
                    // Past the goal the ring keeps going over itself (up to a second
                    // lap). The leading tip gets a thin cut in the card colour so the
                    // second lap reads as lying on top of the first.
                    let end = min(1, activity - 1)
                    let angle = Angle.degrees(end * 360 - 90), radius = 36 * unit
                    Circle().trim(from: 0, to: end)
                        .stroke(pine, style: StrokeStyle(lineWidth: 8 * unit, lineCap: .round))
                        .rotationEffect(.degrees(-90)).frame(width: 72 * unit, height: 72 * unit)
                    Circle().fill(pine).frame(width: 8 * unit, height: 8 * unit)
                        .overlay { Circle().trim(from: 0, to: 0.5).stroke(pineSurface, lineWidth: max(1, 1.4 * unit)).rotationEffect(angle) }
                        .offset(x: radius * CGFloat(cos(angle.radians)), y: radius * CGFloat(sin(angle.radians)))
                }
            }
            Circle().stroke(base, lineWidth: 7 * unit).frame(width: 42 * unit, height: 42 * unit)
            ForEach(0..<min(2, halves.count), id: \.self) { index in
                if !future, halves[index] > 0 {
                    // Left half fills bottom→top, right half top→bottom; butt caps so
                    // two complete halves meet as one seamless circle.
                    Circle().trim(from: 0.25, to: 0.25 + 0.5 * min(1, halves[index]) * grow)
                        .stroke(pine, style: StrokeStyle(lineWidth: 7 * unit, lineCap: .butt))
                        .rotationEffect(.degrees(index == 0 ? 0 : 180)).frame(width: 42 * unit, height: 42 * unit)
                }
            }
            Circle().fill(!future && posture ? pine : base).frame(width: 18 * unit, height: 18 * unit)
                .scaleEffect(!future && posture ? 0.3 + 0.7 * grow : 1)
        }
        .frame(width: size, height: size)
        // New data (a sync, a finished set) sweeps instead of jumping.
        .animation(reduceMotion ? nil : .spring(response: 0.6, dampingFraction: 0.85), value: activity)
        .animation(reduceMotion ? nil : .spring(response: 0.6, dampingFraction: 0.85), value: halves)
        .animation(reduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.6), value: posture)
        .onAppear {
            guard animated, !shown, !reduceMotion else { return }
            withAnimation(.spring(response: 0.8, dampingFraction: 0.85).delay(delay)) { shown = true }
        }
        .accessibilityHidden(true)
    }
}

/// Celebration haptics: a short "da — da-da" for one goal, a longer roll ending
/// in a success tap for the big moments. No sound.
@MainActor enum PineHaptics {
    static func celebrate(big: Bool) {
        let tap = UIImpactFeedbackGenerator(style: big ? .heavy : .medium)
        tap.prepare()
        let beats: [Double] = big ? [0, 0.16, 0.26, 0.48, 0.58, 0.68] : [0, 0.2, 0.3]
        for (index, time) in beats.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + time) { tap.impactOccurred(intensity: index == 0 ? 1 : 0.75) }
        }
        if big { DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { UINotificationFeedbackGenerator().notificationOccurred(.success) } }
    }
}

/// Sparks bursting out from the centre once, in pine and gold, then gone.
struct PineSparkBurst: View {
    var radius: CGFloat = 90
    var count = 28
    var duration: Double = 0.9
    @State private var start = Date()
    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSince(start) / duration
            Canvas { canvas, size in
                guard t < 1 else { return }
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let ease = 1 - pow(1 - t, 3)
                for i in 0..<count {
                    // Fixed pseudo-random spread so every burst looks the same.
                    let jitter = Double((i * 7919) % 97) / 97
                    let angle = Double(i) / Double(count) * 2 * .pi + jitter * 0.35
                    let distance = radius * ease * (0.55 + 0.45 * jitter)
                    let dot = (i % 3 == 0 ? 2.5 : 3.5) * (1 - 0.6 * t)
                    let point = CGPoint(x: center.x + CGFloat(cos(angle) * distance), y: center.y + CGFloat(sin(angle) * distance))
                    let rect = CGRect(x: point.x - dot, y: point.y - dot, width: dot * 2, height: dot * 2)
                    canvas.fill(Path(ellipseIn: rect), with: .color((i % 2 == 0 ? pineGold : pine).opacity(1 - t)))
                }
            }
        }
        .allowsHitTesting(false).accessibilityHidden(true)
        .onAppear { start = Date() }
    }
}

extension View {
    /// iOS 18 zoom transitions from a row into its detail; plain push before.
    @ViewBuilder func pineZoomSource(_ id: String, in space: Namespace.ID) -> some View {
        if #available(iOS 18.0, *) { matchedTransitionSource(id: id, in: space) } else { self }
    }
    @ViewBuilder func pineZoomDestination(_ id: String, in space: Namespace.ID) -> some View {
        if #available(iOS 18.0, *) { navigationTransition(.zoom(sourceID: id, in: space)) } else { self }
    }
}

/// Expands the server's one-character plan tags for display.
func planLabel(_ short: String) -> String {
    ["家": "家庭", "腹": "腹部和腿", "上": "上胸", "胸": "胸部", "肩": "肩宽", "背": "背宽", "选": "选练", "休": "休息", "练": "训练"][short] ?? short
}

private struct PinePreviewReduceMotionKey: EnvironmentKey {
    static let defaultValue = false
}
extension EnvironmentValues {
    var pinePreviewReduceMotion: Bool {
        get { self[PinePreviewReduceMotionKey.self] }
        set { self[PinePreviewReduceMotionKey.self] = newValue }
    }
}
/// System preference in production; a simulator-only fixture can also exercise
/// the same policy without changing the user's simulator accessibility setting.
@propertyWrapper
struct PineReducedMotion: DynamicProperty {
    @Environment(\.accessibilityReduceMotion) private var system
    @Environment(\.pinePreviewReduceMotion) private var preview
    var wrappedValue: Bool { system || preview }
}

extension View {
    func pineCard() -> some View { padding(16).frame(maxWidth: .infinity, alignment: .leading).background(pineSurface, in: RoundedRectangle(cornerRadius: 20, style: .continuous)) }
}
/// Shared type scale for list rows on all three tabs: rows read at 16 pt with
/// 13 pt details, section titles at title3 and the tab title at 30 pt.
extension Font {
    static let pineRow = Font.callout
    static let pineDetail = Font.footnote
}
struct PinePage<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View { ScrollView { LazyVStack(alignment: .leading, spacing: 16) { content }.padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 24) }.frame(maxWidth: .infinity).background(pineCanvas).scrollDismissesKeyboard(.interactively) }
}
struct PineHeading: View {
    let title: String
    var subtitle: String = ""
    var body: some View { VStack(alignment: .leading, spacing: 6) { Text(title).font(.headline); if !subtitle.isEmpty { Text(subtitle).font(.subheadline).foregroundStyle(.secondary) } } }
}
struct PineEmpty: View {
    let title: String
    var symbol = "tray"
    var detail = ""
    var body: some View { ContentUnavailableView(title, systemImage: symbol, description: Text(detail)).frame(maxWidth: .infinity).padding(.vertical, 30) }
}
struct PineRow: View {
    let label: String
    let value: String
    var body: some View { HStack(alignment: .firstTextBaseline) { Text(label).foregroundStyle(.secondary); Spacer(minLength: 16); Text(value).multilineTextAlignment(.trailing) }.font(.subheadline).padding(.vertical, 5) }
}
struct PineBanner: View {
    let text: String
    var body: some View { Label(text, systemImage: "exclamationmark.circle").font(.footnote).foregroundStyle(.secondary).padding(14).frame(maxWidth: .infinity, alignment: .leading).background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 14)).accessibilityIdentifier("status-message") }
}
/// Local feedback only: it never gates the action, starts a task, or animates a
/// page's arrival. Reduce Motion preserves contrast feedback without scaling.
struct PinePressStyle: ButtonStyle {
    @PineReducedMotion private var reduceMotion
    var scale: CGFloat = 0.985
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? scale : 1)
            .opacity(configuration.isPressed ? 0.78 : 1)
            .animation(.easeOut(duration: configuration.isPressed ? 0.10 : 0.14), value: configuration.isPressed)
    }
}
struct PineRing: View {
    let fraction: Double?
    let color: Color
    var width: CGFloat = 7
    var body: some View {
        ZStack {
            Circle().stroke(Color(uiColor: .systemGray5), lineWidth: width)
            if let fraction { Circle().trim(from: 0, to: min(1, max(0, fraction))).stroke(color, style: StrokeStyle(lineWidth: width, lineCap: .round)).rotationEffect(.degrees(-90)) }
        }.accessibilityHidden(true)
    }
}
struct NativeMetricNumber: View {
    let value: JSONValue
    var unit = ""
    @PineReducedMotion private var reduceMotion
    @ScaledMetric(relativeTo: .largeTitle) private var size: CGFloat = 34
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(displayNumber(value, digits: 0))
                .font(.system(size: size, weight: .semibold)).monospacedDigit()
                .contentTransition(reduceMotion ? .identity : .numericText(value: value.number ?? 0))
                .animation(reduceMotion ? nil : .easeOut(duration: 0.20), value: value.number)
            if !unit.isEmpty { Text(unit).font(.subheadline).foregroundStyle(.secondary).fixedSize() }
        }.accessibilityElement(children: .combine)
    }
}
struct NativeSectionTitle: View {
    let title: String
    var detail = ""
    var body: some View { HStack { Text(title).font(.title3.bold()); Spacer(); if !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(.secondary) } } }
}
func dayTitle(_ key: String, format: String = "M月d日 EEEE") -> String {
    NativeDate.dayLabel(key, format: format)
}
func clockLabel(_ value: JSONValue, timezone: String = "America/New_York") -> String {
    guard let date = NativeDate.parse(value) else { return "—" }
    return NativeDate.label(date, format: "HH:mm", timezone: timezone)
}
func sleepDuration(_ value: JSONValue) -> String {
    guard let minutes = value.number, minutes >= 0 else { return "—" }
    let total = Int(minutes.rounded()); return total >= 60 ? "\(total / 60) 小时 \(total % 60) 分" : "\(total) 分钟"
}
struct NativeNumberField: View {
    let label: String
    let value: JSONValue
    var maximum: Double = 2000
    var decimal = false
    var minimum: Double = 0
    let onValue: (JSONValue) -> Void
    var body: some View {
        SelectNumberInput(label: label, value: value, maximum: maximum, decimal: decimal, minimum: minimum, onValue: onValue)
            .frame(minWidth: 52, minHeight: 44)
    }
}
private struct SelectNumberInput: UIViewRepresentable {
    let label: String
    let value: JSONValue
    let maximum: Double
    let decimal: Bool
    let minimum: Double
    let onValue: (JSONValue) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> UITextField {
        let field = UITextField(); field.borderStyle = .roundedRect; field.textAlignment = .center
        field.font = .preferredFont(forTextStyle: .body); field.adjustsFontForContentSizeCategory = true
        field.keyboardType = decimal ? .decimalPad : .numberPad; field.delegate = context.coordinator
        field.setContentHuggingPriority(.defaultLow, for: .horizontal); field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
        let bar = UIToolbar(); bar.sizeToFit(); bar.items = [UIBarButtonItem(systemItem: .flexibleSpace), UIBarButtonItem(title: "完成", style: .done, target: context.coordinator, action: #selector(Coordinator.done))]
        field.inputAccessoryView = bar; context.coordinator.field = field; return field
    }
    func updateUIView(_ field: UITextField, context: Context) {
        context.coordinator.parent = self; field.accessibilityLabel = label
        if !field.isFirstResponder { field.text = value.number.map { $0.formatted(.number.grouping(.never).precision(.fractionLength(0...2)).locale(Locale(identifier: "en_US_POSIX"))) } ?? "" }
    }
    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: SelectNumberInput
        weak var field: UITextField?
        init(_ parent: SelectNumberInput) { self.parent = parent }
        func textFieldDidBeginEditing(_ textField: UITextField) { DispatchQueue.main.async { textField.selectAll(nil) } }
        func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
            guard let r = Range(range, in: textField.text ?? "") else { return false }
            let value = (textField.text ?? "").replacingCharacters(in: r, with: string).replacingOccurrences(of: ",", with: ".")
            if value.isEmpty || parent.decimal && value == "." { return true }
            guard let n = Double(value), n.isFinite, n >= parent.minimum, n <= parent.maximum,
                  value.allSatisfy({ $0.isNumber || parent.decimal && $0 == "." }), parent.decimal || n.rounded() == n else { return false }
            return true
        }
        @objc func changed(_ field: UITextField) {
            let text = (field.text ?? "").replacingOccurrences(of: ",", with: ".")
            parent.onValue(.value(Double(text)))
        }
        @objc func done() { field?.resignFirstResponder() }
    }
}

func healthValue(_ value: JSONValue, key: String) -> JSONValue {
    if ["sleep_hours", "hrv", "resting_hr"].contains(key), (value.number ?? 0) <= 0 { return .null }; return value
}
func numberText(_ value: JSONValue, digits: Int = 2) -> String {
    guard let n = value.number, n.isFinite else { return value.text.isEmpty ? "" : value.text }
    return n.formatted(.number.precision(.fractionLength(0...digits)))
}
func displayNumber(_ value: JSONValue, digits: Int = 1) -> String { value.isNull ? "—" : numberText(value, digits: digits) }
func dateLabel(_ value: JSONValue) -> String {
    if let d = NativeDate.parse(value) { return d.formatted(.dateTime.month().day().hour().minute()) }; return value.text
}
func unitLabel(_ m: JSONValue) -> String { m["unit"].text == "kg" ? "公斤" : "磅" }
func loadText(_ m: JSONValue, _ s: JSONValue) -> String {
    if NativeTraining.timed(m) { return displayNumber(s["duration_seconds"]) + " 秒" }
    let load = m["load_mode"].text == "bodyweight" ? "自重" : (m["load_mode"].text == "assistance" ? "辅助 " : "") + displayNumber(s["weight"]) + " " + unitLabel(m)
    return load + " × " + displayNumber(s["reps"]) + " 次"
}
struct MetricChart: View {
    let rows: [JSONValue]
    let key: String
    var color: Color = pine
    var body: some View {
        let points = rows.filter { healthValue($0[key], key: key).number != nil }
        if points.isEmpty { Text("这段时间暂无数据").foregroundStyle(.secondary).padding(.vertical, 32) }
        else {
            Chart(Array(rows.enumerated()), id: \.offset) { _, row in
                if let value = healthValue(row[key], key: key).number {
                    BarMark(x: .value("日期", String(row["date"].text.suffix(5))), y: .value("数值", value)).foregroundStyle(color.gradient).cornerRadius(3)
                }
            }.chartXAxis { AxisMarks(values: .automatic(desiredCount: 5)) }.frame(height: 190)
            Text("空白日期表示没有记录。").font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct NativeLoginView: View {
    @Environment(NativeStore.self) var store
    @State private var username = ""
    @State private var password = ""
    @State private var busy = false
    @State private var error: String?
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    VStack(alignment: .leading, spacing: 12) {
                        PineDayGlyph(activity: 1, halves: [1, 0], posture: true, size: 64).padding(.bottom, 14)
                        Text("Pine").font(.system(size: 40, weight: .semibold))
                        Text("留意身体，\n按自己的节奏训练。").font(.title2).foregroundStyle(.secondary)
                    }.padding(.top, 48)
                    VStack(spacing: 16) {
                        TextField("用户名", text: $username).textContentType(.username).textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("login-username")
                        Divider()
                        SecureField("密码", text: $password).textContentType(.password).accessibilityIdentifier("login-password")
                    }.padding(20).background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
                    if let error { PineBanner(text: error) }
                    Button { signIn() } label: { HStack { Spacer(); if busy { ProgressView().tint(.white) }; Text(busy ? "正在登录" : "登录").font(.headline); Spacer() }.padding(.vertical, 9) }
                        .buttonStyle(.borderedProminent).disabled(username.trimmingCharacters(in: .whitespaces).isEmpty || password.isEmpty || busy).accessibilityIdentifier("login-submit")
                    Text("使用现有健康服务器账号，继续查看健康数据和训练记录。").font(.footnote).foregroundStyle(.secondary)
                }.padding(28).frame(maxWidth: 520)
            }.frame(maxWidth: .infinity).background(Color(uiColor: .systemGroupedBackground))
        }
    }
    private func signIn() {
        busy = true; error = nil
        Task {
            do { try await store.login(username.trimmingCharacters(in: .whitespaces), password: password); password = "" }
            catch { self.error = (error as? HealthAPIError)?.status == 401 ? "用户名或密码不正确。" : error.localizedDescription }
            busy = false
        }
    }
}

/// Shared top of the three tab roots: same title size, height and action style on
/// every tab, instead of the system bar whose large/inline title varies by page.
struct PineSettle { var scale = 1.0; var lift = 0.0 }
struct PineTabHeader<Actions: View>: View {
    @Environment(NativeStore.self) var store
    @PineReducedMotion private var reduceMotion
    let title: String
    @ViewBuilder var actions: Actions
    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(title).font(.system(size: 30, weight: .bold)).lineLimit(1).minimumScaleFactor(0.8)
                .accessibilityAddTraits(.isHeader)
                // Switching tabs: the new page's title settles in with a small bounce.
                .keyframeAnimator(initialValue: PineSettle(), trigger: store.selectedTab) { text, value in
                    text.scaleEffect(value.scale, anchor: .leading).offset(y: value.lift)
                } keyframes: { _ in
                    KeyframeTrack(\.scale) { CubicKeyframe(reduceMotion ? 1 : 0.94, duration: 0.01); SpringKeyframe(1.0, duration: 0.45, spring: .bouncy) }
                    KeyframeTrack(\.lift) { CubicKeyframe(reduceMotion ? 0 : 6, duration: 0.01); SpringKeyframe(0, duration: 0.45, spring: .bouncy) }
                }
            Spacer(minLength: 8)
            if store.active != nil {
                Button { store.workoutSource = "resume-" + title; store.workoutPresented = true } label: {
                    Label("继续训练", systemImage: "play.fill").font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 14).frame(height: 36).background(pine, in: Capsule())
                        .pineWorkoutSource("resume-" + title)
                }.buttonStyle(PinePressStyle()).frame(minHeight: 44)
            }
            actions
            PineCircleButton(title: "设置", systemImage: "gearshape") { store.showingSettings = true }
        }.frame(minHeight: 44)
    }
}
extension PineTabHeader where Actions == EmptyView {
    init(title: String) { self.init(title: title) { EmptyView() } }
}
/// A quiet round icon button on the page surface (not a glass toolbar item).
struct PineCircleButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void
    var body: some View {
        Button(action: action) { PineCircleIcon(systemImage: systemImage) }
            .buttonStyle(PinePressStyle(scale: 0.94)).accessibilityLabel(title)
    }
}
struct PineCircleIcon: View {
    let systemImage: String
    var body: some View {
        Image(systemName: systemImage).font(.body.weight(.medium)).foregroundStyle(.primary)
            .frame(width: 40, height: 40).background(pineSurface, in: Circle()).frame(width: 44, height: 44).contentShape(Circle())
    }
}
/// Section title used on every page: one size, trailing accessories on the baseline.
struct PineSectionHeader<Accessory: View>: View {
    let title: String
    var minHeight: CGFloat = 44
    @ViewBuilder var accessory: Accessory
    var body: some View {
        HStack(alignment: .center, spacing: 4) {
            Text(title).font(.title3.weight(.semibold)).accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            accessory
        }.frame(minHeight: minHeight)
    }
}
extension PineSectionHeader where Accessory == EmptyView {
    init(title: String) { self.init(title: title) { EmptyView() } }
}

/// One moment worth celebrating today; each kind plays at most once a day.
struct PineCelebration: Identifiable, Equatable {
    enum Kind: String { case activity, strength, posture, all, round, steps, streak }
    let id = UUID()
    let kind: Kind
    let activity: Double?
    let halves: [Double]
    let posture: Bool
    /// For a finished round: its number and total work sets.
    var round = 0
    var sets = 0
    /// For a posture streak badge: consecutive practice days (3, 7 or 14).
    var streak = 0
    var big: Bool { kind == .all || kind == .round || (kind == .streak && streak >= 14) }
    var title: String {
        switch kind {
        case .activity: return "活动目标达成"
        case .strength: return "今天的力量练完了"
        case .posture: return "体态练习完成"
        case .all: return "今天三项全满"
        case .round: return "第 \(round) 轮完成"
        case .steps: return "步数目标达成"
        case .streak: return "体态连续 \(streak) 天"
        }
    }
    var detail: String {
        switch kind {
        case .round: return "五天 · \(sets) 组"
        case .streak: return "计划日一天没落下"
        default: return "活动 · 力量 · 体态"
        }
    }
}

/// A goal closing: the glyph spins once while sparks burst, with a haptic
/// rhythm. One goal is a toast at the top; all three take the whole screen.
struct PineCelebrationView: View {
    let event: PineCelebration
    let onDone: () -> Void
    @PineReducedMotion private var reduceMotion
    @State private var spin = 0.0
    @State private var appear = false
    @State private var finished = false
    var body: some View {
        Group {
            if event.big {
                ZStack {
                    Rectangle().fill(.ultraThinMaterial).ignoresSafeArea()
                    VStack(spacing: 14) {
                        ZStack {
                            if !reduceMotion { PineSparkBurst(radius: 150, count: 40, duration: 1.2) }
                            Group {
                                if event.kind == .round { PineMedal(round: event.round).frame(width: 180, height: 180) }
                                else if event.kind == .streak { PineStreakBadge(count: event.streak).frame(width: 170, height: 170) }
                                else { PineDayGlyph(activity: event.activity, halves: event.halves, posture: event.posture, size: 170) }
                            }
                            .rotation3DEffect(.degrees(event.kind == .round || event.kind == .streak ? spin : 0), axis: (x: 0, y: 1, z: 0))
                            .rotationEffect(.degrees(event.kind == .round || event.kind == .streak ? 0 : spin)).scaleEffect(appear ? 1 : 0.6)
                        }.frame(width: 320, height: 320)
                        Text(event.title).font(.title.weight(.bold))
                        Text(event.detail).font(.subheadline.weight(.semibold)).foregroundStyle(pineGold)
                    }
                }.opacity(appear ? 1 : 0)
            } else {
                HStack(spacing: 12) {
                    ZStack {
                        if !reduceMotion { PineSparkBurst(radius: 30, count: 16, duration: 0.8).frame(width: 76, height: 76) }
                        Group {
                            switch event.kind {
                            case .steps: Image(systemName: "figure.walk").font(.system(size: 20, weight: .semibold)).foregroundStyle(pineGold).frame(width: 34, height: 34).background(pineTint, in: Circle())
                                .symbolEffect(.bounce, value: spin)
                            case .streak: PineStreakBadge(count: event.streak).frame(width: 34, height: 34)
                            default: PineDayGlyph(activity: event.activity, halves: event.halves, posture: event.posture, size: 34)
                            }
                        }.rotationEffect(.degrees(event.kind == .streak || event.kind == .steps ? 0 : spin))
                        .rotation3DEffect(.degrees(event.kind == .streak ? spin : 0), axis: (x: 0, y: 1, z: 0))
                    }.frame(width: 36, height: 36)
                    Text(event.title).font(.headline)
                    Image(systemName: "sparkles").foregroundStyle(pineGold)
                }
                .padding(.horizontal, 18).padding(.vertical, 12)
                .background(.regularMaterial, in: Capsule())
                .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
                .padding(.top, 6)
                .offset(y: appear ? 0 : -140)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { finish() }
        .accessibilityElement(children: .combine).accessibilityAddTraits(.isButton).accessibilityHint("点按关闭")
        .task {
            PineHaptics.celebrate(big: event.big)
            withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.5, dampingFraction: 0.72)) { appear = true }
            if !reduceMotion { withAnimation(.spring(response: 1.1, dampingFraction: 0.82)) { spin = 360 } }
            try? await Task.sleep(for: .seconds(event.kind == .round ? 3.6 : event.big ? 2.8 : 2.2))
            finish()
        }
    }
    private func finish() {
        guard !finished else { return }
        finished = true
        withAnimation(.easeOut(duration: 0.25)) { appear = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) { onDone() }
    }
}

/// A posture streak badge: a pine disc with a gold ring and the day count,
/// the ring split into as many arcs as the milestone (3, 7, 14).
struct PineStreakBadge: View {
    let count: Int
    var body: some View {
        GeometryReader { proxy in
            let d = min(proxy.size.width, proxy.size.height), segments = max(3, min(14, count))
            ZStack {
                Circle().fill(pine)
                ForEach(0..<segments, id: \.self) { index in
                    let gap = 0.012
                    Circle().trim(from: Double(index) / Double(segments) + gap, to: Double(index + 1) / Double(segments) - gap)
                        .stroke(pineGold, style: StrokeStyle(lineWidth: max(1.5, d * 0.07), lineCap: .butt))
                        .rotationEffect(.degrees(-90)).padding(d * 0.07)
                }
                VStack(spacing: 0) {
                    Text("\(count)").font(.system(size: d * 0.36, weight: .bold, design: .rounded)).monospacedDigit()
                    if d > 60 { Text("天体态").font(.system(size: d * 0.09, weight: .semibold)) }
                }.foregroundStyle(.white)
            }.frame(width: d, height: d).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .compositingGroup().shadow(color: pineGold.opacity(0.3), radius: 8, y: 3)
        .accessibilityElement().accessibilityLabel("体态连续 \(count) 天徽章")
    }
}

/// The round's medal: a gold rim around the pine face, with a light sweep.
struct PineMedal: View {
    let round: Int
    @State private var sweep = false
    @PineReducedMotion private var reduceMotion
    var body: some View {
        GeometryReader { proxy in
            let d = min(proxy.size.width, proxy.size.height), rim = d * 0.07
            ZStack {
                Circle().fill(LinearGradient(colors: [pineGold.opacity(0.75), pineGold, pineGold.opacity(0.85)], startPoint: .topLeading, endPoint: .bottomTrailing))
                Circle().inset(by: rim).fill(pine)
                Circle().inset(by: rim).stroke(.white.opacity(0.25), lineWidth: max(0.5, d * 0.008))
                VStack(spacing: 0) {
                    Text("\(round)").font(.system(size: d * 0.36, weight: .bold, design: .rounded)).monospacedDigit()
                    if d > 60 { Text("轮").font(.system(size: d * 0.1, weight: .semibold)) }
                }.foregroundStyle(.white)
                // A soft highlight passes across the medal once.
                if !reduceMotion && d > 60 {
                    LinearGradient(colors: [.clear, .white.opacity(0.45), .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: d * 0.33).rotationEffect(.degrees(20)).offset(x: sweep ? d * 0.85 : -d * 0.85)
                        .mask(Circle())
                }
            }
            .frame(width: d, height: d)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .compositingGroup().shadow(color: pineGold.opacity(0.35), radius: 12, y: 4)
        .onAppear { withAnimation(.easeInOut(duration: 1.4).delay(0.6)) { sweep = true } }
        .accessibilityElement().accessibilityLabel("第 \(round) 轮奖章")
    }
}

// MARK: Motion batch 3

/// Hold to confirm: a ring fills around the check while the finger stays down,
/// and the action runs when it closes. Letting go early drains it. VoiceOver's
/// activate runs the action directly.
struct PineHoldButton: View {
    let title: String
    var duration: Double = 1.0
    let action: () -> Void
    @PineReducedMotion private var reduceMotion
    @State private var progress: CGFloat = 0
    @State private var hint = false
    @State private var done = 0
    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().stroke(.white.opacity(0.3), lineWidth: 3)
                Circle().trim(from: 0, to: progress).stroke(.white, style: StrokeStyle(lineWidth: 3, lineCap: .round)).rotationEffect(.degrees(-90))
                Image(systemName: "checkmark").font(.caption.weight(.bold)).scaleEffect(progress >= 1 ? 1.2 : 1)
            }.frame(width: 24, height: 24)
            Text(hint ? "按住完成" : title)
                .contentTransition(.opacity)
        }
        .font(.headline).foregroundStyle(.white)
        .frame(maxWidth: .infinity, minHeight: 56)
        .background {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(pine)
                    Capsule().fill(.white.opacity(0.16)).frame(width: proxy.size.width * progress)
                }
            }
        }
        .clipShape(Capsule())
        .scaleEffect(progress > 0 && progress < 1 && !reduceMotion ? 0.98 : 1)
        .contentShape(Capsule())
        .onLongPressGesture(minimumDuration: duration, maximumDistance: 40) {
            done += 1
            action()
        } onPressingChanged: { pressing in
            if pressing {
                withAnimation(.linear(duration: duration)) { progress = 1 }
            } else if progress < 1 || done == 0 {
                withAnimation(.easeOut(duration: 0.25)) { progress = 0 }
            }
        }
        .simultaneousGesture(TapGesture().onEnded {
            withAnimation(.easeOut(duration: 0.15)) { hint = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { withAnimation(.easeOut(duration: 0.2)) { hint = false } }
        })
        .sensoryFeedback(.impact(weight: .light), trigger: progress > 0) { _, pressing in pressing }
        .sensoryFeedback(.success, trigger: done)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title).accessibilityAddTraits(.isButton)
        .accessibilityAction { action() }
    }
}

/// A gold ring that swells and fades once: the rest clock reaching zero.
struct PineRingFlash: View {
    var size: CGFloat = 240
    @State private var on = false
    var body: some View {
        Circle().stroke(pineGold, lineWidth: 14)
            .frame(width: size, height: size)
            .scaleEffect(on ? 1.18 : 1).opacity(on ? 0 : 0.9)
            .onAppear { withAnimation(.easeOut(duration: 0.8)) { on = true } }
            .allowsHitTesting(false).accessibilityHidden(true)
    }
}

/// The glyph as a pull-to-refresh indicator: the rings fill as the page is
/// pulled, then the whole mark spins while the refresh runs.
struct PineRefreshGlyph: View {
    let progress: Double
    let spinning: Bool
    var size: CGFloat = 26
    @PineReducedMotion private var reduceMotion
    var body: some View {
        TimelineView(.animation(minimumInterval: nil, paused: !spinning || reduceMotion)) { context in
            let turn = spinning && !reduceMotion ? context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.1) / 1.1 * 360 : progress * 270
            PineDayGlyph(activity: max(0.01, min(1, progress * 1.4)), halves: [min(1, max(0, progress * 2 - 0.4)), min(1, max(0, progress * 2 - 1))], posture: progress >= 1, size: size)
                .rotationEffect(.degrees(turn))
        }
        .padding(7).background(.regularMaterial, in: Circle())
        .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
        .accessibilityHidden(true)
    }
}

/// A small animated numeral that counts up from zero the first time it appears.
struct PineCountUp: View {
    let value: Double
    var digits = 0
    var font: Font = .title3.weight(.semibold)
    var duration: Double = 0.9
    @PineReducedMotion private var reduceMotion
    @State private var shown: Double?
    var body: some View {
        Text(displayNumber(.number(shown ?? value), digits: digits)).font(font).monospacedDigit()
            .contentTransition(reduceMotion ? .identity : .numericText(value: shown ?? value))
            .onAppear {
                guard !reduceMotion, shown == nil else { return }
                shown = 0
                withAnimation(.smooth(duration: duration).delay(0.15)) { shown = value }
            }
            .onChange(of: value) { _, next in withAnimation(reduceMotion ? nil : .smooth(duration: 0.5)) { shown = next } }
    }
}

/// A half-circle dial (left to right) that sweeps to `fraction` on appear.
struct PineHalfDial: View {
    let fraction: Double
    var lineWidth: CGFloat = 12
    var color: Color = pine
    @PineReducedMotion private var reduceMotion
    @State private var shown = false
    var body: some View {
        GeometryReader { proxy in
            let d = min(proxy.size.width, proxy.size.height * 2)
            ZStack {
                Circle().trim(from: 0.5, to: 1).stroke(pineTrack, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                Circle().trim(from: 0.5, to: 0.5 + 0.5 * max(0, min(1, fraction)) * (shown || reduceMotion ? 1 : 0))
                    .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            }
            .frame(width: d - lineWidth, height: d - lineWidth)
            .frame(width: proxy.size.width, height: d / 2 + lineWidth / 2, alignment: .top)
            .offset(y: lineWidth / 2)
        }
        .onAppear { withAnimation(.spring(response: 1.0, dampingFraction: 0.9).delay(0.1)) { shown = true } }
        .animation(reduceMotion ? nil : .spring(response: 0.6, dampingFraction: 0.85), value: fraction)
        .accessibilityHidden(true)
    }
}

/// The namespace the workout cover zooms out of (iOS 18+): set by the tab
/// root, read by every button that opens the workout.
private struct PineWorkoutZoomKey: EnvironmentKey { static let defaultValue: Namespace.ID? = nil }
extension EnvironmentValues {
    var pineWorkoutZoom: Namespace.ID? {
        get { self[PineWorkoutZoomKey.self] }
        set { self[PineWorkoutZoomKey.self] = newValue }
    }
}
private struct PineWorkoutSource: ViewModifier {
    @Environment(\.pineWorkoutZoom) private var space
    let id: String
    func body(content: Content) -> some View {
        if let space { content.pineZoomSource(id, in: space) } else { content }
    }
}
extension View {
    /// Marks a button the workout screen grows out of and shrinks back into.
    func pineWorkoutSource(_ id: String) -> some View { modifier(PineWorkoutSource(id: id)) }
}

/// Pull to refresh with the glyph instead of the system spinner (iOS 18+; the
/// system control before). Pulling fills the rings; past the threshold it
/// fires once with a tap and spins until the refresh ends.
struct PinePullRefresh: ViewModifier {
    let action: @MainActor () async -> Void
    var threshold: CGFloat = 76
    @State private var pull: CGFloat = 0
    @State private var running = false
    @State private var armed = true
    @State private var fired = 0
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content
                .scrollBounceBehavior(.always)
                .onScrollGeometryChange(for: CGFloat.self) { geometry in
                    -(geometry.contentOffset.y + geometry.contentInsets.top)
                } action: { _, value in
                    pull = max(0, value)
                    if value <= 2 { armed = true }
                    if armed, !running, value >= threshold { armed = false; fired += 1; run() }
                }
                .overlay(alignment: .top) {
                    if pull > 8 {
                        PineRefreshGlyph(progress: running ? 1 : min(1, pull / threshold), spinning: running)
                            .offset(y: pull / 2 - 20)
                            .opacity(min(1, (pull - 8) / 24))
                    }
                }
                .sensoryFeedback(.impact(weight: .medium), trigger: fired)
        } else {
            content.refreshable { await action() }
        }
    }
    private func run() {
        running = true
        Task { await action(); running = false }
    }
}

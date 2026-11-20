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
    var body: some View {
        let unit = size / 88
        let base = future ? pineFaint : pineTrack
        ZStack {
            Circle().stroke(base, lineWidth: 8 * unit).frame(width: 72 * unit, height: 72 * unit)
            if !future, let activity, activity > 0 {
                Circle().trim(from: 0, to: min(1, activity))
                    .stroke(pine, style: StrokeStyle(lineWidth: 8 * unit, lineCap: .round))
                    .rotationEffect(.degrees(-90)).frame(width: 72 * unit, height: 72 * unit)
                if activity > 1 {
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
                    Circle().trim(from: 0.25, to: 0.25 + 0.5 * min(1, halves[index]))
                        .stroke(pine, style: StrokeStyle(lineWidth: 7 * unit, lineCap: .butt))
                        .rotationEffect(.degrees(index == 0 ? 0 : 180)).frame(width: 42 * unit, height: 42 * unit)
                }
            }
            Circle().fill(!future && posture ? pine : base).frame(width: 18 * unit, height: 18 * unit)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
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
struct PineTabHeader<Actions: View>: View {
    @Environment(NativeStore.self) var store
    let title: String
    @ViewBuilder var actions: Actions
    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(title).font(.system(size: 30, weight: .bold)).lineLimit(1).minimumScaleFactor(0.8)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            if store.active != nil {
                Button { store.workoutPresented = true } label: {
                    Label("继续训练", systemImage: "play.fill").font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 14).frame(height: 36).background(pine, in: Capsule())
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

import SwiftUI
import PhotosUI

// Body weight, lean-gain pace, protein, girths and comparison photos.
/// Body-weight readings, newest first, with the change from each previous one.
/// Lean-gain pace against a band for a newer lifter: 0.5–1 % of body weight a
/// month. Slower rarely builds much muscle; faster mostly adds fat.
enum NativeGain {
    static let band = 0.5...1.0
    static func rate(_ rows: [JSONValue], today: String) -> (percentPerMonth: Double, kgPerMonth: Double, average: Double)? {
        NativeDays.weightRate(rows.compactMap { row in row["kg"].number.map { (date: row["date"].text, kg: $0) } }, today: today)
    }
    static func status(_ percent: Double) -> String { percent < band.lowerBound ? "偏慢" : percent > band.upperBound ? "偏快" : "合适" }
    static func advice(_ percent: Double) -> String {
        if percent < 0 { return "近 4 周体重在往下走，增肌很难。每天多吃约 300–400 千卡，比如多一碗米饭加一杯牛奶。" }
        if percent < band.lowerBound { return "涨得偏慢。每天多吃约 200–300 千卡，比如多一份主食或一杯牛奶。" }
        if percent > band.upperBound { return "涨得偏快，多出来的多半是脂肪。每天少吃约 200 千卡，同时留意腰围。" }
        return "节奏合适，保持现在的吃法。腰围每月增加不超过约 1 厘米就说明主要在长肌肉。"
    }
}
/// Protein eaten today, tapped in by portions; kept on this phone.
enum NativeProtein {
    static let key = "pine.protein"
    static func all() -> [String: Double] { UserDefaults.standard.dictionary(forKey: key) as? [String: Double] ?? [:] }
    static func add(_ grams: Double, on date: String) {
        var rows = all(); rows[date] = max(0, (rows[date] ?? 0) + grams)
        store(rows); NativeBodySync.markProtein(date)
    }
    /// The server's totals replace the phone's copy after a sync.
    static func replace(_ rows: [String: Double]) { store(rows) }
    private static func store(_ value: [String: Double]) {
        var rows = value
        // Keep about two months on the phone; the server keeps the rest.
        if rows.count > 70 { for old in rows.keys.sorted().prefix(rows.count - 70) { rows[old] = nil } }
        UserDefaults.standard.set(rows, forKey: key)
    }
    /// 1.6 g per kg of body weight, rounded to 5 g.
    static func target(kg: Double) -> Double { (kg * 1.6 / 5).rounded() * 5 }
}
/// Girths and protein: the phone keeps a copy for offline use and the server keeps
/// the record. Local changes are marked and pushed first (each write is idempotent),
/// then the server's copy replaces the phone's. Photos never leave the phone.
enum NativeBodySync {
    private static let migratedKey = "pine.body.migrated"
    private static let dirtyEntriesKey = "pine.body.dirty.entries", deletedEntriesKey = "pine.body.deleted.entries", dirtyProteinKey = "pine.body.dirty.protein"
    @MainActor private static var running = false
    static func markEntry(_ id: String) { change(dirtyEntriesKey) { _ = $0.insert(id) } }
    static func markDeleted(_ id: String) { change(deletedEntriesKey) { _ = $0.insert(id) }; change(dirtyEntriesKey) { _ = $0.remove(id) } }
    static func markProtein(_ date: String) { change(dirtyProteinKey) { _ = $0.insert(date) } }
    private static func ids(_ key: String) -> Set<String> { Set(UserDefaults.standard.stringArray(forKey: key) ?? []) }
    private static func change(_ key: String, _ edit: (inout Set<String>) -> Void) {
        var value = ids(key); edit(&value); UserDefaults.standard.set(value.sorted(), forKey: key)
    }
    /// True when the server's copy was applied to the phone.
    @MainActor @discardableResult static func sync(_ api: HealthAPI) async -> Bool {
        guard !running else { return false }
        running = true; defer { running = false }
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: migratedKey) {
            // The first sync uploads what was recorded before girths and protein had a server copy.
            for entry in NativeMeasurements.entries() { markEntry(entry.id.uuidString) }
            for date in NativeProtein.all().keys { markProtein(date) }
            defaults.set(true, forKey: migratedKey)
        }
        do {
            for id in ids(deletedEntriesKey) {
                _ = try await api.request("/body/measurements/" + id, method: "DELETE"); change(deletedEntriesKey) { _ = $0.remove(id) }
            }
            let entries = NativeMeasurements.entries()
            for id in ids(dirtyEntriesKey) {
                if let entry = entries.first(where: { $0.id.uuidString == id }) {
                    _ = try await api.request("/body/measurements/" + id, method: "PUT", body: ["kind": .string(entry.kind), "date": .string(entry.date), "cm": .number(entry.cm)])
                }
                change(dirtyEntriesKey) { _ = $0.remove(id) }
            }
            let protein = NativeProtein.all()
            for date in ids(dirtyProteinKey) {
                _ = try await api.request("/body/protein/" + date, method: "PUT", body: ["grams": .number(protein[date] ?? 0)])
                change(dirtyProteinKey) { _ = $0.remove(date) }
            }
            let server = try await api.request("/body")
            // An edit made while this ran is pushed next time; keep it on the phone until then.
            guard ids(dirtyEntriesKey).isEmpty, ids(deletedEntriesKey).isEmpty, ids(dirtyProteinKey).isEmpty else { return false }
            NativeMeasurements.save(server["measurements"].array.compactMap { row in
                guard let id = UUID(uuidString: row.id), let cm = row["cm"].number, !row["kind"].text.isEmpty, !row["date"].text.isEmpty else { return nil }
                return NativeMeasurements.Entry(id: id, kind: row["kind"].text, date: row["date"].text, cm: cm)
            })
            NativeProtein.replace(server["protein"].object.compactMapValues(\.number))
            return true
        } catch {
            // An older server without these endpoints, or no connection: keep the phone's copy and retry later.
            return false
        }
    }
}
/// Shoulder circumference over waist, pairing each shoulder reading with the
/// waist reading closest in time (within ten days).
enum NativeShape {
    static func ratios(_ entries: [NativeMeasurements.Entry]) -> [(date: String, ratio: Double)] {
        let waists = entries.filter { $0.kind == NativeMeasurements.Kind.waist.rawValue }
        func day(_ key: String) -> Double { (NativeDate.parse(key + "T12:00:00Z")?.timeIntervalSince1970 ?? 0) / 86400 }
        return entries.filter { $0.kind == NativeMeasurements.Kind.shoulder.rawValue }.sorted { $0.date < $1.date }.compactMap { shoulder in
            guard let waist = waists.min(by: { abs(day($0.date) - day(shoulder.date)) < abs(day($1.date) - day(shoulder.date)) }),
                  abs(day(waist.date) - day(shoulder.date)) <= 10, waist.cm > 0 else { return nil }
            return (shoulder.date, shoulder.cm / waist.cm)
        }
    }
}

struct NativeWeightList: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(NativeStore.self) private var store
    let rows: [JSONValue]
    @State private var protein = NativeProtein.all()
    /// Portions added on this page, newest last, so undo takes back exactly the last one.
    @State private var added: [Double] = []
    @State private var entries = NativeMeasurements.entries()
    private var today: String { store.home["date"].text.isEmpty ? NativeDate.day(Date(), timezone: TimeZone.current.identifier) : store.home["date"].text }
    var body: some View {
        let sorted = rows.filter { $0["kg"].number != nil }.sorted { $0["date"].text > $1["date"].text }
        let rate = NativeGain.rate(rows, today: today)
        let kg = rate?.average ?? sorted.first?["kg"].number
        List {
            Section {
                if let rate {
                    HStack(alignment: .firstTextBaseline) {
                        Text(NativeGain.status(rate.percentPerMonth)).font(.title3.weight(.semibold))
                            .foregroundStyle(NativeGain.status(rate.percentPerMonth) == "合适" ? pine : Color.primary)
                        Spacer()
                        Text(signed(rate.kgPerMonth) + " 公斤/月").font(.subheadline.weight(.semibold)).monospacedDigit()
                    }
                    gainBar(rate.percentPerMonth)
                    Text(paceText(percent: rate.percentPerMonth, average: rate.average))
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    Text(NativeGain.advice(rate.percentPerMonth)).font(.subheadline)
                } else {
                    Text("近 4 周至少称 6 次、跨度两周以上后显示。每周称 3 次以上，固定在早上起床后。").font(.subheadline).foregroundStyle(.secondary)
                }
            } header: { Text("增肌速度") } footer: { Text("目标每月涨体重的 0.5–1%：力量训练前一两年的常用增肌节奏。按每天的称重拟合趋势，单次波动不影响。") }
            Section {
                let eaten = protein[today] ?? 0, goal = kg.map(NativeProtein.target) ?? 0
                HStack(alignment: .firstTextBaseline) {
                    Text(displayNumber(.number(eaten), digits: 0) + " 克").font(.title3.weight(.semibold)).monospacedDigit()
                        .contentTransition(.numericText(value: eaten))
                    if goal > 0 { Text("/ " + displayNumber(.number(goal), digits: 0)).font(.subheadline).foregroundStyle(.secondary) }
                    Spacer()
                    if goal > 0, eaten >= goal { Label("达标", systemImage: "checkmark").font(.subheadline.weight(.semibold)).foregroundStyle(pine) }
                }
                if goal > 0 { ProgressView(value: min(1, eaten / goal)).tint(pine) }
                HStack(spacing: 8) {
                    ForEach([20.0, 30.0, 50.0], id: \.self) { grams in
                        Button("+\(Int(grams))") { addProtein(grams) }.buttonStyle(.bordered).tint(pine)
                    }
                    Spacer()
                    Button("撤销上一次", systemImage: "arrow.uturn.backward") { undoProtein() }.labelStyle(.iconOnly).buttonStyle(.bordered).disabled(added.isEmpty || eaten <= 0)
                        .accessibilityLabel(added.last.map { "撤销刚才的 +\(Int($0)) 克" } ?? "撤销")
                }.font(.subheadline.weight(.semibold))
                let week = (0..<7).compactMap { offset -> Double? in
                    guard let date = NativeDate.parse(today + "T12:00:00Z")?.addingTimeInterval(-Double(offset) * 86400) else { return nil }
                    return protein[NativeDate.day(date, timezone: "UTC")]
                }
                if goal > 0, !week.isEmpty { Text("近 7 天记录了 \(week.count) 天，其中 \(week.filter { $0 >= goal }.count) 天达标").font(.caption).foregroundStyle(.secondary) }
            } header: { Text("今天的蛋白质") } footer: { Text("每公斤体重约 1.6 克，分到三四顿。参考：一个鸡蛋约 6 克，一杯牛奶约 8 克，一掌心肉或鱼约 25 克，一勺蛋白粉约 25 克。会同步到服务器。") }
            Section {
                let ratios = NativeShape.ratios(entries)
                if let last = ratios.last {
                    HStack(alignment: .firstTextBaseline) {
                        Text(displayNumber(.number(last.ratio), digits: 2)).font(.title3.weight(.semibold)).monospacedDigit()
                        Spacer()
                        if let first = ratios.first, ratios.count > 1 {
                            let change = ((last.ratio - first.ratio) * 100).rounded() / 100
                            Text("自 \(dayTitle(first.date, format: "M月d日")) \(signed(change))")
                                .font(.subheadline).foregroundStyle(change > 0 ? pine : Color.secondary).monospacedDigit()
                        }
                    }
                    Text("肩围 ÷ 腰围。肩变宽、腰不变粗，这个数就往上走，是外形变化最直接的指标。常被当作理想参考的是 1.6 左右。").font(.footnote).foregroundStyle(.secondary)
                } else {
                    Text("记录肩围和腰围（相隔不超过 10 天）后显示。").font(.subheadline).foregroundStyle(.secondary)
                }
                NavigationLink { NativeMeasurementsView() } label: { Label("围度与对比照片", systemImage: "ruler") }
            } header: { Text("肩腰比") } footer: { Text("腰围每周一次，臂围和肩围每月一次。") }
            if sorted.isEmpty { Text("还没有体重记录。").foregroundStyle(.secondary) }
            ForEach(Array(sorted.enumerated()), id: \.offset) { index, row in
                HStack {
                    Text(dayTitle(row["date"].text, format: "M月d日 EEE"))
                    Spacer()
                    if index + 1 < sorted.count, let kg = row["kg"].number, let prior = sorted[index + 1]["kg"].number {
                        let delta = ((kg - prior) * 10).rounded() / 10
                        Text((delta >= 0 ? "+" : "") + displayNumber(.number(delta), digits: 1)).font(.footnote).foregroundStyle(.secondary).monospacedDigit()
                    }
                    Text(displayNumber(row["kg"], digits: 1) + " 公斤").fontWeight(.semibold).monospacedDigit()
                }
            }
        }.navigationTitle("体重与体型").navigationBarTitleDisplayMode(.inline)
            .onAppear { entries = NativeMeasurements.entries(); protein = NativeProtein.all() }
            .task { if !store.isDesignPreview, await NativeBodySync.sync(store.api) { entries = NativeMeasurements.entries(); protein = NativeProtein.all() } }
    }
    private func signed(_ value: Double) -> String { (value >= 0 ? "+" : "") + displayNumber(.number(value), digits: 2) }
    private func paceText(percent: Double, average: Double) -> String {
        let avg: String = displayNumber(.number(average), digits: 1)
        return "近 4 周每月 \(signed(percent))% · 7 天平均 \(avg) 公斤"
    }
    private func addProtein(_ grams: Double) {
        NativeProtein.add(grams, on: today); added.append(grams)
        withAnimation(.snappy) { protein = NativeProtein.all() }
        pushProtein()
    }
    private func undoProtein() {
        guard let last = added.popLast() else { return }
        NativeProtein.add(-last, on: today)
        withAnimation(.snappy) { protein = NativeProtein.all() }
        pushProtein()
    }
    private func pushProtein() {
        guard !store.isDesignPreview else { return }
        Task { if await NativeBodySync.sync(store.api) { protein = NativeProtein.all() } }
    }
    /// The month's pace on a 0–1.5 % scale with the target band shaded.
    private func gainBar(_ percent: Double) -> some View {
        GeometryReader { proxy in
            let w = proxy.size.width, scale = 1.5
            let x = { (v: Double) in CGFloat(max(0, min(scale, v)) / scale) * w }
            ZStack(alignment: .leading) {
                Capsule().fill(pineTrack).frame(height: 8)
                Capsule().fill(pine.opacity(0.3)).frame(width: x(NativeGain.band.upperBound) - x(NativeGain.band.lowerBound), height: 8).offset(x: x(NativeGain.band.lowerBound))
                Circle().fill(pine).frame(width: 14, height: 14).overlay(Circle().stroke(pineSurface, lineWidth: 2)).offset(x: x(percent) - 7)
            }.frame(height: 14)
        }.frame(height: 14).accessibilityHidden(true)
    }
}

/// Girths kept on this phone: waist weekly, arm and shoulders monthly.
enum NativeMeasurements {
    enum Kind: String, CaseIterable, Identifiable {
        case waist, arm, shoulder
        var id: String { rawValue }
        var title: String { switch self { case .waist: return "腰围"; case .arm: return "上臂围"; case .shoulder: return "肩围" } }
        var days: Int { self == .waist ? 7 : 30 }
        var how: String {
            switch self {
            case .waist: return "早上空腹、自然呼气后，软尺贴着皮肤过肚脐绕一圈，不要勒紧。"
            case .arm: return "右臂放松下垂，量上臂最粗的地方。"
            case .shoulder: return "站直、双臂自然下垂，软尺绕过两侧肩膀最宽处一圈。"
            }
        }
    }
    struct Entry: Codable, Identifiable, Equatable { var id = UUID(); let kind: String; let date: String; let cm: Double }
    struct Photo: Codable, Identifiable, Equatable { var id = UUID(); let date: String; let file: String }
    static let key = "pine.measurements", photosKey = "pine.photos"
    static func entries() -> [Entry] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
    }
    static func save(_ entries: [Entry]) { UserDefaults.standard.set(try? JSONEncoder().encode(entries), forKey: key) }
    static func photos() -> [Photo] {
        guard let data = UserDefaults.standard.data(forKey: photosKey) else { return [] }
        return (try? JSONDecoder().decode([Photo].self, from: data)) ?? []
    }
    static func savePhotos(_ photos: [Photo]) { UserDefaults.standard.set(try? JSONEncoder().encode(photos), forKey: photosKey) }
    static var folder: URL {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("pine-photos", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    /// Latest value and the change against the reading at least 25 days earlier.
    static func latest(_ kind: Kind, in list: [Entry]) -> (value: Double, date: String, change: Double?)? {
        let rows = list.filter { $0.kind == kind.rawValue }.sorted { $0.date > $1.date }
        guard let last = rows.first else { return nil }
        let older = rows.first { entry in
            guard let a = NativeDate.parse(last.date + "T12:00:00Z"), let b = NativeDate.parse(entry.date + "T12:00:00Z") else { return false }
            return a.timeIntervalSince(b) >= 25 * 86400
        }
        return (last.cm, last.date, older.map { ((last.cm - $0.cm) * 10).rounded() / 10 })
    }
}

struct NativeMeasurementsView: View {
    @Environment(NativeStore.self) var store
    @State private var entries = NativeMeasurements.entries()
    @State private var photos = NativeMeasurements.photos()
    @State private var editing: NativeMeasurements.Kind?
    @State private var picked: PhotosPickerItem?
    @State private var viewing: NativeMeasurements.Photo?
    @State private var comparing = false
    private var today: String { store.home["date"].text.isEmpty ? NativeDate.day(Date(), timezone: TimeZone.current.identifier) : store.home["date"].text }
    var body: some View {
        List {
            ForEach(NativeMeasurements.Kind.allCases) { kind in
                Section {
                    let latest = NativeMeasurements.latest(kind, in: entries)
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(latest.map { displayNumber(.number($0.value)) + " 厘米" } ?? "还没有记录").font(.title3.weight(.semibold)).monospacedDigit()
                            if let latest {
                                Text(dayTitle(latest.date, format: "M月d日") + (latest.change.map { " · 4周 " + ($0 >= 0 ? "+" : "") + displayNumber(.number($0)) } ?? ""))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        let due = latest.map { (NativeDate.parse(today + "T12:00:00Z")?.timeIntervalSince(NativeDate.parse($0.date + "T12:00:00Z") ?? .distantPast) ?? 0) >= Double(kind.days - 1) * 86400 } ?? true
                        Button(due ? "记录" : "更新") { editing = kind }.buttonStyle(.borderedProminent).tint(due ? pine : .secondary)
                    }
                    ForEach(entries.filter { $0.kind == kind.rawValue }.sorted { $0.date > $1.date }.prefix(6)) { entry in
                        HStack { Text(dayTitle(entry.date, format: "M月d日 EEE")); Spacer(); Text(displayNumber(.number(entry.cm)) + " 厘米").monospacedDigit() }
                            .font(.subheadline).foregroundStyle(.secondary)
                            .swipeActions { Button("删除", role: .destructive) { entries.removeAll { $0.id == entry.id }; NativeMeasurements.save(entries); NativeBodySync.markDeleted(entry.id.uuidString); syncBody() } }
                    }
                } header: { Text(kind.title + (kind == .waist ? " · 每周" : " · 每月")) } footer: { Text(kind.how) }
            }
            Section {
                PhotosPicker(selection: $picked, matching: .images) { Label("添加今天的照片", systemImage: "camera") }
                if photos.count >= 2 { Button { comparing = true } label: { Label("第一张和最新一张对比", systemImage: "rectangle.split.2x1") } }
                if !photos.isEmpty {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                        ForEach(photos.sorted { $0.date > $1.date }) { photo in
                            Button { viewing = photo } label: {
                                ZStack(alignment: .bottomLeading) {
                                    photoImage(photo).resizable().scaledToFill().frame(height: 120).clipped()
                                    Text(dayTitle(photo.date, format: "M/d")).font(.caption2.weight(.semibold)).foregroundStyle(.white).padding(4)
                                }.clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            }.buttonStyle(.plain)
                        }
                    }.padding(.vertical, 4)
                }
            } header: { Text("对比照片 · 每月") } footer: { Text("同样的光线和站姿，正面、侧面、背面各一张。围度会同步到服务器，进入每周观察；照片只保存在这台手机上，删除 App 会一起删除。") }
        }
        .navigationTitle("围度与照片").navigationBarTitleDisplayMode(.inline)
        .task { if !store.isDesignPreview, await NativeBodySync.sync(store.api) { entries = NativeMeasurements.entries() } }
        .sheet(item: $editing) { kind in NavigationStack { NativeMeasurementEntry(kind: kind, date: today) { value in
            let entry = NativeMeasurements.Entry(kind: kind.rawValue, date: today, cm: value)
            entries.append(entry); NativeMeasurements.save(entries); NativeBodySync.markEntry(entry.id.uuidString); syncBody()
        } }.presentationDetents([.medium]) }
        .sheet(item: $viewing) { photo in
            NavigationStack {
                photoImage(photo).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.black)
                    .navigationTitle(dayTitle(photo.date, format: "M月d日")).navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) { Button("完成") { viewing = nil } }
                        ToolbarItem(placement: .destructiveAction) { Button("删除", role: .destructive) { remove(photo); viewing = nil } }
                    }
            }
        }
        .sheet(isPresented: $comparing) {
            let sorted = photos.sorted { $0.date < $1.date }
            NavigationStack {
                HStack(spacing: 4) {
                    ForEach([sorted.first, sorted.last].compactMap { $0 }) { photo in
                        VStack(spacing: 6) {
                            photoImage(photo).resizable().scaledToFit()
                            Text(dayTitle(photo.date, format: "M月d日")).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }.padding().navigationTitle("对比").navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { comparing = false } } }
            }
        }
        .onChange(of: picked) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data), let jpeg = image.jpegData(compressionQuality: 0.85) {
                    let file = UUID().uuidString + ".jpg"
                    try? jpeg.write(to: NativeMeasurements.folder.appendingPathComponent(file), options: .completeFileProtection)
                    photos.append(.init(date: today, file: file)); NativeMeasurements.savePhotos(photos)
                }
                picked = nil
            }
        }
    }
    private func syncBody() {
        Task { if await NativeBodySync.sync(store.api) { entries = NativeMeasurements.entries() } }
    }
    private func photoImage(_ photo: NativeMeasurements.Photo) -> Image {
        let path = NativeMeasurements.folder.appendingPathComponent(photo.file).path
        return UIImage(contentsOfFile: path).map { Image(uiImage: $0) } ?? Image(systemName: "photo")
    }
    private func remove(_ photo: NativeMeasurements.Photo) {
        try? FileManager.default.removeItem(at: NativeMeasurements.folder.appendingPathComponent(photo.file))
        photos.removeAll { $0.id == photo.id }; NativeMeasurements.savePhotos(photos)
    }
}

struct NativeMeasurementEntry: View {
    @Environment(\.dismiss) private var dismiss
    let kind: NativeMeasurements.Kind
    let date: String
    let save: (Double) -> Void
    @State private var text = ""
    var body: some View {
        Form {
            Section {
                HStack {
                    TextField("例如 80.5", text: $text).keyboardType(.decimalPad).font(.title2.weight(.semibold)).monospacedDigit()
                    Text("厘米").foregroundStyle(.secondary)
                }
            } footer: { Text(kind.how) }
        }
        .navigationTitle(kind.title + " · " + dayTitle(date, format: "M月d日")).navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") { if let value = Double(text.replacingOccurrences(of: ",", with: ".")) { save(value); dismiss() } }
                    .disabled(Double(text.replacingOccurrences(of: ",", with: ".")).map { $0 < 10 || $0 > 300 } ?? true)
            }
        }
    }
}

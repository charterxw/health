import SwiftUI
import UIKit
import CryptoKit
import Observation

@MainActor
@Observable
final class NativeStore {
    enum Phase: Equatable { case loading, login, ready, failed(String) }
    var phase: Phase = .loading
    @ObservationIgnored private var cache = NativeCacheState() { didSet { projectChanges(from: oldValue) } }
    var message: String?
    var refreshing = false
    private(set) var healthRefreshing = false
    @ObservationIgnored private var healthTask: Task<Void, Never>?
    var syncing = false
    private(set) var storageFailed = false
    var showingSettings = false
    var workoutPresented = false
    var selectedTab = 0
    var reportID: String?
    var username = ""
    var movementIndex = 0
    let api = HealthAPI()
    let coordinator = WorkoutCoordinator()
    private var cacheURL: URL?
    private var epoch = UUID()
    private var syncTask: Task<Void, Never>?
    private var publishing = false
    private var activityRevision = 0
    @ObservationIgnored private var activityForce = false
    private var booted = false
    private var pendingWorkout: String?
    private var pendingReport: String?
    private var deferredWorkout = false
    @ObservationIgnored private var lastForeground: Date?

    init() {
        #if DEBUG && targetEnvironment(simulator)
        // Prepare a standalone preview before the first frame. It must not wait
        // for scene activation, authentication, or the normal async boot task.
        if isDesignPreview {
            cache = NativeDesignFixtures.cache; username = "设计预览"; phase = .ready
            if ProcessInfo.processInfo.environment["HEALTH_DESIGN_BRIEF"] == "long" {
                cache.brief["sentences"] = [
                    ["text": "昨夜睡眠充足，HRV与静息心率均略高于基线，整体恢复接近平常。"],
                    ["text": "今天已训练，晚上照常遛狗即可，不必额外加量。"]
                ]
            }
            // Stored-property observers do not run during initialization.
            projectChanges(from: NativeCacheState())
            selectedTab = designPreviewScreen == "training" ? 1 : designPreviewScreen == "records" ? 2 : 0
            booted = true
        }
        #endif
    }

    var isDesignPreview: Bool {
        #if DEBUG && targetEnvironment(simulator)
        return ProcessInfo.processInfo.environment["HEALTH_DESIGN_PREVIEW"] == "1"
        #else
        return false
        #endif
    }
    var designPreviewScreen: String {
        #if DEBUG && targetEnvironment(simulator)
        return isDesignPreview ? ProcessInfo.processInfo.environment["HEALTH_DESIGN_SCREEN"] ?? "home" : ""
        #else
        return ""
        #endif
    }
    var designPreviewArchive: JSONValue {
        #if DEBUG && targetEnvironment(simulator)
        return isDesignPreview ? NativeDesignFixtures.archive : .null
        #else
        return .null
        #endif
    }
    private(set) var home: JSONValue = .null
    private(set) var catalog: JSONValue = .null
    private(set) var imported: JSONValue = []
    private(set) var observations: JSONValue = []
    private(set) var brief: JSONValue = .null
    private(set) var integrations: JSONValue = .null
    private(set) var deleted: Set<String> = []
    private(set) var recordDocuments: [String: NativeRecord] = [:]
    private(set) var records: [NativeRecord] = []
    private(set) var active: NativeRecord?
    private(set) var completedRecords: [NativeRecord] = []
    private(set) var history: [JSONValue] = []
    private(set) var historyRevision = 0
    private(set) var weeklyMuscleCounts: [String: Int] = [:]
    @ObservationIgnored private var recordPositions: [String: Int] = [:]
    @ObservationIgnored private var priorSetCache: [String: [JSONValue]] = [:]
    @ObservationIgnored private var cacheRevision: UInt64 = 0
    @ObservationIgnored private var checkpointDelay: Task<Void, Never>?
    @ObservationIgnored private var checkpointTask: Task<Void, Never>?
    var exercises: [JSONValue] { catalog["exercises"].array }
    var templates: [JSONValue] { catalog["templates"].array }

    private func projectChanges(from previous: NativeCacheState) {
        if home != cache.home { home = cache.home }
        if catalog != cache.catalog { catalog = cache.catalog }
        if imported != cache.imported { imported = cache.imported }
        if observations != cache.observations { observations = cache.observations }
        if brief != cache.brief { brief = cache.brief }
        if integrations != cache.integrations { integrations = cache.integrations }
        if deleted != cache.deleted { deleted = cache.deleted }
        if previous.records != cache.records {
            recordDocuments = cache.records
            let changes = cache.records.filter { previous.records[$0.key] != $0.value }
            let sameOrder = previous.records.count == cache.records.count && changes.allSatisfy {
                guard let old = previous.records[$0.key], recordPositions[$0.key] != nil else { return false }
                return old.session["started_at"] == $0.value.session["started_at"]
            }
            if sameOrder {
                var next = records
                for (id, row) in changes { if let index = recordPositions[id] { next[index] = row } }
                records = next
            } else {
                records = cache.records.values.sorted { $0.session["started_at"].text > $1.session["started_at"].text }
                recordPositions = Dictionary(uniqueKeysWithValues: records.enumerated().map { ($0.element.id, $0.offset) })
            }
            let nextActive = records.first { $0.session["status"].text == "active" }
            if active != nextActive {
                // A cold start or a different workout restores where the lifter was, not movement 1.
                if let row = nextActive, row.id != active?.id { movementIndex = resumeIndex(row.session) }
                active = nextActive
            }
        }
        let completed = records.filter { $0.session["status"].text == "completed" }
        let historyChanged = completedRecords != completed || previous.imported != cache.imported || previous.catalog != cache.catalog
        if completedRecords != completed { completedRecords = completed }
        if historyChanged {
            history = completed.map(\.session) + importedSessions()
            historyRevision += 1; priorSetCache.removeAll(keepingCapacity: true)
        }
        if historyChanged || previous.home["date"] != cache.home["date"] {
            var calendar = Calendar.current; calendar.firstWeekday = 2
            calendar.timeZone = TimeZone(identifier: home["timezone"].text) ?? .current
            let start = calendar.dateInterval(of: .weekOfYear, for: Date())?.start ?? calendar.startOfDay(for: Date())
            var counts: [String: Int] = [:]
            for record in completedRecords {
                for movement in record.session["exercises"].array where !NativeTraining.mobility(movement) {
                    let count = NativeTraining.done(movement).filter { !$0["warmup"].flag && (NativeDate.parse($0["completed_at"]) ?? .distantPast) >= start }.count
                    for key in movement["primary_muscles"].array { counts[key.text, default: 0] += count }
                }
            }
            if weeklyMuscleCounts != counts { weeklyMuscleCounts = counts }
        }
    }
    func previousSets(exercise: String, mode: String, before: JSONValue, timezone: String, current: String) -> [JSONValue] {
        _ = historyRevision
        let key = [exercise, mode, before.text, timezone, current].joined(separator: "|")
        if let value = priorSetCache[key] { return value }
        let value = NativeTraining.previous(history, exercise: exercise, mode: mode, before: NativeDate.parse(before) ?? .now, timezone: timezone, current: current)
        priorSetCache[key] = value; return value
    }
    var pending: Bool { records.contains { $0.dirty || $0.blocked != nil || $0.alternative != nil } }

    func boot() async {
        guard !booted else { return }; booted = true
        await connect()
    }
    func connect() async {
        phase = .loading
        do {
            let status = try await api.request("/auth/app-status")
            guard status["authenticated"].flag, let account = await api.username else { await api.clearCredential(); phase = .login; return }
            try await enter(account)
        } catch {
            if await api.canOpenOffline, let account = await api.username {
                do {
                    try await loadCache(account); phase = .ready; publishActivity(); await openPending()
                    message = await api.credentialExpired ? "登录已过期，正在显示本机数据。联网后请重新登录，未同步的记录会保留。" : "连接暂时不可用，正在显示本机数据。"
                }
                catch { phase = .failed(error.localizedDescription) }
            } else { phase = .failed("暂时无法连接健康服务器，请检查网络后重试。") }
        }
    }
    func login(_ name: String, password: String) async throws {
        try await api.login(username: name, password: password); try await enter(name)
    }
    private func enter(_ name: String) async throws {
        epoch = UUID(); try await loadCache(name); phase = .ready; message = nil; lastForeground = Date()
        await refresh(); await openPending()
    }
    private func loadCache(_ account: String) async throws {
        let namespace = cacheScope(account), stamp = epoch
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("PineNative", isDirectory: true)
        let hash = SHA256.hash(data: Data(namespace.utf8)).map { String(format: "%02x", $0) }.joined()
        let url = folder.appendingPathComponent(hash + ".json")
        do {
            let loaded = try await Task.detached(priority: .userInitiated) {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                var protected = folder; var options = URLResourceValues(); options.isExcludedFromBackup = true
                try protected.setResourceValues(options)
                return try NativeCacheDisk.load(at: url)
            }.value
            guard epoch == stamp else { throw CancellationError() }
            cacheURL = url; cacheRevision = loaded.revision; cache = loaded.state; username = account
        } catch is CancellationError { throw CancellationError() }
        catch { throw TrainingError.invalid("本机记录无法读取。原文件和逐次记录已保留，请先恢复后再继续。") }
    }
    private func cacheScope(_ account: String) -> String {
        // The release host is fixed; test accounts also include the isolated fixture ID.
        var scope = "https://health.frankandpatrick.com/" + account
        #if DEBUG && targetEnvironment(simulator)
        if let id = ProcessInfo.processInfo.environment["HEALTH_UI_TEST_ID"] { scope += "/fixture/" + id }
        #endif
        return scope
    }
    private func persist(_ next: NativeCacheState) throws {
        guard let url = cacheURL else { throw TrainingError.invalid("本机存储尚未准备好。") }
        let delta = NativeCacheDelta(previous: cache, next: next, revision: cacheRevision + 1)
        if delta.isEmpty {
            if storageFailed {
                let folder = NativeCacheDisk.journalURL(for: url)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let probe = folder.appendingPathComponent("storage.probe")
                try Data().write(to: probe, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]); try FileManager.default.removeItem(at: probe)
            }
            return
        }
        try NativeCacheDisk.append(delta, at: url)
        cacheRevision = delta.revision
    }
    private func commit(_ next: NativeCacheState) throws {
        guard cache != next || storageFailed else { return }
        do {
            try persist(next)
            if cache != next { cache = next; scheduleCheckpoint() }
            storageFailed = false
        } catch { storageFailed = true; throw error }
    }
    private func scheduleCheckpoint() {
        checkpointDelay?.cancel()
        guard checkpointTask == nil else { return }
        checkpointDelay = Task {
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            guard let url = cacheURL else { return }
            let snapshot = cache, revision = cacheRevision, stamp = epoch
            checkpointTask = Task {
                do { try await Task.detached(priority: .utility) { try NativeCacheDisk.checkpoint(snapshot, revision: revision, at: url) }.value }
                catch { /* The atomic journal remains the durable source. Retry on a later edit. */ }
                checkpointTask = nil
                if epoch == stamp, cacheRevision > revision { scheduleCheckpoint() }
            }
        }
    }

    func refresh() async {
        guard !isDesignPreview, phase == .ready, !refreshing else { return }; refreshing = true
        let stamp = epoch
        let paths = ["home": "/home", "catalog": "/strength/catalog", "sessions": "/strength/sessions?limit=500", "deleted": "/strength/session-deletions",
                     "imported": "/workouts/training/archive", "observations": "/insights/archive", "brief": "/home/brief", "integrations": "/integrations/status"]
        let outcomes = await withTaskGroup(of: (String, Result<JSONValue, Error>).self) { group in
            for (key, path) in paths { group.addTask { [api] in do { return (key, .success(try await api.request(path))) } catch { return (key, .failure(error)) } } }
            var result: [String: Result<JSONValue, Error>] = [:]; for await (key, value) in group { result[key] = value }; return result
        }
        guard stamp == epoch, phase == .ready else { refreshing = false; return }
        var next = cache; var failure: Error?
        for (key, result) in outcomes {
            switch result {
            case .success(let data):
                switch key {
                case "home": next.home = data
                case "catalog": next.catalog = data
                case "imported": next.imported = .array(data.array.filter { $0["source"].text != "local" })
                case "observations": next.observations = data
                case "brief": next.brief = Self.mergedBrief(next.brief, data)
                case "integrations": next.integrations = data
                default: break
                }
            case .failure(let error): if (error as? HealthAPIError)?.status == 401 { unauthorized(); refreshing = false; return }; if !Self.isCancellation(error) { failure = error }
            }
        }
        if case .success(let rows) = outcomes["deleted"] { next.deleted.formUnion(rows.array.map(\.id)) }
        if case .success(let rows) = outcomes["sessions"] { next.records = NativeRecordMerge.merge(next.records, remote: rows.array, deleted: next.deleted) }
        else { next.records = NativeRecordMerge.merge(next.records, remote: [], deleted: next.deleted) }
        do { try commit(next); message = failure == nil ? nil : "部分数据暂未刷新，已保留本机记录。" }
        catch { message = "本机记录保存失败：" + error.localizedDescription }
        refreshing = false; publishActivity(); await synchronize()
        // GET /home only returns the server's cached snapshot. Like the web dashboard,
        // follow it with a Google Health pull. The server skips sources read within
        // 90 seconds, so repeated foregrounds stay cheap. The unstructured task keeps
        // a brief inactive scene phase from cancelling the pull.
        if stamp == epoch, phase == .ready { startHealthRefresh(); await ensureBrief() }
    }
    private func startHealthRefresh() {
        guard healthTask == nil else { return }
        healthTask = Task { await pullHealth(); healthTask = nil }
    }
    func foreground() async { guard phase == .ready else { return }; await refresh(); await openPending(); publishActivity(force: true) }
    func retrySync() {
        if storageFailed { do { try commit(cache) } catch { message = "本机存储仍不可用，请释放空间后重试。"; return } }
        syncTask?.cancel(); syncTask = nil; protectedSync()
    }
    /// Keeps uploading for a short while if the app is backgrounded or the phone locks,
    /// e.g. right after finishing a workout.
    private func protectedSync() {
        let assertion = BackgroundAssertion("pine-sync")
        Task {
            while syncing { try? await Task.sleep(for: .milliseconds(200)) }
            await synchronize(); assertion.end()
        }
    }
    /// Scene became active. Runs outside the view's task so a brief inactive phase
    /// (Control Center, notification banners) cannot cancel requests mid-flight.
    func becameActive() {
        guard phase == .ready, !isDesignPreview else { return }
        if let last = lastForeground, Date().timeIntervalSince(last) < 30 { Task { await openPending() }; publishActivity(force: true); return }
        lastForeground = Date()
        Task { await foreground() }
    }
    func enteredBackground() {
        guard phase == .ready, !isDesignPreview, records.contains(where: { $0.dirty && $0.blocked == nil }) else { return }
        syncTask?.cancel(); syncTask = nil; protectedSync()
    }
    func periodicSync() { guard phase == .ready, !syncing else { return }; Task { await synchronize() } }
    nonisolated static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }
    private func scheduleSync() {
        syncTask?.cancel(); syncTask = Task {
            do { try await Task.sleep(for: .milliseconds(600)) } catch { return }
            syncTask = nil
            await synchronize()
        }
    }
    func synchronize() async {
        guard !isDesignPreview, phase == .ready, !syncing, records.contains(where: { $0.dirty && $0.blocked == nil }) else { return }; syncing = true
        let stamp = epoch
        var savedAny = false
        defer { syncing = false }
        do {
            let deletions = try await api.request("/strength/session-deletions")
            guard stamp == epoch else { return }
            var next = cache; next.deleted.formUnion(deletions.array.map(\.id)); next.records = NativeRecordMerge.merge(next.records, remote: [], deleted: next.deleted); try commit(next)
            while let row = records.first(where: { $0.dirty && $0.blocked == nil }) {
                guard stamp == epoch, phase == .ready, !Task.isCancelled else { return }
                let sent = row.session
                do {
                    let saved = try await api.request("/strength/sessions/" + row.id, method: "PUT", body: ["session": sent, "expected_version": .number(Double(row.version))])
                    guard stamp == epoch, let current = cache.records[row.id], !cache.deleted.contains(row.id) else { return }
                    var next = cache; next.records[row.id] = NativeRecordMerge.acknowledge(current, sent: sent, response: saved); try commit(next); savedAny = true
                } catch let error as HealthAPIError {
                    guard stamp == epoch else { return }
                    if error.status == 401 { unauthorized(); return }
                    if error.status == 410 { var next = cache; next.deleted.insert(row.id); next.records.removeValue(forKey: row.id); try commit(next); continue }
                    if error.status == 409 || error.status == 422 {
                        let server = error.status == 409 ? try? await api.request("/strength/sessions/" + row.id) : nil
                        guard stamp == epoch, var current = cache.records[row.id] else { return }
                        if error.status == 422 && current.session != sent { continue }
                        current.blocked = error.message; current.server = server
                        var next = cache; next.records[row.id] = current; try commit(next)
                    }
                    message = error.message; break
                }
            }
            if savedAny {
                let home = try await api.request("/home")
                if stamp == epoch, phase == .ready { var next = cache; next.home = home; try commit(next) }
            }
        } catch { if !Task.isCancelled && !Self.isCancellation(error) { handle(error) } }
        publishActivity()
    }
    func update(_ id: String, _ change: (inout JSONValue) throws -> Void) {
        guard phase == .ready, !cache.deleted.contains(id), var record = cache.records[id] else { return }
        do {
            try change(&record.session); record.dirty = true
            if record.server == nil { record.blocked = nil }
            var next = cache; next.records[id] = record; try commit(next); scheduleSync(); publishActivity()
        } catch { message = error.localizedDescription }
    }
    func start(template: JSONValue = .null, remaining: JSONValue = .null) {
        if active != nil { workoutPresented = true; return }
        do {
            guard !cache.catalog.isNull else { throw TrainingError.invalid("请先联网加载动作和模板。") }
            let s = try NativeTraining.start(template: template, catalog: exercises, history: history, remaining: remaining)
            var next = cache; next.records[s.id] = NativeRecord(session: s, dirty: true); try commit(next)
            movementIndex = 0; UserDefaults.standard.set(0, forKey: Self.movementKey + s.id); if reportID != nil { deferredWorkout = true } else { workoutPresented = true }; scheduleSync(); publishActivity()
        } catch { message = error.localizedDescription }
    }
    func finish(_ id: String, discard: Bool = false) {
        update(id) { $0 = NativeTraining.finish($0, status: discard ? "discarded" : "completed") }
        guard cache.records[id]?.session["status"].text != "active" else { return }
        UserDefaults.standard.removeObject(forKey: Self.movementKey + id)
        if !discard { pendingReport = id; selectedTab = 2 }; workoutPresented = false
        retrySync()
    }
    func workoutDidDismiss() { if let id = pendingReport { pendingReport = nil; reportID = id } }
    func reportDidDismiss() { if deferredWorkout { deferredWorkout = false; workoutPresented = true } }
    func resolve(_ id: String, useLocal: Bool) {
        guard var row = cache.records[id], let server = row.server else { return }
        if useLocal { row.alternative = server["session"]; row.version = server["version"].integer; row.dirty = true }
        else { let alternative = row.session; row = NativeRecord(remote: server); row.alternative = alternative }
        row.server = nil; row.blocked = nil; var next = cache; next.records[id] = row
        do { try commit(next); retrySync(); publishActivity() } catch { handle(error) }
    }
    func clearAlternative(_ id: String) {
        var next = cache; next.records[id]?.alternative = nil
        do { try commit(next) } catch { handle(error) }
    }
    func delete(_ id: String) async throws {
        guard let row = cache.records[id], !row.dirty, row.blocked == nil else { throw TrainingError.invalid("请先同步这场训练，再删除。") }
        let stamp = epoch
        do { _ = try await api.request("/strength/sessions/" + id + "/delete", method: "POST", body: ["expected_version": .number(Double(row.version))]) }
        catch {
            if let status = (error as? HealthAPIError)?.status, status == 404 || status == 410 { }
            else {
                do { _ = try await api.request("/strength/sessions/" + id); throw error }
                catch let confirm as HealthAPIError where confirm.status == 404 || confirm.status == 410 { }
                catch { throw error }
            }
        }
        guard stamp == epoch else { return }; var next = cache; next.deleted.insert(id); next.records.removeValue(forKey: id); try commit(next)
        if reportID == id { reportID = nil }; await refresh()
    }
    func saveTemplate(_ template: JSONValue, version: Int) async throws {
        let stamp = epoch
        let saved = try await api.request("/strength/templates/" + template.id, method: "PUT", body: ["template": template, "expected_version": .number(Double(version))])
        guard stamp == epoch, phase == .ready else { throw CancellationError() }
        var next = cache; var rows = next.catalog["templates"].array; rows.removeAll { $0["template"].id == template.id }; rows.append(saved)
        next.catalog["templates"] = .array(rows); try commit(next)
    }
    func createExercise(_ exercise: JSONValue) async throws {
        let stamp = epoch
        let saved = try await api.request("/strength/exercises", method: "POST", body: exercise)
        guard stamp == epoch, phase == .ready else { throw CancellationError() }
        var next = cache; next.catalog["exercises"] = .array(exercises + [saved]); try commit(next)
    }
    func homeAction(_ action: JSONValue) {
        if !action["session_id"].isNull { pendingWorkout = action["session_id"].text; Task { await openPending() }; return }
        if let row = templates.first(where: { $0["template"].id == action["template_id"].text }) { start(template: row["template"], remaining: action["remaining"]) }
        else { selectedTab = 1 }
    }
    func mutateHome(_ path: String, method: String = "PUT", body: JSONValue? = nil) async throws {
        let stamp = epoch; let home = try await api.request(path, method: method, body: body, timeout: path == "/home/refresh" ? 90 : 25)
        guard stamp == epoch, phase == .ready else { return }; var next = cache; next.home = home; try commit(next)
    }
    /// Pulls the latest Google Health data; joins a pull that is already running.
    func refreshHealth() async {
        startHealthRefresh(); await healthTask?.value
    }
    private func pullHealth() async {
        guard !isDesignPreview, phase == .ready else { return }
        let partial = "部分来源暂未更新，保留了已有数据。"
        healthRefreshing = true; defer { healthRefreshing = false }
        do {
            try await mutateHome("/home/refresh", method: "POST")
            if !cache.home["refresh_failed"].array.isEmpty { message = partial } else if message == partial { message = nil }
            await loadBrief(); await ensureBrief()
        } catch {
            // Server errors (409 "Google Health 未连接", 401 → login) and local storage
            // failures are shown. Connectivity failures were already reported by
            // refresh(); a raw URLError text would only replace that clearer message.
            if !(error is URLError) && !Self.isCancellation(error) { handle(error) }
        }
    }
    /// `force` asks the server to write a fresh observation even when its inputs
    /// are unchanged (the manual "analyse now").
    func loadBrief(generate: Bool = false, force: Bool = false) async {
        let stamp = epoch
        do {
            let result = try await api.request(force ? "/home/brief?force=true" : "/home/brief", method: generate || force ? "POST" : "GET")
            guard stamp == epoch, phase == .ready else { return }; var next = cache; next.brief = Self.mergedBrief(next.brief, result); try commit(next)
        } catch { handle(error) }
    }
    /// The server only reports sentences while its inputs are unchanged. Keep the
    /// period's last ready observation on screen until a newer one is ready.
    nonisolated static func mergedBrief(_ old: JSONValue, _ new: JSONValue) -> JSONValue {
        guard new["sentences"].array.isEmpty, !old["sentences"].array.isEmpty,
              old["date"] == new["date"], old["period"] == new["period"] else { return new }
        var kept = new; kept["sentences"] = old["sentences"]; kept["generated_at"] = old["generated_at"]; return kept
    }
    /// Like the web dashboard: ask the server to write the current period's
    /// observation when none is ready. At most once per period every two hours,
    /// so changing inputs (steps through the day) do not regenerate it repeatedly.
    func ensureBrief() async {
        guard !isDesignPreview, phase == .ready else { return }
        let status = cache.brief["status"].text
        let current = !cache.brief["sentences"].array.isEmpty && status == "ready"
        guard !current, status != "pending", !cache.brief["date"].text.isEmpty else { return }
        let key = "pine.brief.requested." + cache.brief["date"].text + "." + cache.brief["period"].text
        // A failed generation is retried sooner than a merely outdated one.
        let wait: TimeInterval = status == "error" ? 20 * 60 : 2 * 3600
        if let last = UserDefaults.standard.object(forKey: key) as? Date, Date().timeIntervalSince(last) < wait { return }
        UserDefaults.standard.set(Date(), forKey: key)
        await loadBrief(generate: true)
    }
    func open(_ url: URL) { guard let id = HealthRoute.workoutID(from: url) else { return }; pendingWorkout = id; Task { await openPending() } }
    private func openPending() async {
        guard phase == .ready, let id = pendingWorkout else { return }
        if cache.deleted.contains(id) { pendingWorkout = nil; message = "这场训练已删除。"; return }
        if cache.records[id] == nil {
            do { let row = try await api.request("/strength/sessions/" + id); var next = cache; next.records = NativeRecordMerge.merge(next.records, remote: [row], deleted: next.deleted); try commit(next) }
            catch { handle(error); return }
        }
        pendingWorkout = nil
        // Opening from the Lock Screen or a rest reminder keeps the movement being recorded.
        if let row = cache.records[id], row.session["status"].text == "active" { if active?.id != id { movementIndex = resumeIndex(row.session) }; workoutPresented = true }
        else { reportID = id; selectedTab = 2 }
    }
    func logout() async throws {
        guard !pending else { throw TrainingError.invalid("训练或冲突副本尚未处理，请先同步并处理后再退出。") }
        try await api.logout(); epoch = UUID(); syncTask?.cancel(); workoutPresented = false; reportID = nil
        checkpointDelay?.cancel(); await checkpointTask?.value
        if let cacheURL {
            try? FileManager.default.removeItem(at: cacheURL)
            try? FileManager.default.removeItem(at: NativeCacheDisk.journalURL(for: cacheURL))
        }; cacheURL = nil; cacheRevision = 0
        cache = NativeCacheState(); username = ""; phase = .login; showingSettings = false; publishActivity()
    }
    func handle(_ error: Error) { if (error as? HealthAPIError)?.status == 401 { unauthorized() } else { message = error.localizedDescription } }
    private func unauthorized() { epoch = UUID(); syncTask?.cancel(); phase = .login; workoutPresented = false; showingSettings = false; publishActivity() }
    func selectMovement(_ index: Int) {
        movementIndex = index
        if let id = active?.id { UserDefaults.standard.set(index, forKey: Self.movementKey + id) }
        publishActivity()
    }
    private static let movementKey = "pine.workout.movement."
    /// The saved selection for this workout, else the movement of the latest completed set.
    private func resumeIndex(_ session: JSONValue) -> Int {
        let count = session["exercises"].array.count
        if let saved = UserDefaults.standard.object(forKey: Self.movementKey + session.id) as? Int, (0..<count).contains(saved) { return saved }
        return NativeTraining.resumeIndex(session)
    }
    func publishActivity(force: Bool = false) {
        guard !isDesignPreview else { return }
        activityForce = activityForce || force
        activityRevision += 1; guard !publishing else { return }; publishing = true
        Task {
            var handled = -1
            while handled != activityRevision {
                handled = activityRevision
                let force = activityForce; activityForce = false
                let snapshot = phase == .ready ? active.flatMap { NativeTraining.snapshot($0.session, movement: movementIndex) } : nil
                do { try await coordinator.sync(snapshot, force: force) } catch { message = error.localizedDescription }
            }; publishing = false
        }
    }
    private func importedSessions() -> [JSONValue] {
        cache.imported.array.enumerated().map { index, workout in
            let movements = workout["movements"].array.compactMap { old -> JSONValue? in
                guard let exercise = exercises.first(where: { $0["name"] == old["name"] || $0.id == old["exercise_id"].text }) else { return nil }
                let mode: JSONValue = old["exetype"].text == "help" ? "assistance" : old["exetype"].text == "self" ? "bodyweight" : exercise["load_mode"]
                let rows = old["sets"].array.filter { $0["done"].flag }.map { row -> JSONValue in var s = row; s["completed_at"] = .string(workout["datestr"].text); return s }
                return ["id": .string("import-\(index)"), "exercise_id": exercise["id"], "name": old["name"], "load_mode": mode,
                        "unit": old["sets"][0]["unit"].or("lb"), "tracking": "reps", "sets": .array(rows)]
            }
            return ["id": .string("import-\(index)-" + workout["datestr"].text), "title": workout["title"], "status": "completed",
                    "started_at": workout["datestr"], "ended_at": nil, "exercises": .array(movements)]
        }
    }
}

/// One UIKit background-time request; ended explicitly or when iOS reclaims it.
@MainActor
private final class BackgroundAssertion {
    private var id = UIBackgroundTaskIdentifier.invalid
    init(_ name: String) {
        id = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in MainActor.assumeIsolated { self?.end() } }
    }
    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id); id = .invalid
    }
}

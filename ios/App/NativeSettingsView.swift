import SwiftUI

struct NativeSettingsView: View {
    @Environment(NativeStore.self) var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var live = true
    @State private var reminders = false
    @State private var chime = true
    @State private var activitiesAllowed = true
    @State private var permission = ""
    @State private var google: Bool?
    @State private var error: String?
    @State private var busy = false
    @State private var signingOut = false
    var body: some View {
        Form {
            Section("训练") {
                Toggle("训练实况", isOn: Binding(get: { live }, set: { value in change { await store.coordinator.setLiveActivities(value) } })).disabled(busy)
                if !activitiesAllowed { Text("系统未允许训练实况，可在 iPhone 设置中查看。").font(.footnote).foregroundStyle(.secondary) }
                Toggle("休息结束提示音", isOn: Binding(get: { chime }, set: { value in store.coordinator.setRestChime(value); chime = value }))
                Toggle("组间休息提醒", isOn: Binding(get: { reminders }, set: { value in change { if value { try await store.coordinator.enableRestReminders() } else { store.coordinator.disableRestReminders() } } })).disabled(busy)
                if permission == "denied" { Button("在系统设置中开启通知") { if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) } } }
            }
            Section("连接") {
                PineRow(label: "健康服务器", value: "health.frankandpatrick.com")
                PineRow(label: "账号", value: store.username)
                PineRow(label: "Google Health", value: google == nil ? "读取中" : google == true ? "已连接" : "未连接")
                PineRow(label: "ChatGPT", value: integrationConnected ? "已连接" : "请查看服务器配置")
                Button("重新读取数据", systemImage: "arrow.clockwise") { Task { await store.refresh(); await load() } }.disabled(store.refreshing)
                Link("在浏览器中管理 Google Health 授权", destination: URL(string: "https://health.frankandpatrick.com/")!)
            }
            Section {
                PineRow(label: "本机训练同步", value: store.syncing ? "同步中" : store.pending ? "有待处理记录" : "已同步")
                Button("立即同步") { store.retrySync() }.disabled(store.syncing)
                ForEach(store.records.filter { $0.alternative != nil }, id: \.id) { row in NavigationLink("冲突副本 · " + row.session["title"].text) { NativeAlternativeView(id: row.id) } }
            } header: { Text("记录") } footer: { Text("训练先保存在本机，再同步至现有服务器。退出登录前需同步并处理保留的冲突副本。") }
            Section {
                PineRow(label: "分析通知", value: store.integrations["notifications"]["enabled"].flag ? "Telegram 已连接" : "未配置 Telegram")
                Text("此 App 提供组间休息的本地提醒。分析报告沿用服务器的 Telegram 或主屏幕网页推送。").font(.footnote).foregroundStyle(.secondary)
            } header: { Text("通知") }
            if let error { Section { Text(error).foregroundStyle(.red) } }
            Section { Button("退出登录", role: .destructive) { signingOut = true }.disabled(busy) }
            Section { PineRow(label: "版本", value: NativeBuildInfo.text); NavigationLink("开源许可") { NativeLicenseView() }; Link("服务器备份与隐私", destination: URL(string: "https://health.frankandpatrick.com/server-backup-privacy.html")!) }
        }.navigationTitle("设置").toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .task { await load() }
            .confirmationDialog("退出当前账号？", isPresented: $signingOut, titleVisibility: .visible) { Button("退出登录", role: .destructive) { busy = true; Task { do { try await store.logout() } catch { self.error = error.localizedDescription }; busy = false } } } message: { Text("已同步的数据保留在服务器。本机登录状态和缓存会清除。") }
    }
    private var integrationConnected: Bool { let c = store.integrations["chatgpt"]; return c["connected"].flag || c["authenticated"].flag || c["status"].text == "connected" }
    private func load() async {
        let status = await store.coordinator.status(); live = status.liveActivitiesEnabled; reminders = status.restRemindersEnabled
        chime = status.restChimeEnabled; activitiesAllowed = status.activitiesAllowed; permission = status.notificationPermission.rawValue
        error = status.activityError ?? status.reminderError
        do { google = try await store.api.request("/auth/status")["authenticated"].flag } catch { store.handle(error) }
    }
    private func change(_ action: @escaping () async throws -> Void) { busy = true; Task { do { try await action(); await load() } catch { self.error = error.localizedDescription }; busy = false } }
}
struct NativeAlternativeView: View {
    @Environment(NativeStore.self) var store
    let id: String
    @State private var deleting = false
    var body: some View {
        PinePage {
            if let alternative = store.recordDocuments[id]?.alternative {
                PineHeading(title: alternative["title"].text, subtitle: "冲突解决时保留的另一份记录")
                ForEach(Array(alternative["exercises"].array.enumerated()), id: \.offset) { _, m in VStack(alignment: .leading, spacing: 10) { Text(m["name"].text).font(.headline); ForEach(Array(m["sets"].array.enumerated()), id: \.offset) { _, row in Text((row["completed_at"].isNull ? "未完成 · " : "") + loadText(m,row)).font(.subheadline) } }.pineCard() }
                ShareLink("导出副本", item: String(data: (try? alternative.data()) ?? Data(), encoding: .utf8) ?? "")
                Button("清除保留的副本", role: .destructive) { deleting = true }
            } else { PineEmpty(title: "副本已清除", symbol: "checkmark.circle") }
        }.navigationTitle("保留的副本").confirmationDialog("清除这份本机副本？", isPresented: $deleting, titleVisibility: .visible) { Button("清除副本", role: .destructive) { store.clearAlternative(id) } }
    }
}

/// "1.3.0 (118) · 4d00324": the build number rises with every CI run and the
/// commit identifies exactly which code is installed.
enum NativeBuildInfo {
    static var text: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? ""
        let build = info["CFBundleVersion"] as? String ?? ""
        let commit = info["PineCommit"] as? String ?? ""
        return version + (build.isEmpty ? "" : " (\(build))") + (commit.isEmpty || commit == "local" ? "" : " · " + commit)
    }
}

import Foundation

public enum HealthTab: String, Codable, CaseIterable, Sendable {
    case dashboard, strength, workout, sleep
    public var title: String {
        switch self {
        case .dashboard: return "总览"
        case .strength: return "训练"
        case .workout: return "运动记录"
        case .sleep: return "睡眠"
        }
    }
    public var symbol: String {
        switch self {
        case .dashboard: return "square.grid.2x2"
        case .strength: return "dumbbell"
        case .workout: return "list.clipboard"
        case .sleep: return "moon"
        }
    }
}

public struct NativeChromeState: Codable, Equatable, Sendable {
    public enum Screen: String, Codable, Sendable { case home, workout, report }
    public let protocolVersion: Int
    public let authenticated: Bool
    public let tab: HealthTab
    public let screen: Screen
    public let title: String
    public let workoutID: String?
    public let googleConnected: Bool?
    public let webDialogOpen: Bool
    public let bottomOverlay: Bool?

    public static let initial = NativeChromeState(protocolVersion: 1, authenticated: false, tab: .dashboard,
        screen: .home, title: "总览", workoutID: nil, googleConnected: nil, webDialogOpen: false, bottomOverlay: nil)
    public var showsNavigation: Bool { authenticated && !webDialogOpen }
    public var showsTabs: Bool { authenticated && !webDialogOpen && screen != .workout }

    public func validated() throws -> NativeChromeState {
        guard protocolVersion == 1, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              title.count <= 100, screen == .home || (authenticated && tab == .strength),
              screen == .home ? workoutID == nil : UUID(uuidString: workoutID ?? "") != nil
        else { throw NativePayloadError.invalid }
        return self
    }
}

public struct NativeMenuRequest: Decodable {
    public struct Action: Decodable {
        public let id: String
        public let title: String
    }
    public let title: String
    public let actions: [Action]
    public func validated() throws -> NativeMenuRequest {
        guard !title.isEmpty, title.count <= 100, (1...40).contains(actions.count),
              Set(actions.map(\.id)).count == actions.count,
              actions.allSatisfy({ !$0.id.isEmpty && $0.id.count <= 80 && !$0.title.isEmpty && $0.title.count <= 160 })
        else { throw NativePayloadError.invalid }
        return self
    }
}

public struct NativeConfirmationRequest: Decodable {
    public let title: String
    public let message: String
    public let confirmLabel: String
    public let destructive: Bool
    public func validated() throws -> NativeConfirmationRequest {
        guard !title.isEmpty, title.count <= 100, message.count <= 500,
              !confirmLabel.isEmpty, confirmLabel.count <= 40 else { throw NativePayloadError.invalid }
        return self
    }
}

public enum NativePayloadError: LocalizedError {
    case invalid
    public var errorDescription: String? { "无法识别页面状态，请刷新后重试。" }
}

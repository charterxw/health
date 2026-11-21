import Foundation

/// The fields of `GET /api/home` the overview depends on, as types. A renamed or
/// retyped field fails here, where it can be reported, instead of showing up as a
/// quiet "—" in the interface. The raw document stays the source for everything else.
///
/// Keep in step with `backend/tests/test_home_contract.py` and the synthetic
/// sample in `docs/contracts/home-summary.json`, which both sides check.
public struct NativeHome: Decodable, Equatable, Sendable {
    public struct Day: Decodable, Equatable, Sendable {
        public let date: String
        public let short: String
        public let activity: Double?
        public let sets: Int
        public let target: Int
        public let posture: Bool
        public let posturePlanned: Bool
        public let strengthPlanned: Bool
        public let strengthOptional: Bool
        enum CodingKeys: String, CodingKey {
            case date, short, activity, sets, target, posture
            case posturePlanned = "posture_planned", strengthPlanned = "strength_planned", strengthOptional = "strength_optional"
        }
    }
    public struct Goals: Decodable, Equatable, Sendable {
        public let dailyActivity: Double
        public let weeklyActivity: Double
        public let weeklyStrength: Int
        public let weeklyPosture: Int
    }
    public struct StepGoal: Decodable, Equatable, Sendable { public let target: Double }
    public struct Recovery: Decodable, Equatable, Sendable {
        public let score: Double?
        public let label: String?
    }
    public struct Feedback: Decodable, Equatable, Sendable {
        public let energy: String?
        public let fatigue: String?
        public let soreness: [String]?
        public let stress: String?
        public let note: String?
    }
    public let date: String
    public let timezone: String
    public let days: [Day]
    public let goals: Goals
    public let stepGoal: StepGoal
    public let recovery: Recovery
    public let feedback: Feedback
    public let nextEffective: String
    enum CodingKeys: String, CodingKey {
        case date, timezone, days, goals, recovery, feedback
        case stepGoal = "step_goal", nextEffective = "next_effective"
    }

    public init(_ document: JSONValue) throws {
        self = try JSONDecoder().decode(Self.self, from: document.data())
    }

    /// The decoding failure in words for the sync page: which field, and what went wrong.
    public static func problem(_ document: JSONValue) -> String? {
        do { _ = try NativeHome(document); return nil }
        catch let DecodingError.keyNotFound(key, context) { return "缺少字段 " + path(context.codingPath + [key]) }
        catch let DecodingError.typeMismatch(_, context) { return "字段类型不符 " + path(context.codingPath) }
        catch let DecodingError.valueNotFound(_, context) { return "字段为空 " + path(context.codingPath) }
        catch { return "无法读取：" + error.localizedDescription }
    }
    private static func path(_ keys: [CodingKey]) -> String {
        keys.map { $0.intValue.map { "[\($0)]" } ?? $0.stringValue }.joined(separator: ".").replacingOccurrences(of: ".[", with: "[")
    }
}

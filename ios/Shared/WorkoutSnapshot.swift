import Foundation

// Deliberately excludes heart data, notes, credentials and API tokens. Weights and
// reps appear only as the next set's plan while resting, so the lifter can set
// up without unlocking; edits while training never change the payload.
public struct WorkoutSnapshot: Codable, Hashable, Sendable {
    public enum ActivityPhase: Equatable {
        case training, resting, paused, pausedRest, restFinished, stale
    }
    public let protocolVersion: Int
    public let sessionID: String
    public let title: String
    public let startedAt: Date
    public let pausedAt: Date?
    public let pausedSeconds: TimeInterval
    public let restUntil: Date?
    public let movementName: String
    public let movementIndex: Int
    public let movementCount: Int
    public let completedSets: Int
    public let plannedSets: Int
    public let currentSet: Int
    public let movementSetCount: Int
    /// While resting: the next set, e.g. "侧平举 · 20 磅 × 12". Nil otherwise.
    public var nextSet: String? = nil
    /// The set the Lock Screen "完成本组" button would check off: the current move's
    /// first unfinished set. Nil while paused or when the move is done.
    public var openSetID: String? = nil

    enum ValidationError: Error { case invalidSnapshot }

    public func validated(at now: Date = Date()) throws -> WorkoutSnapshot {
        guard protocolVersion == 1, UUID(uuidString: sessionID) != nil,
              !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              title.count <= 100, movementName.count <= 100,
              startedAt.timeIntervalSince1970.isFinite,
              startedAt <= now.addingTimeInterval(300),
              startedAt >= now.addingTimeInterval(-7 * 24 * 3600),
              pausedSeconds.isFinite, pausedSeconds >= 0,
              pausedSeconds <= max(0, now.timeIntervalSince(startedAt)) + 300,
              (0...40).contains(movementCount),
              (0...2000).contains(plannedSets), (0...plannedSets).contains(completedSets),
              (0...50).contains(movementSetCount), (0...movementSetCount).contains(currentSet),
              movementCount == 0 ? movementIndex == 0 : (1...movementCount).contains(movementIndex),
              (nextSet?.count ?? 0) <= 60, (openSetID?.count ?? 0) <= 64
        else { throw ValidationError.invalidSnapshot }
        if let pausedAt {
            guard pausedAt >= startedAt, pausedAt <= now.addingTimeInterval(300) else { throw ValidationError.invalidSnapshot }
        }
        if let restUntil {
            guard restUntil.timeIntervalSince1970.isFinite, restUntil >= startedAt,
                  restUntil <= (pausedAt ?? now).addingTimeInterval(601)
            else { throw ValidationError.invalidSnapshot }
        }
        return self
    }

    public var effectiveStartedAt: Date { startedAt.addingTimeInterval(pausedSeconds) }
    public func elapsed(at now: Date = Date()) -> TimeInterval {
        max(0, floor((pausedAt ?? now).timeIntervalSince(startedAt) - pausedSeconds))
    }
    public func restRemaining(at now: Date = Date()) -> TimeInterval {
        guard let restUntil else { return 0 }
        return max(0, ceil(restUntil.timeIntervalSince(pausedAt ?? now)))
    }
    public func reminderDate(at now: Date = Date()) -> Date? {
        guard pausedAt == nil, let restUntil, restUntil > now else { return nil }
        return restUntil
    }
    public func activityPhase(at now: Date = Date(), stale: Bool = false) -> ActivityPhase {
        if pausedAt != nil { return restRemaining(at: now) > 0 ? .pausedRest : .paused }
        if let restUntil { return restUntil > now && !stale ? .resting : .restFinished }
        return stale ? .stale : .training
    }

    public func activityStaleDate(at now: Date = Date()) -> Date {
        reminderDate(at: now) ?? now.addingTimeInterval(2 * 3600)
    }
    public static func clock(_ duration: TimeInterval) -> String {
        let value = Int(max(0, duration))
        return String(format: "%02d:%02d", value / 60, value % 60)
    }
    public static func decode(_ data: Data) throws -> WorkoutSnapshot {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode(Self.self, from: data)
    }
}

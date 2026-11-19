import Foundation

/// Lossless API documents keep server-owned fields intact across native edits.
public enum JSONValue: Codable, Equatable, Sendable, ExpressibleByDictionaryLiteral,
                       ExpressibleByArrayLiteral, ExpressibleByStringLiteral,
                       ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral,
                       ExpressibleByBooleanLiteral, ExpressibleByNilLiteral {
    case object([String: JSONValue]), array([JSONValue]), string(String), number(Double), bool(Bool), null

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    public init(dictionaryLiteral elements: (String, JSONValue)...) { self = .object(Dictionary(elements, uniquingKeysWith: { _, v in v })) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(nilLiteral: ()) { self = .null }
    public subscript(_ key: String) -> JSONValue {
        get { if case .object(let v) = self { return v[key] ?? .null }; return .null }
        set { var v = object; v[key] = newValue; self = .object(v) }
    }
    public subscript(_ index: Int) -> JSONValue {
        get { array.indices.contains(index) ? array[index] : .null }
        set { var v = array; guard v.indices.contains(index) else { return }; v[index] = newValue; self = .array(v) }
    }
    public var object: [String: JSONValue] { if case .object(let v) = self { return v }; return [:] }
    public var array: [JSONValue] { if case .array(let v) = self { return v }; return [] }
    public var text: String { if case .string(let v) = self { return v }; return "" }
    public var number: Double? { if case .number(let v) = self { return v }; return nil }
    public var integer: Int { number.flatMap { $0.isFinite && abs($0) < Double(Int.max) ? Int($0) : nil } ?? 0 }
    public var flag: Bool { if case .bool(let v) = self { return v }; return false }
    public var isNull: Bool { self == .null }
    public var id: String { self["id"].text }
    public func or(_ fallback: JSONValue) -> JSONValue { isNull ? fallback : self }
    public static func value(_ v: Double?) -> JSONValue { v.map(JSONValue.number) ?? .null }
    public static func value(_ v: String?) -> JSONValue { v.map(JSONValue.string) ?? .null }
    public static func read(_ data: Data) throws -> JSONValue { try JSONDecoder().decode(Self.self, from: data) }
    public func data() throws -> Data { let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]; return try e.encode(self) }
}

public enum NativeDate {
    private final class Formatters: @unchecked Sendable {
        let lock = NSLock()
        let fractional = ISO8601DateFormatter()
        let seconds = ISO8601DateFormatter()
        let parsed = NSCache<NSString, NSDate>()
        var labels: [String: DateFormatter] = [:]
        init() {
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            seconds.formatOptions = [.withInternetDateTime]
            parsed.countLimit = 8192
        }
    }
    private static let cached = Formatters()
    public static func parse(_ value: JSONValue) -> Date? { parse(value.text) }
    public static func parse(_ value: String) -> Date? {
        guard !value.isEmpty else { return nil }
        if let found = cached.parsed.object(forKey: value as NSString) { return found as Date }
        cached.lock.lock(); defer { cached.lock.unlock() }
        let date = cached.fractional.date(from: value) ?? cached.seconds.date(from: value)
        if let date { cached.parsed.setObject(date as NSDate, forKey: value as NSString) }
        return date
    }
    public static func stamp(_ date: Date = Date()) -> JSONValue {
        cached.lock.lock(); defer { cached.lock.unlock() }
        return .string(cached.fractional.string(from: date))
    }
    public static func day(_ date: Date, timezone: String) -> String {
        label(date, format: "yyyy-MM-dd", timezone: timezone, locale: "en_US_POSIX")
    }
    public static func label(_ date: Date, format: String, timezone: String, locale: String = "zh_CN") -> String {
        cached.lock.lock(); defer { cached.lock.unlock() }
        let key = locale + "|" + timezone + "|" + format
        let formatter: DateFormatter
        if let existing = cached.labels[key] { formatter = existing }
        else {
            formatter = DateFormatter(); formatter.locale = Locale(identifier: locale)
            formatter.timeZone = TimeZone(identifier: timezone) ?? .current; formatter.dateFormat = format
            cached.labels[key] = formatter
        }
        return formatter.string(from: date)
    }
    public static func dayLabel(_ key: String, format: String) -> String {
        guard let date = parse(key + "T12:00:00Z") else { return key }
        return label(date, format: format, timezone: "UTC")
    }
}

public struct NativeRecord: Codable, Equatable, Sendable {
    public var session: JSONValue
    public var version: Int
    public var dirty: Bool
    public var blocked: String?
    public var server: JSONValue?
    public var alternative: JSONValue?
    public init(session: JSONValue, version: Int = 0, dirty: Bool = false) {
        self.session = session; self.version = version; self.dirty = dirty
    }
    public init(remote: JSONValue) { self.init(session: remote["session"], version: remote["version"].integer) }
    public var id: String { session.id }
}

public enum NativeRecordMerge {
    public static func merge(_ local: [String: NativeRecord], remote: [JSONValue], deleted: Set<String>) -> [String: NativeRecord] {
        var next = local
        for value in remote {
            let row = NativeRecord(remote: value)
            guard !row.id.isEmpty, !deleted.contains(row.id) else { continue }
            if let old = next[row.id], old.dirty || old.blocked != nil || old.version > row.version { continue }
            var saved = row; saved.alternative = next[row.id]?.alternative; next[row.id] = saved
        }
        for id in deleted { next.removeValue(forKey: id) }
        return next
    }
    /// An edit made while a save is in flight must remain dirty at the new version.
    public static func acknowledge(_ current: NativeRecord, sent: JSONValue, response: JSONValue) -> NativeRecord {
        var next = current; next.version = response["version"].integer; next.dirty = current.session != sent
        if !next.dirty { next.session = response["session"] }
        next.blocked = nil; next.server = nil; return next
    }
}

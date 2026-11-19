import Foundation

public struct NativeCacheState: Codable, Equatable, Sendable {
    public var records: [String: NativeRecord] = [:]
    public var deleted: Set<String> = []
    public var catalog: JSONValue = .null
    public var home: JSONValue = .null
    public var imported: JSONValue = []
    public var observations: JSONValue = []
    public var brief: JSONValue = .null
    public var integrations: JSONValue = .null
    public var checkpointRevision: UInt64?
    public init() {}
}

public struct NativeCacheDelta: Codable, Sendable {
    public let revision: UInt64
    public let records: [String: NativeRecord]
    public let removed: Set<String>
    public let deleted: Set<String>?
    public let metadata: [String: JSONValue]
    public var isEmpty: Bool { records.isEmpty && removed.isEmpty && deleted == nil && metadata.isEmpty }
    public init(previous: NativeCacheState, next: NativeCacheState, revision: UInt64) {
        self.revision = revision
        records = next.records.filter { previous.records[$0.key] != $0.value }
        removed = Set(previous.records.keys).subtracting(next.records.keys)
        deleted = previous.deleted == next.deleted ? nil : next.deleted
        var changes: [String: JSONValue] = [:]
        if previous.catalog != next.catalog { changes["catalog"] = next.catalog }
        if previous.home != next.home { changes["home"] = next.home }
        if previous.imported != next.imported { changes["imported"] = next.imported }
        if previous.observations != next.observations { changes["observations"] = next.observations }
        if previous.brief != next.brief { changes["brief"] = next.brief }
        if previous.integrations != next.integrations { changes["integrations"] = next.integrations }
        metadata = changes
    }
    public func applying(to previous: NativeCacheState) -> NativeCacheState {
        var next = previous
        next.records.merge(records) { _, new in new }
        for id in removed { next.records.removeValue(forKey: id) }
        if let deleted { next.deleted = deleted }
        for (key, value) in metadata {
            switch key {
            case "catalog": next.catalog = value
            case "home": next.home = value
            case "imported": next.imported = value
            case "observations": next.observations = value
            case "brief": next.brief = value
            case "integrations": next.integrations = value
            default: break
            }
        }
        return next
    }
}

/// Edits append one small, atomic transaction before the UI reports success.
/// Full snapshots run off the main thread and never hold up journal appends.
public enum NativeCacheDisk {
    private static let checkpointQueue = DispatchQueue(label: "com.pine.cache-checkpoints", qos: .utility)
    public static func journalURL(for url: URL) -> URL { url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + ".journal", isDirectory: true) }
    public static func load(at url: URL) throws -> (state: NativeCacheState, revision: UInt64) {
        let files = FileManager.default
        var state = files.fileExists(atPath: url.path) ? try JSONDecoder().decode(NativeCacheState.self, from: Data(contentsOf: url)) : NativeCacheState()
        var revision = state.checkpointRevision ?? 0
        state.checkpointRevision = nil
        let folder = journalURL(for: url)
        if files.fileExists(atPath: folder.path) {
            let entries = try files.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            for entry in entries {
                let sequence = UInt64(entry.deletingPathExtension().lastPathComponent)
                guard let sequence else { continue }
                if sequence <= revision { continue }
                let delta = try JSONDecoder().decode(NativeCacheDelta.self, from: Data(contentsOf: entry))
                guard delta.revision == sequence else { throw CocoaError(.fileReadCorruptFile) }
                state = delta.applying(to: state); revision = sequence
            }
        }
        return (state, revision)
    }
    public static func append(_ delta: NativeCacheDelta, at url: URL) throws {
        guard !delta.isEmpty else { return }
        let folder = journalURL(for: url)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = String(format: "%020llu", delta.revision) + ".json"
        try JSONEncoder().encode(delta).write(to: folder.appendingPathComponent(name), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    public static func checkpoint(_ state: NativeCacheState, revision: UInt64, at url: URL) throws {
        try checkpointQueue.sync {
            struct Header: Decodable { let checkpointRevision: UInt64? }
            if let data = try? Data(contentsOf: url), let header = try? JSONDecoder().decode(Header.self, from: data), (header.checkpointRevision ?? 0) >= revision { return }
            var snapshot = state; snapshot.checkpointRevision = revision
            try JSONEncoder().encode(snapshot).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            let folder = journalURL(for: url)
            guard FileManager.default.fileExists(atPath: folder.path) else { return }
            for entry in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) where entry.pathExtension == "json" {
                if let sequence = UInt64(entry.deletingPathExtension().lastPathComponent), sequence <= revision { try FileManager.default.removeItem(at: entry) }
            }
        }
    }
}

import Foundation

/// Reads/writes the widget snapshot in the shared App Group container.
enum SnapshotStore {
    static let appGroupID = "4JAWF8AN8G.com.askasen.PoolMonitor"
    static let fileName = "snapshot.json"

    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
    }

    static var fileURL: URL? { containerURL?.appendingPathComponent(fileName) }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// Atomic write (temp file + rename).
    static func write(_ snapshot: PoolWidgetSnapshot, to url: URL? = fileURL) throws {
        guard let url else { throw CocoaError(.fileNoSuchFile) }
        let data = try encoder.encode(snapshot)
        try data.write(to: url, options: .atomic)
    }

    /// Returns nil when no snapshot exists or it is unreadable / from an unknown future schema.
    static func read(from url: URL? = fileURL) -> PoolWidgetSnapshot? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return decode(data)
    }

    static func decode(_ data: Data) -> PoolWidgetSnapshot? {
        guard let snap = try? decoder.decode(PoolWidgetSnapshot.self, from: data),
              snap.schemaVersion <= PoolWidgetSnapshot.currentSchemaVersion else { return nil }
        return snap
    }
}

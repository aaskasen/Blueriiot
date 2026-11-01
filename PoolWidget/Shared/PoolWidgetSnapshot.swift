import Foundation

/// One timestamped sensor value. `date` is the *measurement* time reported by the cloud.
struct TimedValue: Codable, Hashable, Sendable {
    let date: Date
    let value: Double
}

/// Outcome of the host app's most recent refresh attempt.
/// Staleness of the *sensor reading* is derived separately (see `PoolWidgetSnapshot.displayState`).
enum SourceStatus: String, Codable, Sendable {
    case healthy               // last refresh succeeded
    case offline               // last refresh failed (network/server); data may be from an earlier refresh
    case authenticationNeeded  // credentials rejected
    case notConfigured         // no credentials saved yet
}

/// Server-provided ranges for a metric, from lastMeasurements:
/// `ok_min`/`ok_max` (good), `warning_low`/`warning_high` (beyond = bad), `gauge_min`/`gauge_max` (scale).
/// The optional bounds were added later; older snapshots decode with them nil.
struct MetricRange: Codable, Hashable, Sendable {
    let min: Double
    let max: Double
    var warningLow: Double? = nil
    var warningHigh: Double? = nil
    var gaugeMin: Double? = nil
    var gaugeMax: Double? = nil
}

enum Metric: String, Codable, CaseIterable, Sendable {
    case temperature, ph, orp, conductivity
}

/// Versioned snapshot written by the host app into the App Group container.
/// Contains no credentials or tokens.
struct PoolWidgetSnapshot: Codable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int = PoolWidgetSnapshot.currentSchemaVersion
    var poolID: String
    var poolName: String
    var deviceName: String?
    /// Sensor measurement time of the latest reading (NOT when we fetched it).
    var measuredAt: Date?
    /// When the host app last fetched data successfully.
    var fetchedAt: Date
    /// When the host app last *tried* to refresh (success or failure).
    var lastAttemptAt: Date?
    var temperatureC: Double?
    var ph: Double?
    var orpMillivolts: Double?
    var conductivityValue: Double?
    var conductivityUnit: String?
    var temperatureHistory: [TimedValue] = []
    var phHistory: [TimedValue] = []
    var orpHistory: [TimedValue] = []
    var conductivityHistory: [TimedValue] = []
    var ranges: [Metric: MetricRange] = [:]
    var batteryLow: Bool?
    var viaExtender: Bool?
    var sourceStatus: SourceStatus
    /// True only for preview/development fixtures. Views label these visibly.
    var isMock: Bool = false

    func value(_ m: Metric) -> Double? {
        switch m {
        case .temperature: temperatureC
        case .ph: ph
        case .orp: orpMillivolts
        case .conductivity: conductivityValue
        }
    }

    func history(_ m: Metric) -> [TimedValue] {
        switch m {
        case .temperature: temperatureHistory
        case .ph: phHistory
        case .orp: orpHistory
        case .conductivity: conductivityHistory
        }
    }

    /// Placeholder used when nothing has been written yet.
    static func notConfigured(now: Date = .now) -> PoolWidgetSnapshot {
        PoolWidgetSnapshot(poolID: "", poolName: "Pool", measuredAt: nil, fetchedAt: now, sourceStatus: .notConfigured)
    }
}

// Dictionary<Metric, _> encodes as an array by default; encode as an object keyed by rawValue instead.
extension PoolWidgetSnapshot {
    enum CodingKeys: String, CodingKey {
        case schemaVersion, poolID, poolName, deviceName, measuredAt, fetchedAt, lastAttemptAt
        case temperatureC, ph, orpMillivolts, conductivityValue, conductivityUnit
        case temperatureHistory, phHistory, orpHistory, conductivityHistory
        case ranges, batteryLow, viaExtender, sourceStatus, isMock
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        poolID = try c.decode(String.self, forKey: .poolID)
        poolName = try c.decode(String.self, forKey: .poolName)
        deviceName = try c.decodeIfPresent(String.self, forKey: .deviceName)
        measuredAt = try c.decodeIfPresent(Date.self, forKey: .measuredAt)
        fetchedAt = try c.decode(Date.self, forKey: .fetchedAt)
        lastAttemptAt = try c.decodeIfPresent(Date.self, forKey: .lastAttemptAt)
        temperatureC = try c.decodeIfPresent(Double.self, forKey: .temperatureC)
        ph = try c.decodeIfPresent(Double.self, forKey: .ph)
        orpMillivolts = try c.decodeIfPresent(Double.self, forKey: .orpMillivolts)
        conductivityValue = try c.decodeIfPresent(Double.self, forKey: .conductivityValue)
        conductivityUnit = try c.decodeIfPresent(String.self, forKey: .conductivityUnit)
        temperatureHistory = try c.decodeIfPresent([TimedValue].self, forKey: .temperatureHistory) ?? []
        phHistory = try c.decodeIfPresent([TimedValue].self, forKey: .phHistory) ?? []
        orpHistory = try c.decodeIfPresent([TimedValue].self, forKey: .orpHistory) ?? []
        conductivityHistory = try c.decodeIfPresent([TimedValue].self, forKey: .conductivityHistory) ?? []
        let rawRanges = try c.decodeIfPresent([String: MetricRange].self, forKey: .ranges) ?? [:]
        ranges = Dictionary(uniqueKeysWithValues: rawRanges.compactMap { k, v in Metric(rawValue: k).map { ($0, v) } })
        batteryLow = try c.decodeIfPresent(Bool.self, forKey: .batteryLow)
        viaExtender = try c.decodeIfPresent(Bool.self, forKey: .viaExtender)
        sourceStatus = try c.decodeIfPresent(SourceStatus.self, forKey: .sourceStatus) ?? .offline
        isMock = try c.decodeIfPresent(Bool.self, forKey: .isMock) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(poolID, forKey: .poolID)
        try c.encode(poolName, forKey: .poolName)
        try c.encodeIfPresent(deviceName, forKey: .deviceName)
        try c.encodeIfPresent(measuredAt, forKey: .measuredAt)
        try c.encode(fetchedAt, forKey: .fetchedAt)
        try c.encodeIfPresent(lastAttemptAt, forKey: .lastAttemptAt)
        try c.encodeIfPresent(temperatureC, forKey: .temperatureC)
        try c.encodeIfPresent(ph, forKey: .ph)
        try c.encodeIfPresent(orpMillivolts, forKey: .orpMillivolts)
        try c.encodeIfPresent(conductivityValue, forKey: .conductivityValue)
        try c.encodeIfPresent(conductivityUnit, forKey: .conductivityUnit)
        try c.encode(temperatureHistory, forKey: .temperatureHistory)
        try c.encode(phHistory, forKey: .phHistory)
        try c.encode(orpHistory, forKey: .orpHistory)
        try c.encode(conductivityHistory, forKey: .conductivityHistory)
        try c.encode(Dictionary(uniqueKeysWithValues: ranges.map { ($0.key.rawValue, $0.value) }), forKey: .ranges)
        try c.encodeIfPresent(batteryLow, forKey: .batteryLow)
        try c.encodeIfPresent(viaExtender, forKey: .viaExtender)
        try c.encode(sourceStatus, forKey: .sourceStatus)
        try c.encode(isMock, forKey: .isMock)
    }
}

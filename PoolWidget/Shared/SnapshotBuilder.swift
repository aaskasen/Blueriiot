import Foundation

/// Normalizes raw cloud responses into a `PoolWidgetSnapshot`. Dates and units are normalized here, once.
enum SnapshotBuilder {
    /// Plausibility bounds; values outside are treated as missing (sensor glitch), not shown.
    static let plausible: [Metric: ClosedRange<Double>] = [
        .temperature: -5...60, .ph: 0...14, .orp: -1000...2000, .conductivity: 0...200_000,
    ]

    static func clean(_ v: Any?, _ m: Metric) -> Double? {
        guard let d = (v as? NSNumber)?.doubleValue ?? (v as? Double), d.isFinite,
              plausible[m]!.contains(d) else { return nil }
        return d
    }

    /// Picks the non-expired, newest reading per metric from `lastMeasurements.data`.
    static func latest(from lastMeasurements: [String: Any]) -> [Metric: (value: Double, date: Date?, range: MetricRange?)] {
        var best: [Metric: (value: Double, date: Date?, expired: Bool, range: MetricRange?)] = [:]
        for row in (lastMeasurements["data"] as? [[String: Any]]) ?? [] {
            guard let name = row["name"] as? String, let m = Metric(rawValue: name),
                  let v = clean(row["value"], m) else { continue }
            let date = (row["timestamp"] as? String).flatMap(CloudDate.parse)
            let expired = (row["expired"] as? Bool) ?? false
            var range: MetricRange?
            let num = { (k: String) in (row[k] as? NSNumber)?.doubleValue }
            if let lo = num("ok_min"), let hi = num("ok_max"), lo < hi {
                range = MetricRange(min: lo, max: hi, warningLow: num("warning_low"), warningHigh: num("warning_high"),
                                    gaugeMin: num("gauge_min"), gaugeMax: num("gauge_max"))
            }
            if let cur = best[m] {
                let better = (cur.expired && !expired) ||
                    (cur.expired == expired && (date ?? .distantPast) > (cur.date ?? .distantPast))
                if !better { continue }
            }
            best[m] = (v, date, expired, range)
        }
        return best.mapValues { ($0.value, $0.date, $0.range) }
    }

    /// Converts a `measures` payload into per-metric series, sorted by measurement time.
    static func history(from measures: [String: Any]) -> [Metric: [TimedValue]] {
        var out: [Metric: [TimedValue]] = [:]
        for point in (measures["data"] as? [[String: Any]]) ?? [] {
            guard let created = (point["created"] as? String).flatMap(CloudDate.parse),
                  let data = point["data"] as? [String: Any] else { continue }
            for m in Metric.allCases {
                if let v = clean(data[m.rawValue], m) { out[m, default: []].append(TimedValue(date: created, value: v)) }
            }
        }
        return out.mapValues { Array(Set($0)).sorted { $0.date < $1.date } }
    }

    static func build(pool: BlueriiotAPI.PoolRef, device: [String: Any], lastMeasurements: [String: Any],
                      measures: [String: Any]?, fetchedAt: Date) -> PoolWidgetSnapshot {
        let latest = latest(from: lastMeasurements)
        let hist = measures.map(history(from:)) ?? [:]
        let measuredAt = (lastMeasurements["last_blue_measure_timestamp"] as? String).flatMap(CloudDate.parse)
            ?? latest.values.compactMap(\.date).max()
        var snap = PoolWidgetSnapshot(
            poolID: pool.id, poolName: pool.name,
            deviceName: device["hw_product_name"] as? String,
            measuredAt: measuredAt, fetchedAt: fetchedAt, lastAttemptAt: fetchedAt,
            temperatureC: latest[.temperature]?.value, ph: latest[.ph]?.value,
            orpMillivolts: latest[.orp]?.value,
            conductivityValue: latest[.conductivity]?.value,
            conductivityUnit: latest[.conductivity] != nil ? "µS/cm" : nil,
            sourceStatus: .healthy)
        snap.temperatureHistory = hist[.temperature] ?? []
        snap.phHistory = hist[.ph] ?? []
        snap.orpHistory = hist[.orp] ?? []
        snap.conductivityHistory = hist[.conductivity] ?? []
        snap.ranges = latest.compactMapValues(\.range)
        snap.batteryLow = device["battery_low"] as? Bool
        snap.viaExtender = (device["gateway_id"] as? String).map { $0.hasPrefix("BLEX") }
        return snap
    }
}

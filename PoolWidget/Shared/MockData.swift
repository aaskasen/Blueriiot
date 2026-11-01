import Foundation

/// Development fixtures. Every snapshot built here has `isMock = true`, and views show a
/// visible "Sample data" label for it, so mock values can never pass as real readings.
enum MockData {
    static func series(_ base: Double, amplitude: Double, hours: Int = 24, step: TimeInterval = 72 * 60,
                       end: Date, gapAt: Int? = nil) -> [TimedValue] {
        let n = Int(Double(hours) * 3600 / step)
        return (0..<n).compactMap { i in
            if let g = gapAt, (g..<(g + 3)).contains(i) { return nil }
            let t = end.addingTimeInterval(-Double(n - 1 - i) * step)
            return TimedValue(date: t, value: base + amplitude * sin(Double(i) / 3.0))
        }
    }

    static func snapshot(now: Date = .now, status: SourceStatus = .healthy, measuredAgo: TimeInterval = 14 * 60,
                         partial: Bool = false, withHistory: Bool = true) -> PoolWidgetSnapshot {
        let measured = now.addingTimeInterval(-measuredAgo)
        var s = PoolWidgetSnapshot(
            poolID: "mock-pool", poolName: "Pool", deviceName: "Blue Connect",
            measuredAt: measured, fetchedAt: now, lastAttemptAt: now,
            temperatureC: 27.4, ph: partial ? nil : 7.32, orpMillivolts: 702,
            conductivityValue: partial ? nil : 1480, conductivityUnit: partial ? nil : "µS/cm",
            sourceStatus: status, isMock: true)
        s.ranges = [.temperature: .init(min: 20, max: 40), .ph: .init(min: 7.2, max: 7.6),
                    .orp: .init(min: 650, max: 750), .conductivity: .init(min: 300, max: 10000)]
        if withHistory {
            s.temperatureHistory = series(26.6, amplitude: 0.8, end: measured)
            s.phHistory = partial ? [] : series(7.35, amplitude: 0.05, end: measured)
            s.orpHistory = series(690, amplitude: 25, end: measured, gapAt: 8)
            s.conductivityHistory = partial ? [] : series(1460, amplitude: 30, end: measured)
        }
        s.batteryLow = false
        s.viaExtender = true
        return s
    }
}

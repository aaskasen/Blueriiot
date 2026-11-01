import Foundation

// MARK: - Metric presentation

extension Metric {
    var label: String {
        switch self {
        case .temperature: "Temperature"
        case .ph: "pH"
        case .orp: "Sanitation"
        case .conductivity: "Conductivity"
        }
    }

    var shortLabel: String {
        switch self {
        case .temperature: "Temp"
        case .ph: "pH"
        case .orp: "ORP"
        case .conductivity: "Cond."
        }
    }

    var symbol: String {
        switch self {
        case .temperature: "thermometer.medium"
        case .ph: "drop"
        case .orp: "water.waves"
        case .conductivity: "bolt"
        }
    }

    /// Unit shown next to the figure ("" for pH, which is unitless).
    var unit: String {
        switch self {
        case .temperature: "°C"
        case .ph: ""
        case .orp: "mV"
        case .conductivity: "µS/cm"
        }
    }

    /// Formatted number only, or "—" when unavailable.
    func format(_ v: Double?) -> String {
        guard let v, v.isFinite else { return "—" }
        switch self {
        case .temperature: return String(format: "%.1f", v)
        case .ph: return String(format: "%.2f", v)
        case .orp: return String(format: "%.0f", v)
        case .conductivity:
            // Round to 2 significant-ish steps: <1000 → integer, else nearest 10.
            return v < 1000 ? String(format: "%.0f", v) : String(format: "%.0f", (v / 10).rounded() * 10)
        }
    }

    /// Smallest change considered meaningful for a direction arrow.
    var deltaEpsilon: Double {
        switch self {
        case .temperature: 0.2
        case .ph: 0.03
        case .orp: 10
        case .conductivity: 20
        }
    }
}

// MARK: - Metric state (only from server-provided ranges)

/// normal = within ok range; attention = outside ok but within warning bounds (or warning bounds unknown);
/// bad = beyond the server's warning bounds. Matches the official app's Good / Warning / Bad.
enum MetricState: Equatable {
    case normal, attention, bad, unknown
}

func metricState(_ value: Double?, range: MetricRange?) -> MetricState {
    guard let value, let range else { return .unknown }
    if (range.min...range.max).contains(value) { return .normal }
    if let lo = range.warningLow, value < lo { return .bad }
    if let hi = range.warningHigh, value > hi { return .bad }
    return .attention
}

// MARK: - Change vs. an earlier actual reading

enum Direction: Equatable { case up, down, flat }

struct MetricDelta: Equatable {
    let change: Double
    let direction: Direction
    let comparedTo: Date
}

/// Compares the newest reading with the actual reading closest to `window` earlier (±`tolerance`).
/// Returns nil when no such earlier reading exists — no extrapolation.
func delta(_ history: [TimedValue], metric: Metric, window: TimeInterval = 24 * 3600,
           tolerance: TimeInterval = 3 * 3600) -> MetricDelta? {
    guard let last = history.last else { return nil }
    let target = last.date.addingTimeInterval(-window)
    guard let earlier = history
        .filter({ abs($0.date.timeIntervalSince(target)) <= tolerance })
        .min(by: { abs($0.date.timeIntervalSince(target)) < abs($1.date.timeIntervalSince(target)) })
    else { return nil }
    let change = last.value - earlier.value
    let dir: Direction = abs(change) < metric.deltaEpsilon ? .flat : (change > 0 ? .up : .down)
    return MetricDelta(change: change, direction: dir, comparedTo: earlier.date)
}

// MARK: - Sparkline segmentation

/// Splits a series at gaps larger than `maxGap` so the chart never draws a line across missing data.
/// Returns [] when there are fewer than `minPoints` readings in total.
func sparklineSegments(_ history: [TimedValue], maxGap: TimeInterval = 3 * 3600, minPoints: Int = 4) -> [[TimedValue]] {
    guard history.count >= minPoints else { return [] }
    var segments: [[TimedValue]] = [[]]
    for p in history {
        if let prev = segments[segments.count - 1].last, p.date.timeIntervalSince(prev.date) > maxGap {
            segments.append([])
        }
        segments[segments.count - 1].append(p)
    }
    return segments.filter { !$0.isEmpty }
}

// MARK: - Overall display state

enum DisplayState: Equatable {
    case fresh, stale, offline, authNeeded, notConfigured
}

extension PoolWidgetSnapshot {
    /// A reading older than this is "stale" (device cadence is ~72 min).
    static let staleAfter: TimeInterval = 3 * 3600

    func displayState(now: Date) -> DisplayState {
        switch sourceStatus {
        case .notConfigured: return .notConfigured
        case .authenticationNeeded: return .authNeeded
        case .offline: return .offline
        case .healthy:
            guard let measuredAt else { return .stale }
            return now.timeIntervalSince(measuredAt) > Self.staleAfter ? .stale : .fresh
        }
    }

    var hasAnyValue: Bool { Metric.allCases.contains { value($0) != nil } }

    /// Footer line, e.g. "Last reading 14 min ago".
    func footerText(now: Date) -> String {
        switch displayState(now: now) {
        case .notConfigured: return "Open app to connect BlueRiiot"
        case .authNeeded: return "Sign in to refresh"
        case .offline:
            return measuredAt.map { "Unable to refresh · reading \(relativeAge(from: $0, to: now))" } ?? "Unable to refresh"
        case .stale:
            return measuredAt.map { "Last reading \(relativeAge(from: $0, to: now))" } ?? "No recent measurement"
        case .fresh:
            return measuredAt.map { "Last reading \(relativeAge(from: $0, to: now))" } ?? "No recent measurement"
        }
    }
}

/// "just now", "14 min ago", "3 h ago", "2 d ago" — number and unit joined by a
/// non-breaking space so a wrapped footer never splits "9" from "h".
func relativeAge(from date: Date, to now: Date) -> String {
    let s = max(0, now.timeIntervalSince(date)), nb = "\u{00A0}"
    switch s {
    case ..<90: return "just now"
    case ..<3600: return "\(Int(s / 60))\(nb)min ago"
    case ..<(48 * 3600): return "\(Int(s / 3600))\(nb)h ago"
    default: return "\(Int(s / 86400))\(nb)d ago"
    }
}

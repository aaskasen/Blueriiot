import Charts
import SwiftUI
import WidgetKit

// MARK: - Palette

enum PoolPalette {
    static let lavender = Color(red: 0.56, green: 0.49, blue: 0.86)
    static let blue = Color(red: 0.27, green: 0.52, blue: 0.93)
    static let teal = Color(red: 0.16, green: 0.66, blue: 0.68)
    static let attention = Color(red: 0.93, green: 0.55, blue: 0.16)
    static let bad = Color(red: 0.88, green: 0.24, blue: 0.33)
    static let good = Color(red: 0.20, green: 0.45, blue: 0.96)

    /// Soft tinted card background (used as the widget container background).
    static func background(_ scheme: ColorScheme) -> LinearGradient {
        let colors: [Color] = scheme == .dark
            ? [Color(red: 0.13, green: 0.13, blue: 0.22), Color(red: 0.08, green: 0.14, blue: 0.20)]
            : [Color(red: 0.95, green: 0.94, blue: 1.00), Color(red: 0.91, green: 0.96, blue: 0.98)]
        return LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    /// App-window colours follow the official app's legend: Good = blue, Warning = orange, Bad = red.
    static func appColor(_ state: MetricState) -> Color { state == .normal ? good : color(state) }

    static func color(_ state: MetricState) -> Color {
        switch state {
        case .normal: teal
        case .attention: attention
        case .bad: bad
        case .unknown: .secondary
        }
    }
}

// MARK: - Small building blocks

/// Normal = small filled dot, attention = exclamation badge, unknown = hollow ring.
/// Shapes differ so the state survives the desktop's monochrome/vibrant rendering.
struct StateDot: View {
    let state: MetricState
    var body: some View {
        Group {
            switch state {
            case .normal:
                Circle().fill(PoolPalette.color(state)).frame(width: 6, height: 6)
            case .attention, .bad:
                Image(systemName: state == .bad ? "exclamationmark.triangle.fill" : "exclamationmark.circle.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(PoolPalette.color(state))
                    .widgetAccentable()
            case .unknown:
                Circle().strokeBorder(Color.secondary, lineWidth: 1).frame(width: 6, height: 6)
            }
        }
        .frame(width: 10, height: 10)
        .accessibilityLabel(state == .normal ? "within range" : state == .attention ? "outside range" : state == .bad ? "far outside range" : "no range")
    }
}

struct DeltaLabel: View {
    let delta: MetricDelta?
    let metric: Metric
    var body: some View {
        if let d = delta {
            let name = d.direction == .up ? "arrow.up.right" : d.direction == .down ? "arrow.down.right" : "arrow.right"
            Image(systemName: name)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .accessibilityLabel("\(d.direction == .flat ? "steady" : d.direction == .up ? "up" : "down") vs 24 h ago")
        }
    }
}

struct Sparkline: View {
    let history: [TimedValue]
    var color: Color = PoolPalette.blue
    var body: some View {
        let segments = sparklineSegments(history)
        if !segments.isEmpty {
            let values = history.map(\.value)
            let lo = values.min()!, hi = values.max()!, pad = max((hi - lo) * 0.15, 0.0001)
            Chart {
                ForEach(Array(segments.enumerated()), id: \.offset) { idx, seg in
                    ForEach(seg, id: \.date) { p in
                        LineMark(x: .value("t", p.date), y: .value("v", p.value), series: .value("seg", idx))
                            .interpolationMethod(.monotone)
                            .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round))
                            .foregroundStyle(color)
                    }
                }
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartYScale(domain: (lo - pad)...(hi + pad))
            .chartLegend(.hidden)
            .accessibilityHidden(true)
        }
    }
}

struct HeaderView: View {
    let snapshot: PoolWidgetSnapshot
    let now: Date
    var compact = false
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 1) {
                Text(snapshot.poolName.uppercased())
                    .font(.system(size: compact ? 11 : 12, weight: .bold))
                    .tracking(0.6)
                    .lineLimit(1)
                if !compact {
                    Text(subtitle).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            StatusBadge(state: snapshot.displayState(now: now), isMock: snapshot.isMock)
        }
    }

    var subtitle: String {
        var s = snapshot.deviceName ?? "Blue Connect"
        if snapshot.viaExtender == true { s += " · Extender" }
        return s
    }
}

struct StatusBadge: View {
    let state: DisplayState
    let isMock: Bool
    var body: some View {
        HStack(spacing: 3) {
            if isMock {
                Text("SAMPLE DATA").font(.system(size: 8, weight: .heavy)).foregroundStyle(PoolPalette.attention)
            }
            Image(systemName: symbol).font(.system(size: 9, weight: .semibold)).foregroundStyle(tint)
        }
        .accessibilityLabel(label)
    }
    var symbol: String {
        switch state {
        case .fresh: "dot.radiowaves.left.and.right"
        case .stale: "clock"
        case .offline: "wifi.slash"
        case .authNeeded: "person.crop.circle.badge.exclamationmark"
        case .notConfigured: "gearshape"
        }
    }
    var tint: Color { state == .fresh ? PoolPalette.teal : state == .stale ? .secondary : PoolPalette.attention }
    var label: String {
        switch state {
        case .fresh: "Up to date"
        case .stale: "Reading is old"
        case .offline: "Unable to refresh"
        case .authNeeded: "Sign in needed"
        case .notConfigured: "Not configured"
        }
    }
}

struct FooterView: View {
    let snapshot: PoolWidgetSnapshot
    let now: Date
    var body: some View {
        Text(snapshot.footerText(now: now))
            .font(.system(size: 10))
            .foregroundStyle(snapshot.displayState(now: now) == .fresh ? Color.secondary : PoolPalette.attention)
            .lineLimit(2)
            .minimumScaleFactor(0.85)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Large temperature figure: "27.4" followed by an explicit "°C".
struct TemperatureHero: View {
    let snapshot: PoolWidgetSnapshot
    var size: CGFloat = 38
    var body: some View {
        let v = snapshot.temperatureC
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text(Metric.temperature.format(v))
                .font(.system(size: size, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .minimumScaleFactor(0.7)
                .lineLimit(1)
            if v != nil {
                Text("°C").font(.system(size: size * 0.42, weight: .medium, design: .rounded)).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Temperature \(Metric.temperature.format(v)) degrees Celsius")
    }
}

/// One compact metric row: symbol, label, value + unit, state dot, direction.
struct MetricRow: View {
    let metric: Metric
    let snapshot: PoolWidgetSnapshot
    var body: some View {
        let v = snapshot.value(metric)
        HStack(spacing: 6) {
            Image(systemName: metric.symbol)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(PoolPalette.lavender)
                .frame(width: 13)
            // Full label when it fits, otherwise the short form; the value itself is never truncated.
            ViewThatFits(in: .horizontal) {
                Text(metric.label)
                Text(metric.shortLabel)
            }
            .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 2)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(metric.format(v)).font(.system(size: 13, weight: .semibold, design: .rounded)).monospacedDigit()
                if v != nil && !metric.unit.isEmpty {
                    Text(metric.unit).font(.system(size: 9)).foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
            .fixedSize()
            .layoutPriority(1)
            DeltaLabel(delta: delta(snapshot.history(metric), metric: metric), metric: metric).frame(width: 9)
            StateDot(state: metricState(v, range: snapshot.ranges[metric]))
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Widget bodies

struct SmallPoolView: View {
    let snapshot: PoolWidgetSnapshot
    let now: Date
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HeaderView(snapshot: snapshot, now: now, compact: true)
            Spacer(minLength: 0)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                TemperatureHero(snapshot: snapshot, size: 34)
                DeltaLabel(delta: delta(snapshot.temperatureHistory, metric: .temperature), metric: .temperature)
            }
            if snapshot.ph != nil {
                HStack(spacing: 4) {
                    Text("pH").font(.system(size: 11)).foregroundStyle(.secondary)
                    Text(Metric.ph.format(snapshot.ph)).font(.system(size: 13, weight: .semibold, design: .rounded)).monospacedDigit()
                    StateDot(state: metricState(snapshot.ph, range: snapshot.ranges[.ph]))
                }
            }
            Spacer(minLength: 0)
            FooterView(snapshot: snapshot, now: now)
        }
    }
}

struct MediumPoolView: View {
    let snapshot: PoolWidgetSnapshot
    let now: Date
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HeaderView(snapshot: snapshot, now: now)
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Image(systemName: Metric.temperature.symbol).font(.system(size: 10)).foregroundStyle(PoolPalette.lavender)
                        Text("Water").font(.system(size: 11)).foregroundStyle(.secondary)
                        StateDot(state: metricState(snapshot.temperatureC, range: snapshot.ranges[.temperature]))
                    }
                    TemperatureHero(snapshot: snapshot, size: 36)
                    Sparkline(history: snapshot.temperatureHistory, color: PoolPalette.blue)
                        .frame(height: 18)
                }
                .frame(width: 104, alignment: .leading)
                Rectangle().fill(.separator).frame(width: 0.5).padding(.vertical, 2)
                VStack(spacing: 7) {
                    MetricRow(metric: .ph, snapshot: snapshot)
                    MetricRow(metric: .orp, snapshot: snapshot)
                    MetricRow(metric: .conductivity, snapshot: snapshot)
                }
            }
            Spacer(minLength: 0)
            FooterView(snapshot: snapshot, now: now)
        }
    }
}

struct LargePoolView: View {
    let snapshot: PoolWidgetSnapshot
    let now: Date
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HeaderView(snapshot: snapshot, now: now)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                ForEach(Metric.allCases, id: \.self) { MetricTile(metric: $0, snapshot: snapshot) }
            }
            InsightsView(snapshot: snapshot, now: now)
            Spacer(minLength: 0)
            FooterView(snapshot: snapshot, now: now)
        }
    }
}

struct MetricTile: View {
    let metric: Metric
    let snapshot: PoolWidgetSnapshot
    var body: some View {
        let v = snapshot.value(metric)
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: metric.symbol).font(.system(size: 10)).foregroundStyle(PoolPalette.lavender)
                Text(metric.label).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 0)
                StateDot(state: metricState(v, range: snapshot.ranges[metric]))
            }
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(metric.format(v))
                    .font(.system(size: 20, weight: .semibold, design: .rounded)).monospacedDigit()
                if v != nil && !metric.unit.isEmpty {
                    Text(metric.unit).font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                DeltaLabel(delta: delta(snapshot.history(metric), metric: metric), metric: metric)
            }
            .lineLimit(1)
            Sparkline(history: snapshot.history(metric), color: metric == .temperature ? PoolPalette.blue : PoolPalette.teal)
                .frame(height: 16)
        }
        .padding(7)
        .background(RoundedRectangle(cornerRadius: 10).fill(.background.opacity(0.35)))
        .accessibilityElement(children: .combine)
    }
}

/// Factual observations from verified data only — no advice, no dosing.
struct InsightsView: View {
    let snapshot: PoolWidgetSnapshot
    let now: Date
    var body: some View {
        let items = insights(snapshot)
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("STATUS").font(.system(size: 9, weight: .bold)).tracking(0.6).foregroundStyle(.secondary)
                ForEach(items.prefix(4), id: \.self) { line in
                    HStack(alignment: .top, spacing: 6) {
                        Circle().fill(PoolPalette.lavender).frame(width: 4, height: 4).padding(.top, 5)
                        Text(line).font(.system(size: 11)).lineLimit(1).minimumScaleFactor(0.85)
                    }
                }
            }
        }
    }
}

func insights(_ s: PoolWidgetSnapshot) -> [String] {
    var out: [String] = []
    let ranged = Metric.allCases.filter { s.value($0) != nil && s.ranges[$0] != nil }
    for m in [Metric.orp, .ph, .conductivity, .temperature] {
        guard let v = s.value(m), let r = s.ranges[m] else { continue }
        let unit = m.unit.isEmpty ? "" : " \(m.unit)"
        if v < r.min { out.append("\(m.label) below range (\(m.format(r.min))–\(m.format(r.max))\(unit))") }
        if v > r.max { out.append("\(m.label) above range (\(m.format(r.min))–\(m.format(r.max))\(unit))") }
    }
    if let d = delta(s.temperatureHistory, metric: .temperature), d.direction != .flat {
        out.append(String(format: "Water %@ %.1f °C over 24 h", d.change > 0 ? "warmed" : "cooled", abs(d.change)))
    }
    if !ranged.isEmpty && ranged.allSatisfy({ metricState(s.value($0), range: s.ranges[$0]) == .normal }) {
        out.insert(ranged.count == Metric.allCases.count
                   ? "All four readings are within the pool's ranges"
                   : "Readings with a known range are within it", at: 0)
    }
    if s.batteryLow == true { out.append("Sensor battery reported low") }
    if s.viaExtender == true { out.append("Readings delivered via Blue Extender") }
    return out
}

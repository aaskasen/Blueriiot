import Charts
import SwiftUI

/// History for one metric: range picker, stats, and a chart with the good range shaded.
struct MetricDetailView: View {
    let metric: Metric
    let controller: RefreshController
    @State private var range: HistoryRange = .week
    @State private var series: [TimedValue] = []
    @State private var loading = false
    @State private var error: String?
    @State private var selected: Date?

    var body: some View {
        let snap = controller.snapshot
        let r = snap.ranges[metric]
        ZStack {
            AppBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header(snap, r)
                    Picker("Range", selection: $range) {
                        ForEach(HistoryRange.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 380)
                    chartCard(r)
                    stats
                }
                .padding(28)
                .frame(maxWidth: 980)
                .frame(maxWidth: .infinity)
            }
        }
        .navigationTitle(metric == .orp ? "Sanitation (ORP)" : metric.label)
        .task(id: range) { await load() }
    }

    private func header(_ snap: PoolWidgetSnapshot, _ r: MetricRange?) -> some View {
        let v = snap.value(metric)
        let state = metricState(v, range: r)
        return HStack(alignment: .center, spacing: 16) {
            Image(systemName: metric.symbol).font(.system(size: 26)).foregroundStyle(PoolPalette.lavender)
                .frame(width: 52, height: 52)
                .background(Circle().fill(PoolPalette.lavender.opacity(0.12)))
            VStack(alignment: .leading, spacing: 2) {
                Text(metric == .orp ? "Sanitation (ORP)" : metric.label).font(.title2.bold())
                if let d = snap.measuredAt { Text("Measured \(fullRelative(d))").foregroundStyle(.secondary) }
            }
            Spacer()
            ValueBubble(text: metric.format(v) + (metric.unit.isEmpty || v == nil ? "" : " \(metric.unit)"),
                        color: v == nil ? .gray : PoolPalette.appColor(state))
        }
    }

    private func chartCard(_ r: MetricRange?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                if let r {
                    Label("Good range \(metric.format(r.min))–\(metric.format(r.max)) \(metric.unit)", systemImage: "rectangle.fill")
                        .labelStyle(TintedLabel(tint: PoolPalette.good.opacity(0.3)))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let p = selectedPoint {
                    Text("\(metric.format(p.value)) \(metric.unit) · \(p.date.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption.monospacedDigit().weight(.semibold))
                } else if loading {
                    ProgressView().controlSize(.small)
                }
            }
            Group {
                if let error {
                    ContentUnavailableView("Couldn't load history", systemImage: "wifi.exclamationmark", description: Text(error))
                } else if series.isEmpty && !loading {
                    ContentUnavailableView("No readings in this period", systemImage: "chart.xyaxis.line",
                                           description: Text("The sensor reported nothing between these dates."))
                } else {
                    chart(r)
                }
            }
            .frame(height: 320)
        }
        .padding(20)
        .cardChrome()
    }

    private func chart(_ r: MetricRange?) -> some View {
        let segments = sparklineSegments(series, maxGap: 3 * 3600, minPoints: 1)
        let color = PoolPalette.blue
        return Chart {
            if let r, let first = series.first?.date, let last = series.last?.date {
                RectangleMark(xStart: .value("from", first), xEnd: .value("to", last),
                              yStart: .value("min", r.min), yEnd: .value("max", r.max))
                    .foregroundStyle(PoolPalette.good.opacity(0.08))
            }
            ForEach(Array(segments.enumerated()), id: \.offset) { idx, seg in
                ForEach(seg, id: \.date) { p in
                    AreaMark(x: .value("Time", p.date), yStart: .value("base", yDomain.lowerBound),
                             yEnd: .value(metric.label, p.value), series: .value("seg", idx))
                        .foregroundStyle(LinearGradient(colors: [color.opacity(0.22), color.opacity(0.0)],
                                                        startPoint: .top, endPoint: .bottom))
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("Time", p.date), y: .value(metric.label, p.value), series: .value("seg", idx))
                        .foregroundStyle(color)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                        .interpolationMethod(.monotone)
                }
            }
            if let p = selectedPoint {
                RuleMark(x: .value("Selected", p.date)).foregroundStyle(.secondary.opacity(0.4))
                PointMark(x: .value("Time", p.date), y: .value(metric.label, p.value))
                    .symbolSize(70).foregroundStyle(color)
            }
        }
        .chartYScale(domain: yDomain)
        .chartXSelection(value: $selected)
        .chartYAxis { AxisMarks(position: .leading) }
        .animation(.easeInOut(duration: 0.25), value: series)
    }

    private var yDomain: ClosedRange<Double> {
        var vals = series.map(\.value)
        if let r = controller.snapshot.ranges[metric] { vals += [r.min, r.max] }
        guard let lo = vals.min(), let hi = vals.max() else { return 0...1 }
        let pad = Swift.max((hi - lo) * 0.08, metric.deltaEpsilon)
        return (lo - pad)...(hi + pad)
    }

    private var selectedPoint: TimedValue? {
        guard let selected else { return nil }
        return series.min { abs($0.date.timeIntervalSince(selected)) < abs($1.date.timeIntervalSince(selected)) }
    }

    private var stats: some View {
        let vals = series.map(\.value)
        return HStack(spacing: 14) {
            stat("Lowest", vals.min())
            stat("Average", vals.isEmpty ? nil : vals.reduce(0, +) / Double(vals.count))
            stat("Highest", vals.max())
            statText("Readings", "\(series.count)")
        }
    }

    private func stat(_ title: String, _ v: Double?) -> some View {
        statText(title, metric.format(v) + (v == nil || metric.unit.isEmpty ? "" : " \(metric.unit)"))
    }

    private func statText(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 20, weight: .semibold, design: .rounded).monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .cardChrome()
    }

    private func load() async {
        loading = true; error = nil; selected = nil
        defer { loading = false }
        do {
            series = try await controller.history(range)[metric] ?? []
        } catch {
            self.error = "\(error)"
            series = []
        }
    }
}

struct TintedLabel: LabelStyle {
    let tint: Color
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) { configuration.icon.foregroundStyle(tint); configuration.title }
    }
}

import SwiftUI

/// Renders every widget family × state × appearance to PNG (development/verification only).
@MainActor
enum PreviewRenderer {
    static func renderAll(to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let now = Date.now
        var states: [(String, PoolWidgetSnapshot)] = [
            ("fresh", MockData.snapshot(now: now)),
            ("stale", MockData.snapshot(now: now, measuredAgo: 5 * 3600)),
            ("offline", MockData.snapshot(now: now, status: .offline, measuredAgo: 9 * 3600)),
            ("auth", MockData.snapshot(now: now, status: .authenticationNeeded, measuredAgo: 2 * 3600)),
            ("partial-nohistory", MockData.snapshot(now: now, partial: true, withHistory: false)),
            ("notconfigured", .notConfigured(now: now)),
        ]
        if let real = SnapshotStore.read() { states.insert(("live", real), at: 0) }
        for (name, snap) in states.prefix(2) {
            for scheme in [ColorScheme.light, .dark] {
                renderDashboard(snap, scheme, dir.appendingPathComponent("app-\(name)-\(scheme == .dark ? "dark" : "light").png"))
            }
        }
        for (name, snap) in states {
            for scheme in [ColorScheme.light, .dark] {
                let tag = scheme == .dark ? "dark" : "light"
                write(SmallPoolView(snapshot: snap, now: now), WidgetSize.small, scheme, dir.appendingPathComponent("small-\(name)-\(tag).png"))
                write(MediumPoolView(snapshot: snap, now: now), WidgetSize.medium, scheme, dir.appendingPathComponent("medium-\(name)-\(tag).png"))
                write(LargePoolView(snapshot: snap, now: now), WidgetSize.large, scheme, dir.appendingPathComponent("large-\(name)-\(tag).png"))
            }
        }
    }

    /// The main window's content (header + metric cards) without window chrome.
    private static func renderDashboard(_ snap: PoolWidgetSnapshot, _ scheme: ColorScheme, _ url: URL) {
        let content = ZStack {
            AppBackground()
            VStack(alignment: .leading, spacing: 22) {
                DashboardHeaderPreview(snapshot: snap)
                Grid(horizontalSpacing: 18, verticalSpacing: 18) {
                    GridRow { MetricCard(metric: .temperature, snapshot: snap); MetricCard(metric: .ph, snapshot: snap) }
                    GridRow { MetricCard(metric: .orp, snapshot: snap); MetricCard(metric: .conductivity, snapshot: snap) }
                }
            }
            .padding(28)
        }
        .frame(width: 860)
        .environment(\.colorScheme, scheme)
        let r = ImageRenderer(content: content)
        r.scale = 2
        guard let img = r.nsImage, let tiff = img.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url)
    }

    private static func write<V: View>(_ view: V, _ size: CGSize, _ scheme: ColorScheme, _ url: URL) {
        let content = view
            .padding(14)
            .frame(width: size.width, height: size.height)
            .background(PoolPalette.background(scheme))
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.separator, lineWidth: 0.5))
            .padding(10)
            .background(scheme == .dark ? Color(white: 0.12) : Color(white: 0.86))
            .environment(\.colorScheme, scheme)
        let r = ImageRenderer(content: content)
        r.scale = 2
        guard let img = r.nsImage, let tiff = img.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url)
    }
}

/// Static stand-in for PoolHeader (which needs a live RefreshController).
private struct DashboardHeaderPreview: View {
    let snapshot: PoolWidgetSnapshot
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(snapshot.poolName).font(.system(size: 30, weight: .bold, design: .rounded))
                    HStack(spacing: 8) {
                        Chip(icon: "sensor", text: snapshot.deviceName ?? "Blue Connect")
                        if snapshot.viaExtender == true { Chip(icon: "antenna.radiowaves.left.and.right", text: "Blue Extender") }
                        if snapshot.batteryLow == true { Chip(icon: "battery.25", text: "Battery low", tint: PoolPalette.bad) }
                    }
                }
                Spacer()
                if let d = snapshot.measuredAt { Text("Measured \(fullRelative(d))").font(.callout).foregroundStyle(.secondary) }
            }
            Legend()
        }
    }
}

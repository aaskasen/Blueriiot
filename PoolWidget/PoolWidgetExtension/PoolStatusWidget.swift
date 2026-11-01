import SwiftUI
import WidgetKit

struct PoolEntry: TimelineEntry {
    let date: Date
    let snapshot: PoolWidgetSnapshot
}

/// Reads the last snapshot written by the host app. Never touches the network.
struct PoolProvider: TimelineProvider {
    func placeholder(in context: Context) -> PoolEntry {
        PoolEntry(date: .now, snapshot: MockData.snapshot())
    }

    func getSnapshot(in context: Context, completion: @escaping (PoolEntry) -> Void) {
        // The widget gallery preview may show sample data (it's labeled "SAMPLE DATA").
        let snap = SnapshotStore.read() ?? (context.isPreview ? MockData.snapshot() : .notConfigured())
        completion(PoolEntry(date: .now, snapshot: snap))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<PoolEntry>) -> Void) {
        let snap = SnapshotStore.read() ?? .notConfigured()
        let now = Date.now
        // A few entries so "x min ago" and the stale state age correctly without new data.
        let entries = stride(from: 0, through: 120, by: 15).map {
            PoolEntry(date: now.addingTimeInterval(Double($0) * 60), snapshot: snap)
        }
        completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(30 * 60))))
    }
}

struct PoolWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.colorScheme) private var scheme
    let entry: PoolEntry

    var body: some View {
        Group {
            switch family {
            case .systemSmall: SmallPoolView(snapshot: entry.snapshot, now: entry.date)
            case .systemLarge: LargePoolView(snapshot: entry.snapshot, now: entry.date)
            default: MediumPoolView(snapshot: entry.snapshot, now: entry.date)
            }
        }
        .containerBackground(for: .widget) { PoolPalette.background(scheme) }
        .widgetURL(URL(string: "poolmonitor://pool"))
    }
}

struct PoolStatusWidget: Widget {
    static let kind = "PoolStatusWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: PoolProvider()) { entry in
            PoolWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Pool Status")
        .description("Temperature, pH, sanitation (ORP) and conductivity from your Blue Connect.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

@main
struct PoolWidgetBundle: WidgetBundle {
    var body: some Widget { PoolStatusWidget() }
}

#Preview("Medium · sample", as: .systemMedium) {
    PoolStatusWidget()
} timeline: {
    PoolEntry(date: .now, snapshot: MockData.snapshot())
    PoolEntry(date: .now, snapshot: MockData.snapshot(status: .offline, measuredAgo: 6 * 3600))
    PoolEntry(date: .now, snapshot: MockData.snapshot(partial: true, withHistory: false))
    PoolEntry(date: .now, snapshot: .notConfigured())
}

#Preview("Small · sample", as: .systemSmall) {
    PoolStatusWidget()
} timeline: {
    PoolEntry(date: .now, snapshot: MockData.snapshot())
    PoolEntry(date: .now, snapshot: MockData.snapshot(status: .authenticationNeeded))
}

#Preview("Large · sample", as: .systemLarge) {
    PoolStatusWidget()
} timeline: {
    PoolEntry(date: .now, snapshot: MockData.snapshot())
}

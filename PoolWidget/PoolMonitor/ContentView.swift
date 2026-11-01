import SwiftUI

/// Main window: header, legend, and one card per metric, as in the official app.
/// Clicking a card opens its history.
struct ContentView: View {
    let controller: RefreshController
    @Binding var selectedMetric: Metric?
    @Environment(\.colorScheme) private var scheme
    @State private var showWidgets = false

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackground()
                if controller.hasCredentials || controller.snapshot.hasAnyValue {
                    dashboard
                } else {
                    SignInView(controller: controller)
                }
            }
            .navigationDestination(item: $selectedMetric) { m in
                MetricDetailView(metric: m, controller: controller)
            }
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button { showWidgets = true } label: { Label("Widget previews", systemImage: "square.grid.2x2") }
                        .help("Show how the desktop widgets look with current data")
                    Button { Task { await controller.refresh() } } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .help("Fetch the latest readings")
                    .disabled(controller.isRefreshing || !controller.hasCredentials)
                    SettingsLink { Label("Settings", systemImage: "gearshape") }
                }
            }
            .sheet(isPresented: $showWidgets) { WidgetGallery(snapshot: controller.snapshot) }
        }
        .frame(minWidth: 560, minHeight: 520)
    }

    private var dashboard: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PoolHeader(controller: controller)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 340), spacing: 18)], spacing: 18) {
                    ForEach(Metric.allCases, id: \.self) { m in
                        Button { selectedMetric = m } label: {
                            MetricCard(metric: m, snapshot: controller.snapshot)
                        }
                        .buttonStyle(CardButtonStyle())
                    }
                }
                Text("Ranges come from your BlueRiiot account. Readings arrive from the sensor about every 72 minutes.")
                    .font(.footnote).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            .padding(28)
            .frame(maxWidth: 980)
            .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - Background & card chrome

struct AppBackground: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        ZStack {
            (scheme == .dark ? Color(red: 0.07, green: 0.08, blue: 0.11) : Color(red: 0.965, green: 0.968, blue: 0.985))
            // Soft lavender/teal glow, echoing the widget's tint.
            RadialGradient(colors: [PoolPalette.lavender.opacity(scheme == .dark ? 0.22 : 0.16), .clear],
                           center: .topLeading, startRadius: 20, endRadius: 620)
            RadialGradient(colors: [PoolPalette.teal.opacity(scheme == .dark ? 0.16 : 0.10), .clear],
                           center: .bottomTrailing, startRadius: 20, endRadius: 700)
        }
        .ignoresSafeArea()
    }
}

struct CardChrome: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(scheme == .dark ? Color.white.opacity(0.06) : Color.white.opacity(0.92))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(scheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.05), lineWidth: 1)
            )
            .shadow(color: .black.opacity(scheme == .dark ? 0.35 : 0.06), radius: 14, y: 6)
    }
}

extension View { func cardChrome() -> some View { modifier(CardChrome()) } }

struct CardButtonStyle: ButtonStyle {
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.985 : (hovering ? 1.008 : 1))
            .animation(.spring(response: 0.25, dampingFraction: 0.8), value: hovering)
            .animation(.spring(response: 0.2, dampingFraction: 0.8), value: configuration.isPressed)
            .onHover { hovering = $0 }
    }
}

// MARK: - Header

struct PoolHeader: View {
    let controller: RefreshController
    var body: some View {
        let s = controller.snapshot
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(s.poolName).font(.system(size: 30, weight: .bold, design: .rounded))
                    HStack(spacing: 8) {
                        Chip(icon: "sensor", text: s.deviceName ?? "Blue Connect")
                        if s.viaExtender == true { Chip(icon: "antenna.radiowaves.left.and.right", text: "Blue Extender") }
                        if s.batteryLow == true { Chip(icon: "battery.25", text: "Battery low", tint: PoolPalette.bad) }
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    if controller.isRefreshing {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(updatedText(s)).font(.callout).foregroundStyle(stateTint(s))
                    }
                    if let err = controller.lastError {
                        Text(err).font(.caption).foregroundStyle(PoolPalette.attention).lineLimit(1)
                    }
                }
            }
            Legend()
        }
    }

    private func updatedText(_ s: PoolWidgetSnapshot) -> String {
        switch s.displayState(now: .now) {
        case .authNeeded: "Sign in to refresh"
        case .notConfigured: "Not connected"
        default: s.measuredAt.map { "Measured \(fullRelative($0))" } ?? "No recent measurement"
        }
    }

    private func stateTint(_ s: PoolWidgetSnapshot) -> Color {
        s.displayState(now: .now) == .fresh ? .secondary : PoolPalette.attention
    }
}

struct Chip: View {
    let icon: String
    let text: String
    var tint: Color = .secondary
    var body: some View {
        Label(text, systemImage: icon)
            .font(.caption.weight(.medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(Capsule().fill(tint.opacity(0.10)))
    }
}

struct Legend: View {
    var body: some View {
        HStack(spacing: 18) {
            item(PoolPalette.bad, "Bad")
            item(PoolPalette.attention, "Warning")
            item(PoolPalette.good, "Good")
        }
        .font(.callout.weight(.medium))
    }
    private func item(_ c: Color, _ t: String) -> some View {
        HStack(spacing: 6) { Circle().fill(c).frame(width: 9, height: 9); Text(t) }
    }
}

func fullRelative(_ date: Date) -> String {
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .full
    return f.localizedString(for: date, relativeTo: .now)
}

// MARK: - Metric card with range bar

struct MetricCard: View {
    let metric: Metric
    let snapshot: PoolWidgetSnapshot

    var body: some View {
        let v = snapshot.value(metric)
        let range = snapshot.ranges[metric]
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Label {
                    Text(metric == .orp ? "Sanitation (ORP)" : metric.label)
                } icon: {
                    Image(systemName: metric.symbol).foregroundStyle(PoolPalette.lavender)
                }
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                Spacer()
                if let d = snapshot.measuredAt {
                    Text(fullRelative(d)).font(.callout).foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
            if let range, let v {
                RangeBar(metric: metric, value: v, range: range)
                    .frame(height: 64)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(metric.format(v)).font(.system(size: 30, weight: .semibold, design: .rounded))
                    if v != nil { Text(metric.unit).foregroundStyle(.secondary) }
                }
                .frame(height: 64, alignment: .bottomLeading)
            }
            HStack(spacing: 6) {
                Sparkline(history: snapshot.history(metric), color: PoolPalette.appColor(metricState(v, range: range)).opacity(0.9))
                    .frame(height: 22)
                if let d = delta(snapshot.history(metric), metric: metric) {
                    Text(deltaText(d)).font(.caption).foregroundStyle(.secondary).fixedSize()
                }
            }
        }
        .padding(20)
        .cardChrome()
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Shows history")
    }

    private func deltaText(_ d: MetricDelta) -> String {
        let sign = d.change > 0 ? "+" : d.change < 0 ? "−" : "±"
        let unit = metric.unit.isEmpty ? "" : " \(metric.unit)"
        return "\(sign)\(metric.format(abs(d.change)))\(unit) vs 24 h"
    }
}

/// Five-zone scale (bad · warning · good · warning · bad) with a value bubble, after the official app.
/// Zones get fixed visual widths; the value is placed linearly within its zone.
struct RangeBar: View {
    let metric: Metric
    let value: Double
    let range: MetricRange

    static let weights: [CGFloat] = [0.14, 0.18, 0.36, 0.18, 0.14]
    static let colors: [Color] = [PoolPalette.bad, PoolPalette.attention, PoolPalette.good, PoolPalette.attention, PoolPalette.bad]

    /// Zone boundaries: gaugeMin, warningLow, okMin, okMax, warningHigh, gaugeMax (missing ones extrapolated).
    var bounds: [Double] {
        let span = range.max - range.min
        let wl = range.warningLow ?? range.min - span
        let wh = range.warningHigh ?? range.max + span
        let gmin = Swift.min(range.gaugeMin ?? wl - (range.min - wl), wl)
        let gmax = Swift.max(range.gaugeMax ?? wh + (wh - range.max), wh)
        return [gmin, wl, range.min, range.max, wh, gmax]
    }

    func position(_ v: Double) -> CGFloat {
        let b = bounds
        var start: CGFloat = 0
        for i in 0..<5 {
            let lo = b[i], hi = b[i + 1], w = Self.weights[i]
            if v <= hi || i == 4 {
                let f = hi > lo ? CGFloat((v - lo) / (hi - lo)) : 0
                return Swift.min(Swift.max(start + w * Swift.min(Swift.max(f, 0), 1), 0.005), 0.995)
            }
            start += w
        }
        return 0.5
    }

    var body: some View {
        let state = metricState(value, range: range)
        GeometryReader { geo in
            let w = geo.size.width
            let x = position(value) * w
            let b = bounds
            ZStack(alignment: .topLeading) {
                // Boundary labels (warning low, ok min, ok max, warning high)
                ForEach(1..<5, id: \.self) { i in
                    let bx = Self.weights.prefix(i).reduce(0, +) * w
                    Text(metric.format(b[i]))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .fixedSize()
                        .position(x: bx, y: 36)
                        .opacity(abs(bx - x) < 34 ? 0 : 1)   // never collide with the bubble
                }
                // Zones
                HStack(spacing: 2) {
                    ForEach(0..<5, id: \.self) { i in
                        Self.colors[i].opacity(i == 2 ? 0.95 : 0.85)
                            .frame(width: Swift.max(Self.weights[i] * w - 2, 0))
                    }
                }
                .frame(height: 10)
                .clipShape(Capsule())
                .offset(y: 50)
                // Marker
                Capsule().fill(.white).frame(width: 3, height: 16)
                    .shadow(color: .black.opacity(0.25), radius: 1.5)
                    .position(x: x, y: 55)
                // Bubble
                ValueBubble(text: metric.format(value) + (metric.unit.isEmpty ? "" : " \(metric.unit)"),
                            color: PoolPalette.appColor(state))
                    .fixedSize()
                    .position(x: Swift.min(Swift.max(x, 50), w - 50), y: 14)
                Triangle().fill(PoolPalette.appColor(state)).frame(width: 12, height: 7)
                    .position(x: x, y: 33)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(metric.label) \(metric.format(value)) \(metric.unit), good range \(metric.format(range.min)) to \(metric.format(range.max))")
    }
}

struct ValueBubble: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text)
            .font(.system(size: 17, weight: .bold, design: .rounded).monospacedDigit())
            .foregroundStyle(.white)
            .padding(.horizontal, 14).padding(.vertical, 5)
            .background(Capsule().fill(color.gradient))
            .shadow(color: color.opacity(0.35), radius: 6, y: 3)
    }
}

struct Triangle: Shape {
    func path(in r: CGRect) -> Path {
        Path { p in
            p.move(to: CGPoint(x: r.minX, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
            p.addLine(to: CGPoint(x: r.midX, y: r.maxY))
            p.closeSubpath()
        }
    }
}

// MARK: - Sign in

struct SignInView: View {
    let controller: RefreshController
    @State private var email = ""
    @State private var password = ""
    var body: some View {
        VStack(spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 96, height: 96)
            Text("Connect BlueRiiot").font(.title.bold())
            Text("Your email and password are stored in the macOS Keychain and used only by this app. The widget never sees them.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 360)
            VStack(spacing: 10) {
                TextField("Email", text: $email).textContentType(.username)
                SecureField("Password", text: $password).textContentType(.password)
            }
            .textFieldStyle(.roundedBorder).frame(width: 300)
            Button {
                Task { await controller.saveCredentials(email: email, password: password); password = "" }
            } label: {
                Text(controller.isRefreshing ? "Signing in…" : "Sign in").frame(width: 120)
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
            .disabled(email.isEmpty || password.isEmpty || controller.isRefreshing)
            .keyboardShortcut(.defaultAction)
            if let e = controller.lastError { Text(e).font(.callout).foregroundStyle(PoolPalette.bad) }
        }
        .padding(40)
        .cardChrome()
        .padding(40)
    }
}

// MARK: - Widget previews sheet

struct WidgetGallery: View {
    let snapshot: PoolWidgetSnapshot
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Desktop widgets").font(.title2.bold())
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            HStack(alignment: .top, spacing: 16) {
                VStack(spacing: 16) {
                    card(SmallPoolView(snapshot: snapshot, now: .now), WidgetSize.small)
                    card(MediumPoolView(snapshot: snapshot, now: .now), WidgetSize.medium)
                }
                card(LargePoolView(snapshot: snapshot, now: .now), WidgetSize.large)
            }
            Text("Add them via right-click on the desktop → Edit Widgets… → “Pool Status”.")
                .font(.callout).foregroundStyle(.secondary)
        }
        .padding(24)
    }

    private func card<V: View>(_ v: V, _ size: CGSize) -> some View {
        v.padding(14)
            .frame(width: size.width, height: size.height)
            .background(PoolPalette.background(scheme))
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.separator, lineWidth: 0.5))
    }
}

/// macOS desktop widget sizes (points) as measured on this Mac's desktop (large ≈ 345×345).
enum WidgetSize {
    static let small = CGSize(width: 158, height: 158)
    static let medium = CGSize(width: 345, height: 158)
    static let large = CGSize(width: 345, height: 345)
}

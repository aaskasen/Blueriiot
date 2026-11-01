import Foundation
import Observation
import OSLog
import WidgetKit

/// Fetches from BlueRiiot, writes the App Group snapshot, and asks WidgetKit to reload.
@MainActor @Observable
final class RefreshController {
    static let refreshInterval: TimeInterval = 30 * 60   // device measures ~every 72 min
    static let reloadThrottle: TimeInterval = 5 * 60

    private let log = Logger(subsystem: "com.askasen.PoolMonitor", category: "refresh")
    private(set) var snapshot: PoolWidgetSnapshot
    private(set) var isRefreshing = false
    private(set) var lastError: String?
    private var lastReload: Date = .distantPast
    private var scheduler: NSBackgroundActivityScheduler?
    /// One signed-in API session reused across refreshes and history requests.
    private var api: BlueriiotAPI?
    private var apiEmail: String?
    private var device: (pool: BlueriiotAPI.PoolRef, serial: String)?
    private var historyCache: [HistoryRange: (fetched: Date, series: [Metric: [TimedValue]])] = [:]

    static let shared = RefreshController()

    init() {
        snapshot = SnapshotStore.read() ?? .notConfigured()
    }

    var hasCredentials: Bool { KeychainStore.load() != nil }

    /// Starts periodic refreshing. Called once at app launch (not when a window appears), so a
    /// menu-bar-only launch at login also keeps the widget current. NSBackgroundActivityScheduler
    /// is used instead of a Timer because it keeps firing for a background app under App Nap
    /// and catches up after sleep.
    func start() {
        guard scheduler == nil else { return }
        let s = NSBackgroundActivityScheduler(identifier: "com.askasen.PoolMonitor.refresh")
        s.repeats = true
        s.interval = Self.refreshInterval
        s.tolerance = 5 * 60
        s.qualityOfService = .utility
        s.schedule { completion in
            Task { @MainActor [weak self] in
                await self?.refresh()
                completion(.finished)
            }
        }
        scheduler = s
        Task { await refresh() }
    }

    /// Refresh when the user brings the window up, unless we refreshed very recently.
    func refreshIfStale() async {
        if let last = snapshot.lastAttemptAt, Date.now.timeIntervalSince(last) < 5 * 60 { return }
        await refresh()
    }

    func refresh() async {
        guard !isRefreshing else { return }
        guard let creds = KeychainStore.load() else {
            write(.notConfigured()); lastError = nil; return
        }
        isRefreshing = true
        defer { isRefreshing = false }
        let now = Date.now
        let api = client(for: creds)
        do {
            let (pool, serial) = try await resolveDevice(api)
            let device = try await api.device(serial: serial)
            let last = try await api.lastMeasurements(pool: pool.id, serial: serial)
            // History is optional: a failure here must not hide current readings.
            let hist = try? await api.measures(pool: pool.id, serial: serial,
                                               start: now.addingTimeInterval(-26 * 3600), end: now)
            let snap = SnapshotBuilder.build(pool: pool, device: device, lastMeasurements: last,
                                             measures: hist, fetchedAt: now)
            write(snap)
            lastError = nil
            log.info("refresh ok; measuredAt=\(snap.measuredAt?.description ?? "nil", privacy: .public)")
        } catch let e as BlueriiotAPI.APIError {
            if case .authentication = e { markFailure(.authenticationNeeded, now: now, message: "Sign-in rejected") }
            else { markFailure(.offline, now: now, message: "\(e)") }
        } catch {
            markFailure(.offline, now: now, message: error.localizedDescription)
        }
    }

    /// Keeps last-known-good values but records that refreshing failed.
    private func markFailure(_ status: SourceStatus, now: Date, message: String) {
        var s = snapshot
        if s.sourceStatus == .notConfigured && status == .offline { s = .notConfigured(now: now) }
        s.sourceStatus = status
        s.lastAttemptAt = now
        s.isMock = false
        write(s)
        lastError = message
        log.error("refresh failed: \(message, privacy: .public)")
    }

    private func write(_ s: PoolWidgetSnapshot) {
        snapshot = s
        do { try SnapshotStore.write(s) } catch { log.error("snapshot write failed: \(error.localizedDescription, privacy: .public)") }
        if Date.now.timeIntervalSince(lastReload) > Self.reloadThrottle || s.sourceStatus != .healthy {
            lastReload = .now
            WidgetCenter.shared.reloadTimelines(ofKind: "PoolStatusWidget")
        }
    }

    private func client(for creds: KeychainStore.Credentials) -> BlueriiotAPI {
        if let api, apiEmail == creds.email { return api }
        let fresh = BlueriiotAPI(email: creds.email, password: creds.password)
        api = fresh; apiEmail = creds.email; device = nil; historyCache = [:]
        return fresh
    }

    private func resolveDevice(_ api: BlueriiotAPI) async throws -> (BlueriiotAPI.PoolRef, String) {
        if let device { return (device.pool, device.serial) }
        guard let pool = try await api.pools().first,
              let serial = try await api.deviceSerials(pool: pool.id).first else {
            throw BlueriiotAPI.APIError.noPoolOrDevice
        }
        device = (pool, serial)
        return (pool, serial)
    }

    /// Per-metric history for the detail view. Cached for 10 minutes per range.
    func history(_ range: HistoryRange) async throws -> [Metric: [TimedValue]] {
        if let c = historyCache[range], Date.now.timeIntervalSince(c.fetched) < 600 { return c.series }
        guard let creds = KeychainStore.load() else { throw BlueriiotAPI.APIError.authentication("not signed in") }
        let api = client(for: creds)
        let (pool, serial) = try await resolveDevice(api)
        let end = Date.now
        var merged: [Metric: [TimedValue]] = [:]
        // Same defensive 30-day windows as the Python client (no server cap was observed).
        var windowStart = end.addingTimeInterval(-range.duration)
        while windowStart < end {
            let windowEnd = min(windowStart.addingTimeInterval(30 * 86400), end)
            let payload = try await api.measures(pool: pool.id, serial: serial, start: windowStart, end: windowEnd)
            for (m, pts) in SnapshotBuilder.history(from: payload) { merged[m, default: []] += pts }
            windowStart = windowEnd
        }
        let series = merged.mapValues { Array(Set($0)).sorted { $0.date < $1.date } }
        historyCache[range] = (.now, series)
        return series
    }

    func saveCredentials(email: String, password: String) async {
        do {
            try KeychainStore.save(.init(email: email, password: password))
            api = nil; apiEmail = nil; device = nil; historyCache = [:]
            lastReload = .distantPast
            await refresh()
        } catch {
            lastError = "Could not save to Keychain (\(error.localizedDescription))"
        }
    }

    func signOut() {
        KeychainStore.delete()
        api = nil; apiEmail = nil; device = nil; historyCache = [:]
        lastReload = .distantPast
        write(.notConfigured())
    }
}

enum HistoryRange: String, CaseIterable, Identifiable, Hashable {
    case day = "24 h", week = "7 days", month = "30 days", quarter = "90 days"
    var id: String { rawValue }
    var duration: TimeInterval {
        switch self {
        case .day: 86400
        case .week: 7 * 86400
        case .month: 30 * 86400
        case .quarter: 90 * 86400
        }
    }
}

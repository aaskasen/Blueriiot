import XCTest

final class SigV4Tests: XCTestCase {
    /// Vector generated with botocore SigV4Auth (the signer used by the verified Python client),
    /// time frozen at 2026-10-18T12:34:56Z.
    func testMatchesBotocore() {
        let signer = SigV4Signer(accessKey: "ASIAFAKEFAKEFAKEFAKE",
                                 secretKey: "fakefakefakefakefakefakefakefakefakefake",
                                 sessionToken: "fake-session-token")
        let date = ISO8601DateFormatter().date(from: "2026-10-18T12:34:56Z")!
        let query = SigV4Signer.canonicalQuery([("start_date", "2026-10-17T00:00:00.000Z"),
                                                ("end_date", "2026-10-18T00:00:00.000Z")])
        XCTAssertEqual(query, "end_date=2026-10-18T00%3A00%3A00.000Z&start_date=2026-10-17T00%3A00%3A00.000Z")
        let h = signer.headers(host: "api.riiotlabs.com",
                               path: "/prod/swimming_pool/00000000-0000-4000-8000-000000000000/blue/SERIAL01/measures",
                               canonicalQuery: query, date: date)
        XCTAssertEqual(h["X-Amz-Date"], "20261018T123456Z")
        XCTAssertEqual(h["Authorization"],
            "AWS4-HMAC-SHA256 Credential=ASIAFAKEFAKEFAKEFAKE/20261018/eu-west-1/execute-api/aws4_request, " +
            "SignedHeaders=host;x-amz-date;x-amz-security-token, " +
            "Signature=c01af9d70c5a6d30f734f44e2e9f0430a51691ea86fafe713bfa56c2c4de07aa")
    }

    func testSignedRequestURLUsesSameEncodingAsSignature() {
        let signer = SigV4Signer(accessKey: "a", secretKey: "b", sessionToken: "c")
        let req = signer.signedGET(host: "api.riiotlabs.com", path: "/prod/x", query: [("start_date", "2026-10-17T00:00:00.000Z")])
        XCTAssertEqual(req.url?.absoluteString, "https://api.riiotlabs.com/prod/x?start_date=2026-10-17T00%3A00%3A00.000Z")
        XCTAssertEqual(req.value(forHTTPHeaderField: "X-Amz-Security-Token"), "c")
    }
}

final class ParsingTests: XCTestCase {
    func json(_ s: String) -> [String: Any] { try! JSONSerialization.jsonObject(with: Data(s.utf8)) as! [String: Any] }

    // Shapes mirror ../blueriiot-re/tests/fixtures (synthetic IDs).
    lazy var last = json("""
    {"status":"OK","last_blue_measure_timestamp":"2026-10-18T09:35:00.000Z","data":[
     {"name":"temperature","timestamp":"2026-10-18T09:35:00.000Z","expired":false,"value":21.4,"ok_min":20,"ok_max":40},
     {"name":"ph","timestamp":"2026-10-18T09:35:00.000Z","expired":false,"value":7.4,"ok_min":7.2,"ok_max":7.6},
     {"name":"ph","timestamp":"2026-10-19T10:00:00.000Z","expired":true,"value":6.9,"issuer":"strip"},
     {"name":"orp","timestamp":"2026-10-18T09:35:00.000Z","expired":false,"value":307,"ok_min":650,"ok_max":750},
     {"name":"conductivity","timestamp":"2026-10-18T09:35:00.000Z","expired":false,"value":1199,"ok_min":300,"ok_max":10000},
     {"name":"salinity","timestamp":"2026-10-18T09:35:00.000Z","expired":false,"value":0.6}]}
    """)
    lazy var measures = json("""
    {"data":[
     {"created":"2026-10-18T08:23:00.000Z","data":{"temperature":21.6,"ph":7.41,"orp":310,"conductivity":1190,"salinity":0.6}},
     {"created":"2026-10-18T09:35:00.000Z","data":{"temperature":21.4,"ph":7.4,"orp":307,"conductivity":1199}},
     {"created":"2026-10-18T09:35:00.000Z","data":{"temperature":21.4,"ph":7.4,"orp":307,"conductivity":1199}},
     {"created":"2026-10-18T07:10:00.000Z","data":{"temperature":"NaN","ph":99,"orp":305}}],
     "ranges":{"ph":{"min":7.2,"max":7.6,"ideal":7.3}}}
    """)

    func testLatestPrefersNonExpiredAndKeepsRanges() {
        let l = SnapshotBuilder.latest(from: last)
        XCTAssertEqual(l[.ph]?.value, 7.4)              // expired strip reading ignored even though newer
        XCTAssertEqual(l[.orp]?.range, MetricRange(min: 650, max: 750))
        XCTAssertNil(Metric(rawValue: "salinity"))      // salinity is never one of the four widget metrics
        XCTAssertEqual(l.count, 4)
    }

    func testHistorySortedDedupedAndImplausibleDropped() {
        let h = SnapshotBuilder.history(from: measures)
        XCTAssertEqual(h[.temperature]?.count, 2)       // duplicate removed, "NaN" string dropped
        XCTAssertEqual(h[.ph]?.count, 2)                // pH 99 dropped as implausible
        XCTAssertEqual(h[.orp]?.map(\.value), [305, 310, 307]) // sorted by measurement time
    }

    func testBuildSnapshotNeverSubstitutesSalinity() {
        let s = SnapshotBuilder.build(pool: .init(id: "p", name: "Test Pool"), device: ["battery_low": true, "gateway_id": "BLEX-AA"],
                                      lastMeasurements: last, measures: measures, fetchedAt: Date())
        XCTAssertEqual(s.conductivityValue, 1199)
        XCTAssertEqual(s.conductivityUnit, "µS/cm")
        XCTAssertEqual(s.measuredAt, CloudDate.parse("2026-10-18T09:35:00.000Z"))
        XCTAssertEqual(s.batteryLow, true)
        XCTAssertEqual(s.viaExtender, true)
        XCTAssertEqual(s.sourceStatus, .healthy)
        XCTAssertFalse(s.isMock)

        var noCond = last
        noCond["data"] = (last["data"] as! [[String: Any]]).filter { $0["name"] as? String != "conductivity" }
        let s2 = SnapshotBuilder.build(pool: .init(id: "p", name: "P"), device: [:], lastMeasurements: noCond, measures: nil, fetchedAt: Date())
        XCTAssertNil(s2.conductivityValue)               // salinity present but NOT used as conductivity
        XCTAssertNil(s2.conductivityUnit)
        XCTAssertTrue(s2.temperatureHistory.isEmpty)
    }

    func testCloudDateRoundTrip() {
        let d = CloudDate.parse("2026-10-17T17:45:00.000Z")!
        XCTAssertEqual(CloudDate.format(d), "2026-10-17T17:45:00.000Z")
        XCTAssertNotNil(CloudDate.parse("2026-10-17T17:45:00Z"))
        XCTAssertNil(CloudDate.parse("17/10/2026"))
    }
}

final class PresentationTests: XCTestCase {
    func testFormatting() {
        XCTAssertEqual(Metric.temperature.format(27.44), "27.4")
        XCTAssertEqual(Metric.ph.format(7.2), "7.20")
        XCTAssertEqual(Metric.orp.format(701.6), "702")
        XCTAssertEqual(Metric.conductivity.format(1484), "1480")
        XCTAssertEqual(Metric.conductivity.format(17), "17")
        XCTAssertEqual(Metric.ph.format(nil), "—")
        XCTAssertEqual(Metric.ph.format(.nan), "—")
        XCTAssertEqual(Metric.orp.unit, "mV")
        XCTAssertEqual(Metric.orp.label, "Sanitation")
    }

    func testStateUsesOnlyProvidedRanges() {
        XCTAssertEqual(metricState(7.3, range: .init(min: 7.2, max: 7.6)), .normal)
        XCTAssertEqual(metricState(307, range: .init(min: 650, max: 750)), .attention)
        XCTAssertEqual(metricState(307, range: nil), .unknown)
        XCTAssertEqual(metricState(nil, range: .init(min: 1, max: 2)), .unknown)
        // With the server's warning bounds: same three verdicts as the official app.
        let orp = MetricRange(min: 650, max: 750, warningLow: 400, warningHigh: 900, gaugeMin: 300, gaugeMax: 1000)
        XCTAssertEqual(metricState(307, range: orp), .bad)
        XCTAssertEqual(metricState(500, range: orp), .attention)
        XCTAssertEqual(metricState(700, range: orp), .normal)
        XCTAssertEqual(metricState(950, range: orp), .bad)
    }

    func testFreshnessDistinguishesMeasurementFromFetch() {
        let now = Date()
        var s = MockData.snapshot(now: now, measuredAgo: 20 * 60)
        XCTAssertEqual(s.displayState(now: now), .fresh)
        s.measuredAt = now.addingTimeInterval(-4 * 3600)   // fetched just now, but old sensor reading
        s.fetchedAt = now
        XCTAssertEqual(s.displayState(now: now), .stale)
        XCTAssertEqual(s.footerText(now: now), "Last reading 4\u{00A0}h ago")
        s.sourceStatus = .offline
        XCTAssertEqual(s.footerText(now: now), "Unable to refresh · reading 4\u{00A0}h ago")
        s.sourceStatus = .authenticationNeeded
        XCTAssertEqual(s.footerText(now: now), "Sign in to refresh")
        XCTAssertEqual(PoolWidgetSnapshot.notConfigured().footerText(now: now), "Open app to connect BlueRiiot")
    }

    func testDeltaRequiresRealEarlierReading() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let h = [TimedValue(date: t0, value: 25), TimedValue(date: t0.addingTimeInterval(24 * 3600), value: 24)]
        XCTAssertEqual(delta(h, metric: .temperature)?.direction, .down)
        XCTAssertEqual(delta(h, metric: .temperature)?.change ?? 0, -1, accuracy: 1e-9)
        let short = [TimedValue(date: t0, value: 25), TimedValue(date: t0.addingTimeInterval(6 * 3600), value: 24)]
        XCTAssertNil(delta(short, metric: .temperature))   // nothing near 24 h earlier → no arrow
    }

    func testSparklineSplitsAtGapsAndNeedsEnoughPoints() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let pts = [0, 1, 2, 8, 9].map { TimedValue(date: t0.addingTimeInterval(Double($0) * 3600), value: Double($0)) }
        XCTAssertEqual(sparklineSegments(pts).map(\.count), [3, 2])
        XCTAssertEqual(sparklineSegments(Array(pts.prefix(3))).count, 0)
    }

    func testRelativeAge() {
        let now = Date()
        XCTAssertEqual(relativeAge(from: now.addingTimeInterval(-30), to: now), "just now")
        XCTAssertEqual(relativeAge(from: now.addingTimeInterval(-14 * 60), to: now), "14\u{00A0}min ago")
        XCTAssertEqual(relativeAge(from: now.addingTimeInterval(-3 * 86400), to: now), "3\u{00A0}d ago")
    }
}

final class SnapshotStoreTests: XCTestCase {
    func testRoundTripAndAtomicWrite() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        let s = MockData.snapshot()
        try SnapshotStore.write(s, to: url)
        let back = try XCTUnwrap(SnapshotStore.read(from: url))
        XCTAssertEqual(back.ranges[.orp], s.ranges[.orp])
        XCTAssertEqual(back.temperatureHistory.count, s.temperatureHistory.count)
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(text.lowercased().contains("password"))
        XCTAssertFalse(text.lowercased().contains("token"))
    }

    func testMigratesMinimalOldSnapshotAndRejectsFutureSchema() {
        let minimal = #"{"poolID":"p","poolName":"Pool","fetchedAt":"2026-10-18T10:00:00Z"}"#
        let s = SnapshotStore.decode(Data(minimal.utf8))
        XCTAssertNotNil(s)
        XCTAssertEqual(s?.schemaVersion, 1)
        XCTAssertEqual(s?.sourceStatus, .offline)       // unknown provenance → never shown as fresh
        XCTAssertTrue(s?.phHistory.isEmpty ?? false)
        let future = #"{"schemaVersion":99,"poolID":"p","poolName":"Pool","fetchedAt":"2026-10-18T10:00:00Z","sourceStatus":"healthy"}"#
        XCTAssertNil(SnapshotStore.decode(Data(future.utf8)))
        XCTAssertNil(SnapshotStore.decode(Data("garbage".utf8)))
    }
}

import Foundation

/// Swift port of the *verified* read-only calls of ../blueriiot-re/client (see API_SPECIFICATION.md).
/// Only: user/login, swimming_pool, swimming_pool/{p}/blue, blue/{s}, lastMeasurements, measures.
actor BlueriiotAPI {
    enum APIError: Error, Equatable {
        case authentication(String)
        case http(Int, String)
        case server(String)        // HTTP 200 with {"errorMessage": …}
        case decoding(String)
        case noPoolOrDevice
    }

    struct Session {
        let signer: SigV4Signer
        let expiration: Date
    }

    static let host = "api.riiotlabs.com"
    static let basePath = "/prod/"

    private let email: String
    private let password: String
    private let urlSession: URLSession
    private var session: Session?

    init(email: String, password: String, urlSession: URLSession = .shared) {
        self.email = email
        self.password = password
        self.urlSession = urlSession
    }

    // MARK: auth

    func login() async throws {
        var req = URLRequest(url: URL(string: "https://\(Self.host)\(Self.basePath)user/login")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["email": email, "password": password])
        req.timeoutInterval = 20
        let (data, resp) = try await urlSession.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if [400, 401, 403].contains(status) { throw APIError.authentication("login rejected (HTTP \(status))") }
        guard status == 200 else { throw APIError.http(status, "user/login") }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let c = obj["credentials"] as? [String: Any],
              let ak = c["access_key"] as? String, let sk = c["secret_key"] as? String,
              let st = c["session_token"] as? String else {
            throw APIError.authentication("login response lacked credentials")
        }
        let exp = (c["expiration"] as? String).flatMap(CloudDate.parse) ?? Date().addingTimeInterval(55 * 60)
        session = Session(signer: SigV4Signer(accessKey: ak, secretKey: sk, sessionToken: st), expiration: exp)
    }

    private func ensureSession() async throws -> Session {
        if let s = session, Date() < s.expiration.addingTimeInterval(-5 * 60) { return s }
        try await login()
        return session!
    }

    // MARK: transport

    func getJSON(_ path: String, query: [(String, String)] = []) async throws -> Any {
        var relogged = false
        for attempt in 0..<4 {
            let s = try await ensureSession()
            var req = s.signer.signedGET(host: Self.host, path: Self.basePath + path, query: query)
            req.timeoutInterval = 20
            let data: Data, resp: URLResponse
            do {
                (data, resp) = try await urlSession.data(for: req)
            } catch {
                if attempt == 3 { throw error }
                try await Task.sleep(for: .seconds(pow(2, Double(attempt))))
                continue
            }
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if (status == 401 || status == 403) && !relogged {
                relogged = true; session = nil; continue
            }
            if (status == 429 || status >= 500) && attempt < 3 {
                try await Task.sleep(for: .seconds(pow(2, Double(attempt))))
                continue
            }
            if status == 401 || status == 403 { throw APIError.authentication("HTTP \(status)") }
            guard status == 200 else { throw APIError.http(status, path) }
            let obj = try JSONSerialization.jsonObject(with: data)
            if let d = obj as? [String: Any], let msg = d["errorMessage"] as? String { throw APIError.server(msg) }
            return obj
        }
        throw APIError.http(0, path)
    }

    // MARK: verified reads

    struct PoolRef: Sendable { let id: String; let name: String }

    func pools() async throws -> [PoolRef] {
        let obj = try await getJSON("swimming_pool", query: [("deleted", "false")]) as? [String: Any]
        return ((obj?["data"] as? [[String: Any]]) ?? []).compactMap { p in
            guard let id = p["swimming_pool_id"] as? String else { return nil }
            let name = ((p["swimming_pool"] as? [String: Any])?["name"] as? String) ?? (p["name"] as? String) ?? "Pool"
            return PoolRef(id: id, name: name)
        }
    }

    func deviceSerials(pool: String) async throws -> [String] {
        let obj = try await getJSON("swimming_pool/\(pool)/blue") as? [String: Any]
        return ((obj?["data"] as? [[String: Any]]) ?? []).compactMap { $0["blue_device_serial"] as? String }
    }

    func device(serial: String) async throws -> [String: Any] {
        (try await getJSON("blue/\(serial)") as? [String: Any]) ?? [:]
    }

    func lastMeasurements(pool: String, serial: String) async throws -> [String: Any] {
        (try await getJSON("swimming_pool/\(pool)/blue/\(serial)/lastMeasurements",
                           query: [("mode", "blue_and_strip")]) as? [String: Any]) ?? [:]
    }

    func measures(pool: String, serial: String, start: Date, end: Date) async throws -> [String: Any] {
        (try await getJSON("swimming_pool/\(pool)/blue/\(serial)/measures",
                           query: [("start_date", CloudDate.format(start)), ("end_date", CloudDate.format(end))])
            as? [String: Any]) ?? [:]
    }
}

/// Cloud timestamps look like "2026-10-17T17:45:00.000Z" (UTC, milliseconds).
enum CloudDate {
    static func parse(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    /// Full ISO-8601 with milliseconds. Required: the server compares bounds as strings.
    static func format(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: d)
    }
}

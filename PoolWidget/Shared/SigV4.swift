import CryptoKit
import Foundation

/// Minimal AWS Signature V4 for GET requests to API Gateway (`execute-api`).
/// Signed headers: host, x-amz-date, x-amz-security-token — the same set botocore
/// produces for the Python client (verified by SigV4Tests against a botocore vector).
struct SigV4Signer: Sendable {
    let accessKey: String
    let secretKey: String
    let sessionToken: String
    var region = "eu-west-1"
    var service = "execute-api"

    /// RFC 3986 unreserved characters; everything else is percent-encoded.
    static let unreserved = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    static func encode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: unreserved) ?? s
    }

    /// Canonical query string: keys sorted, keys and values RFC 3986-encoded.
    static func canonicalQuery(_ items: [(String, String)]) -> String {
        let encoded: [(key: String, value: String)] = items.map { (key: encode($0.0), value: encode($0.1)) }
        let sorted = encoded.sorted { a, b in a.key == b.key ? a.value < b.value : a.key < b.key }
        return sorted.map { "\($0.key)=\($0.value)" }.joined(separator: "&")
    }

    /// Builds a signed GET request. `path` must already be URL-safe (it is: UUIDs/serials).
    func signedGET(host: String, path: String, query: [(String, String)], date: Date = .now) -> URLRequest {
        let q = Self.canonicalQuery(query)
        var comps = URLComponents()
        comps.scheme = "https"
        comps.host = host
        comps.percentEncodedPath = path
        if !q.isEmpty { comps.percentEncodedQuery = q }
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "GET"
        for (k, v) in headers(host: host, path: path, canonicalQuery: q, date: date) {
            req.setValue(v, forHTTPHeaderField: k)
        }
        return req
    }

    func headers(host: String, path: String, canonicalQuery: String, date: Date) -> [String: String] {
        let amzDate = Self.amzDate(date)
        let day = String(amzDate.prefix(8))
        let signedHeaders = "host;x-amz-date;x-amz-security-token"
        let canonicalHeaders = "host:\(host)\nx-amz-date:\(amzDate)\nx-amz-security-token:\(sessionToken)\n"
        let payloadHash = Self.hex(SHA256.hash(data: Data()))
        let canonicalRequest = ["GET", path, canonicalQuery, canonicalHeaders, signedHeaders, payloadHash]
            .joined(separator: "\n")
        let scope = "\(day)/\(region)/\(service)/aws4_request"
        let stringToSign = ["AWS4-HMAC-SHA256", amzDate, scope,
                            Self.hex(SHA256.hash(data: Data(canonicalRequest.utf8)))].joined(separator: "\n")
        var key = SymmetricKey(data: Data("AWS4\(secretKey)".utf8))
        for part in [day, region, service, "aws4_request"] {
            key = SymmetricKey(data: Data(HMAC<SHA256>.authenticationCode(for: Data(part.utf8), using: key)))
        }
        let signature = Self.hex(HMAC<SHA256>.authenticationCode(for: Data(stringToSign.utf8), using: key))
        return [
            "X-Amz-Date": amzDate,
            "X-Amz-Security-Token": sessionToken,
            "Authorization": "AWS4-HMAC-SHA256 Credential=\(accessKey)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(signature)",
        ]
    }

    static func amzDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return f.string(from: date)
    }

    static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

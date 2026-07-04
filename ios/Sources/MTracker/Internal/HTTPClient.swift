import Foundation
import CryptoKit

/// Outcome of a batch POST, so the caller can decide ack vs. retry vs. backoff.
enum PostResult {
    /// 2xx — server accepted (some may be duplicates); safe to `ack` the batch.
    case success(accepted: Int, duplicates: Int)
    /// 401 — bad signature / unknown key. Do NOT retry blindly (config bug), but keep
    /// events so a corrected key on next launch can still deliver them.
    case authFailure
    /// 429 — buffer full / rate limited. Keep events, back off for `retryAfter` seconds.
    case rateLimited(retryAfter: TimeInterval)
    /// Network / 5xx / transport error. Keep events, exponential backoff.
    case transientFailure
}

/// Transports event batches to ingest.
///
/// Wire contract (docs/sdk-contract §2, §3), verified against the Go `ingest` service
/// (`services/ingest/main.go` + `pkg/authx/hmac.go`):
///
///   POST {ingestBaseURL}/v1/events
///   Content-Type:   application/json
///   X-MT-Key:       <public sdk key>
///   X-MT-Timestamp: <unix seconds, integer>
///   X-MT-Signature: hex( HMAC-SHA256( sdkSecret, "<ts>." + <raw body bytes> ) )
///
/// The signed message is EXACTLY `"{ts}." + body` over the *same raw bytes* that are
/// transmitted — so the body is encoded once and both signed and sent as-is. Any
/// divergence (re-encoding, key ordering change, whitespace) yields a 401.
final class HTTPClient: @unchecked Sendable {
    private let config: MTrackerConfig
    private let session: URLSession
    private let logger: MTLogger

    static let eventsPath = "/v1/events"

    init(config: MTrackerConfig, logger: MTLogger) {
        self.config = config
        self.logger = logger

        let sc = URLSessionConfiguration.default
        sc.timeoutIntervalForRequest = 30
        sc.timeoutIntervalForResource = 60
        sc.waitsForConnectivity = true
        sc.httpAdditionalHeaders = ["User-Agent": Self.userAgent]
        self.session = URLSession(configuration: sc)
    }

    private static let userAgent: String = {
        "mtracker-ios/\(MTracker.sdkVersion)"
    }()

    /// Sends a batch of events. Returns a `PostResult` classifying the response.
    func postEvents(_ events: [QueuedEvent]) async -> PostResult {
        guard let url = URL(string: config.ingestBaseURL + Self.eventsPath) else {
            logger.error("invalid ingest URL")
            return .transientFailure
        }
        guard !events.isEmpty else {
            return .success(accepted: 0, duplicates: 0)
        }

        // 1. Encode the body ONCE. These exact bytes are both signed and sent.
        let body: Data
        do {
            body = try encodeBatch(events)
        } catch {
            logger.error("batch encode failed: \(error.localizedDescription)")
            // Encoding failure is not transient — but we don't want to poison the
            // queue forever either. Treat as transient; the batch shrink/retry path
            // in the sender will eventually isolate a bad event.
            return .transientFailure
        }

        // 2. Sign: message = "{ts}." + rawBody, HMAC-SHA256 keyed by sdkSecret, lowercase hex.
        let ts = Int64(Date().timeIntervalSince1970)
        let signature = Self.sign(secret: config.sdkSecret, timestamp: ts, body: body)

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = body
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(config.sdkKey, forHTTPHeaderField: "X-MT-Key")
        req.setValue(String(ts), forHTTPHeaderField: "X-MT-Timestamp")
        req.setValue(signature, forHTTPHeaderField: "X-MT-Signature")

        do {
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                return .transientFailure
            }
            switch http.statusCode {
            case 200...299:
                let (accepted, duplicates) = Self.parseAccepted(data)
                logger.debug("batch accepted=\(accepted) duplicates=\(duplicates)")
                return .success(accepted: accepted, duplicates: duplicates)
            case 401:
                logger.error("ingest 401 — check sdkKey/sdkSecret (HMAC mismatch)")
                return .authFailure
            case 429:
                let retryAfter = Self.retryAfterSeconds(http) ?? 2
                logger.warn("ingest 429 — backpressure, retry after \(retryAfter)s")
                return .rateLimited(retryAfter: retryAfter)
            default:
                logger.warn("ingest HTTP \(http.statusCode)")
                return .transientFailure
            }
        } catch {
            logger.warn("ingest transport error: \(error.localizedDescription)")
            return .transientFailure
        }
    }

    // MARK: - Signing

    /// Computes `hex(HMAC-SHA256(secret, "{ts}." + body))` — lowercase hex, exactly as
    /// the backend's `authx.VerifyRequest` expects.
    static func sign(secret: String, timestamp: Int64, body: Data) -> String {
        var message = Data()
        message.append(contentsOf: Array("\(timestamp).".utf8)) // "{ts}."
        message.append(body)                                    // raw body bytes

        let key = SymmetricKey(data: Data(secret.utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: message, using: key)
        // CryptoKit MAC -> lowercase hex.
        return mac.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Body encoding

    /// Serialises events into the batch envelope required by ingest:
    /// `{ "sdk_key", "platform":"ios", "events":[ {event}, ... ] }` (docs/sdk-contract §3).
    ///
    /// Built with `JSONSerialization` on an ordered `[String: Any]` so we can inline the
    /// pre-encoded `params` object and omit optional keys exactly like the Go
    /// `omitempty` fields — keeping the payload compact and predictable.
    func encodeBatch(_ events: [QueuedEvent]) throws -> Data {
        var eventObjects: [[String: Any]] = []
        eventObjects.reserveCapacity(events.count)

        for e in events {
            var obj: [String: Any] = [
                "event_id": e.eventId,
                "app_id": e.appId,
                "install_id": e.installId,
                "name": e.name,
                "ts": e.ts,
            ]
            if let sid = e.sessionId, !sid.isEmpty { obj["session_id"] = sid }
            if let rev = e.revenue { obj["revenue"] = rev }
            if let cur = e.currency, !cur.isEmpty { obj["currency"] = cur }
            if let token = e.matchToken, !token.isEmpty { obj["match_token"] = token }
            if let fp = e.deviceFP, !fp.isEmpty { obj["device_fp"] = fp }
            if let pj = e.paramsJSON,
               let params = try? JSONSerialization.jsonObject(with: pj) {
                obj["params"] = params
            }
            eventObjects.append(obj)
        }

        let envelope: [String: Any] = [
            "sdk_key": config.sdkKey,
            "platform": "ios",
            "events": eventObjects,
        ]
        return try JSONSerialization.data(withJSONObject: envelope, options: [])
    }

    // MARK: - Response parsing

    private static func parseAccepted(_ data: Data) -> (Int, Int) {
        guard
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return (0, 0) }
        let accepted = (obj["accepted"] as? Int) ?? 0
        let duplicates = (obj["duplicates"] as? Int) ?? 0
        return (accepted, duplicates)
    }

    /// Parses `Retry-After` (integer seconds or HTTP-date) per the contract.
    private static func retryAfterSeconds(_ response: HTTPURLResponse) -> TimeInterval? {
        guard let raw = response.value(forHTTPHeaderField: "Retry-After") else { return nil }
        if let secs = TimeInterval(raw.trimmingCharacters(in: .whitespaces)) {
            return max(0, secs)
        }
        // HTTP-date form.
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(identifier: "GMT")
        fmt.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        if let date = fmt.date(from: raw) {
            return max(0, date.timeIntervalSinceNow)
        }
        return nil
    }
}

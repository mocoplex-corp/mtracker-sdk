import Foundation

/// Transport for the App Ops surface (docs/appops-contract §2, §3).
///
/// Two endpoints on the ingest host family:
///   - GET  {ingestBaseURL}/v1/appops        — delivery (config/messages/update). PUBLIC, no HMAC.
///   - POST {ingestBaseURL}/v1/push/register — push token registration. HMAC-signed exactly
///     like events, reusing `HTTPClient.sign` (the shared signer).
final class AppOpsClient: @unchecked Sendable {
    private let config: MTrackerConfig
    private let logger: MTLogger
    private let session: URLSession

    static let appOpsPath = "/v1/appops"
    static let pushRegisterPath = "/v1/push/register"

    init(config: MTrackerConfig, logger: MTLogger) {
        self.config = config
        self.logger = logger
        let sc = URLSessionConfiguration.default
        sc.timeoutIntervalForRequest = 15
        sc.httpAdditionalHeaders = ["User-Agent": "mtracker-ios/\(MTracker.sdkVersion)"]
        self.session = URLSession(configuration: sc)
    }

    /// GETs the App Ops payload. Returns the parsed JSON object (config/messages/update) or
    /// nil on any failure. Public endpoint — NO HMAC (tenant resolved from app_id).
    func fetch(
        platform: String,
        appVersion: String,
        lang: String,
        installId: String,
        sessionSec: Int64,
        sessionCount: Int64
    ) async -> [String: Any]? {
        var comps = URLComponents(string: config.ingestBaseURL + Self.appOpsPath)
        comps?.queryItems = [
            URLQueryItem(name: "app_id", value: config.appId),
            URLQueryItem(name: "platform", value: platform),
            URLQueryItem(name: "app_version", value: appVersion),
            URLQueryItem(name: "lang", value: lang),
            URLQueryItem(name: "install_id", value: installId),
            URLQueryItem(name: "session_sec", value: String(sessionSec)),
            URLQueryItem(name: "session_count", value: String(sessionCount)),
        ]
        guard let url = comps?.url else { return nil }

        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                logger.debug("appops fetch non-2xx")
                return nil
            }
            return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        } catch {
            logger.debug("appops fetch failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// POSTs the push-token registration (docs/appops-contract §3). HMAC-signed like events:
    /// X-MT-Key / X-MT-Timestamp / X-MT-Signature over `"<ts>." + rawBody`.
    func registerPush(
        platform: String,
        installId: String,
        token: String,
        lang: String
    ) async -> Bool {
        guard let url = URL(string: config.ingestBaseURL + Self.pushRegisterPath) else { return false }

        // Ordered payload; the exact bytes are both signed and sent.
        let payload: [String: Any] = [
            "app_id": config.appId,
            "install_id": installId,
            "platform": platform,
            "token": token,
            "lang": lang,
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload, options: []) else {
            return false
        }

        let ts = Int64(Date().timeIntervalSince1970)
        // Reuse the event signer — identical HMAC contract (docs/sdk-contract §2).
        let signature = HTTPClient.sign(secret: config.sdkSecret, timestamp: ts, body: body)

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = body
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(config.sdkKey, forHTTPHeaderField: "X-MT-Key")
        req.setValue(String(ts), forHTTPHeaderField: "X-MT-Timestamp")
        req.setValue(signature, forHTTPHeaderField: "X-MT-Signature")

        do {
            let (_, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse else { return false }
            let ok = (200...299).contains(http.statusCode)
            if ok { logger.debug("push token registered") } else { logger.warn("push register HTTP \(http.statusCode)") }
            return ok
        } catch {
            logger.warn("push register failed: \(error.localizedDescription)")
            return false
        }
    }
}

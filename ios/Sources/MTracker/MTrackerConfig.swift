import Foundation

/// Log verbosity for the SDK. Mirrors the Android/RN/Flutter enums.
public enum LogLevel: String, Sendable {
    case none, error, warn, info, debug
}

/// Initialization config. Mirrors `Ja0Tracker.initialize({...})` in docs/sdk-contract §5.
///
/// `sdkKey` (public key) and `sdkSecret` (hmac secret) are both issued together when a
/// tenant creates an SDK key in the dashboard (`/dashboard/mtracker/apps`); the secret
/// is shown once. Both are injected here and used to sign every event request
/// (docs/sdk-contract §2). Embedding the secret in a client has known limits — this is
/// documented and can later be hardened with a challenge scheme (contract note §2).
public struct Ja0TrackerConfig: Sendable {
    /// Public tenant SDK key (contract `public_key`, e.g. `pk_ja0_demo`). Sent as
    /// `X-MT-Key` and in the batch `sdk_key` field. Required.
    public let sdkKey: String

    /// HMAC secret (contract `hmac_secret`) used to sign requests. Required. Never log.
    public let sdkSecret: String

    /// App id (UUID) issued in the dashboard, sent as each event's `app_id`. Required.
    /// The backend treats the key-pinned app_id as authoritative but the SDK still
    /// sends it (contract §3).
    public let appId: String

    public let logLevel: LogLevel

    /// Privacy-first default. When true, deterministic (clipboard) / fingerprint
    /// matching AND identified analytics events stay disabled until consent + ATT are
    /// granted (docs/sdk-contract §4). SKAN/AAK aggregate attribution runs regardless.
    public let waitForConsent: Bool

    /// Event ingest base URL, batch POST /v1/events.
    public let ingestBaseURL: String
    /// clickd / deep link + ad-click resolution base URL.
    public let clickdBaseURL: String
    /// Native ad request base URL (adserver public host). Defaults to clickd host until
    /// the adserver is publicly exposed (docs/sdk-contract §1).
    public let adBaseURL: String

    public static let defaultIngestBaseURL = "https://ingest-mtracker.ja0.com"
    public static let defaultClickdBaseURL = "https://go-mtracker.ja0.com"
    public static let defaultAdBaseURL = "https://go-mtracker.ja0.com"

    public init(
        sdkKey: String,
        sdkSecret: String,
        appId: String,
        logLevel: LogLevel = .info,
        waitForConsent: Bool = true,
        ingestBaseURL: String = Ja0TrackerConfig.defaultIngestBaseURL,
        clickdBaseURL: String = Ja0TrackerConfig.defaultClickdBaseURL,
        adBaseURL: String = Ja0TrackerConfig.defaultAdBaseURL
    ) {
        self.sdkKey = sdkKey
        self.sdkSecret = sdkSecret
        self.appId = appId
        self.logLevel = logLevel
        self.waitForConsent = waitForConsent
        self.ingestBaseURL = ingestBaseURL
        self.clickdBaseURL = clickdBaseURL
        self.adBaseURL = adBaseURL
    }
}

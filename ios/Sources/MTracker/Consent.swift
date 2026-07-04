import Foundation

/// Per-purpose consent flags (GDPR-style). Gates data collection scope
/// (docs/sdk.md §3.4). All default to false — privacy-first.
///
/// On iOS, `attribution`/`ads` additionally require ATT authorization before
/// fingerprint/clipboard matching runs; see `requestTrackingConsent()`.
public struct Consent: Sendable {
    public var analytics: Bool
    public var attribution: Bool
    public var ads: Bool

    public init(analytics: Bool = false, attribution: Bool = false, ads: Bool = false) {
        self.analytics = analytics
        self.attribution = attribution
        self.ads = ads
    }
}

/// Result of `requestTrackingConsent()`. On iOS this maps to
/// `ATTrackingManager.AuthorizationStatus`; on Android it is always `.granted`.
public enum TrackingConsentStatus: String, Sendable {
    case granted
    case denied
    case restricted
    case notDetermined
}

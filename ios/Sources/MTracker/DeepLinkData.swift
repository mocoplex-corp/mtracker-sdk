import Foundation

/// Deferred deep link context restored on first launch after install, or a direct
/// deep link when the app is already installed (docs/attribution.md §5).
///
/// Deliver to `onDeepLink`; the app routes on `path` + `params`.
public struct DeepLinkData: Sendable {
    /// e.g. "/product/123" — the `$deeplink_path` from link creation.
    public let path: String?
    /// Custom link parameters (contentId, referrer, promoCode, ...).
    public let params: [String: String]
    /// Full original URL if available.
    public let url: String?
    /// True when restored after a fresh install (deferred), false for a live click.
    public let isDeferred: Bool

    public init(
        path: String?,
        params: [String: String] = [:],
        url: String? = nil,
        isDeferred: Bool = false
    ) {
        self.path = path
        self.params = params
        self.url = url
        self.isDeferred = isDeferred
    }
}

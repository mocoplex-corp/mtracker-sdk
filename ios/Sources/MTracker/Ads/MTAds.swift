import Foundation

/// Ads accessor, reached via `Ja0Tracker.shared.ads` (docs/sdk-contract §5, docs/ads.md).
/// Requests a native ad by slot ID; the adserver decides which ad fills the slot and
/// returns native assets + tracking URLs (docs/ads.md §6).
public final class MTAds {
    private let config: Ja0TrackerConfig
    private let logger: MTLogger
    private let session: URLSession

    /// Native ad request path on the ad base host (docs/sdk-contract §1: POST /v1/ad).
    private static let adPath = "/v1/ad"

    init(config: Ja0TrackerConfig, logger: MTLogger) {
        self.config = config
        self.logger = logger
        let sc = URLSessionConfiguration.default
        sc.timeoutIntervalForRequest = 10
        sc.httpAdditionalHeaders = ["User-Agent": "mtracker-ios/\(Ja0Tracker.sdkVersion)"]
        self.session = URLSession(configuration: sc)
    }

    /// Loads a native ad for `slotId`. POSTs the slot id + context to the adserver and
    /// parses the winning ad's assets + tracking URLs (docs/ads.md §3, §6), or returns
    /// nil on no-fill / error. Impression/click beacons are fired later by
    /// `MTNativeAdView` when the ad is actually rendered/tapped.
    public func load(slotId: String) async -> NativeAd? {
        guard let url = URL(string: config.adBaseURL + Self.adPath) else { return nil }

        let requestBody: [String: Any] = [
            "sdk_key": config.sdkKey,
            "app_id": config.appId,
            "slot_id": slotId,
            "platform": "ios",
            // Device language so the adserver can pick localized (house-ad) copy.
            "lang": Locale.preferredLanguages.first ?? "en",
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: requestBody) else {
            return nil
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = body
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(config.sdkKey, forHTTPHeaderField: "X-MT-Key")

        do {
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                logger.debug("ad load slot=\(slotId) no-fill/HTTP error")
                return nil
            }
            return Self.parse(data, fallbackSlotId: slotId)
        } catch {
            logger.debug("ad load slot=\(slotId) transport error: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Parsing (docs/ads.md §6 schema)

    static func parse(_ data: Data, fallbackSlotId: String) -> NativeAd? {
        guard
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let adId = obj["adId"] as? String,
            let assetsObj = obj["assets"] as? [String: Any],
            let trackingObj = obj["tracking"] as? [String: Any]
        else { return nil }

        let slotId = (obj["slotId"] as? String) ?? fallbackSlotId
        let format = (obj["format"] as? String) ?? "native"

        var media: NativeAdMedia?
        if let m = assetsObj["media"] as? [String: Any],
           let typeStr = m["type"] as? String,
           let mediaURL = m["url"] as? String,
           let type = NativeAdMedia.MediaType(rawValue: typeStr) {
            media = NativeAdMedia(type: type, url: mediaURL)
        }

        let assets = NativeAdAssets(
            headline: assetsObj["headline"] as? String,
            body: assetsObj["body"] as? String,
            advertiser: assetsObj["advertiser"] as? String,
            cta: assetsObj["cta"] as? String,
            iconURL: assetsObj["icon"] as? String,
            media: media,
            rating: (assetsObj["rating"] as? NSNumber)?.doubleValue
        )

        let impressionURLs = (trackingObj["impression"] as? [String]) ?? []
        guard let clickURL = trackingObj["click"] as? String else { return nil }

        var threshold = ViewableThreshold()
        if let vt = trackingObj["viewableThreshold"] as? [String: Any] {
            let pixels = (vt["pixels"] as? NSNumber)?.doubleValue ?? 0.5
            let ms = (vt["ms"] as? NSNumber)?.intValue ?? 1000
            threshold = ViewableThreshold(pixels: pixels, ms: ms)
        }

        let tracking = NativeAdTracking(
            impressionURLs: impressionURLs,
            clickURL: clickURL,
            viewableThreshold: threshold
        )

        return NativeAd(
            slotId: slotId, adId: adId, format: format,
            assets: assets, tracking: tracking
        )
    }
}

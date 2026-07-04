import Foundation

/// Native ad asset model — mirrors the server rendering contract in docs/ads.md §6.
/// The app renders these assets in its own design system; the SDK owns only the
/// impression/click beacons and click routing.
public struct NativeAdMedia: Sendable {
    public enum MediaType: String, Sendable { case image, video }
    public let type: MediaType
    public let url: String

    public init(type: MediaType, url: String) {
        self.type = type
        self.url = url
    }
}

public struct NativeAdAssets: Sendable {
    public let headline: String?
    public let body: String?
    public let advertiser: String?
    public let cta: String?
    public let iconURL: String?
    public let media: NativeAdMedia?
    public let rating: Double?

    public init(
        headline: String?, body: String?, advertiser: String?, cta: String?,
        iconURL: String?, media: NativeAdMedia?, rating: Double?
    ) {
        self.headline = headline
        self.body = body
        self.advertiser = advertiser
        self.cta = cta
        self.iconURL = iconURL
        self.media = media
        self.rating = rating
    }
}

/// Viewability threshold for a valid impression (docs/ads.md §4, §6).
public struct ViewableThreshold: Sendable {
    public let pixels: Double
    public let ms: Int
    public init(pixels: Double = 0.5, ms: Int = 1000) {
        self.pixels = pixels
        self.ms = ms
    }
}

public struct NativeAdTracking: Sendable {
    public let impressionURLs: [String]
    public let clickURL: String
    public let viewableThreshold: ViewableThreshold

    public init(impressionURLs: [String], clickURL: String, viewableThreshold: ViewableThreshold) {
        self.impressionURLs = impressionURLs
        self.clickURL = clickURL
        self.viewableThreshold = viewableThreshold
    }
}

/// A loaded native ad returned by `MTAds.load`. Rendered via `MTNativeAdView` or a
/// fully-custom app view that reads `assets` directly (docs/ads.md §6).
public struct NativeAd: Sendable {
    public let slotId: String
    public let adId: String
    public let format: String      // "native" | "banner" | "native-video"
    public let assets: NativeAdAssets
    public let tracking: NativeAdTracking

    public init(
        slotId: String, adId: String, format: String,
        assets: NativeAdAssets, tracking: NativeAdTracking
    ) {
        self.slotId = slotId
        self.adId = adId
        self.format = format
        self.assets = assets
        self.tracking = tracking
    }
}

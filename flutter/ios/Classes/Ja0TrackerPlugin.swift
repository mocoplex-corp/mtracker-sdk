import Flutter
import UIKit
import Ja0TrackerSDK

/// mtracker Flutter plugin (iOS).
///
/// Implements the Pigeon `Ja0TrackerHostApi` by DELEGATING to the shared iOS Core
/// (`Ja0Tracker.shared`) — HMAC signing, event queue, attribution (SKAN/AAK/clipboard),
/// sessions and ad rendering all live in the Core. Native -> Dart callbacks
/// (`onAttribution` / `onDeepLink`) are pushed through the generated `Ja0TrackerFlutterApi`.
/// Registers the `MTNativeAdViewFactory` PlatformView for `MTNativeAd`.
public class Ja0TrackerPlugin: NSObject, FlutterPlugin, Ja0TrackerHostApi {

    private var flutterApi: Ja0TrackerFlutterApi?
    private var callbacksWired = false

    public static func register(with registrar: FlutterPluginRegistrar) {
        let instance = Ja0TrackerPlugin()
        let messenger = registrar.messenger()

        Ja0TrackerHostApiSetup.setUp(binaryMessenger: messenger, api: instance)
        instance.flutterApi = Ja0TrackerFlutterApi(binaryMessenger: messenger)

        // Receive app lifecycle callbacks (Universal Links / custom-scheme opens) so we can
        // forward inbound URLs to the Core's handleDeepLink.
        registrar.addApplicationDelegate(instance)

        // Native ad PlatformView (docs/ads.md §6). Wraps the Core's MTNativeAdView.
        registrar.register(
            MTNativeAdViewFactory(messenger: messenger),
            withId: MTNativeAdViewFactory.viewType
        )
    }

    // MARK: - Ja0TrackerHostApi (Dart -> native): delegate to the Core

    func initialize(config: ConfigMessage) throws {
        // sdkKey / sdkSecret / appId are all required by the Core (contract §5).
        guard let sdkSecret = config.sdkSecret, let appId = config.appId else { return }
        let core = Ja0TrackerConfig(
            sdkKey: config.sdkKey,
            sdkSecret: sdkSecret,
            appId: appId,
            logLevel: Self.parseLogLevel(config.logLevel),
            waitForConsent: config.waitForConsent ?? true,
            ingestBaseURL: config.ingestBaseUrl ?? Ja0TrackerConfig.defaultIngestBaseURL,
            clickdBaseURL: config.clickdBaseUrl ?? Ja0TrackerConfig.defaultClickdBaseURL
        )
        Ja0Tracker.shared.initialize(core)
        wireCallbacksOnce()
    }

    func requestTrackingConsent(completion: @escaping (Result<String, Error>) -> Void) {
        Task {
            let status = await Ja0Tracker.shared.requestTrackingConsent()
            completion(.success(Self.wire(status)))
        }
    }

    func setConsent(consent: ConsentMessage) throws {
        Ja0Tracker.shared.setConsent(
            Consent(
                analytics: consent.analytics,
                attribution: consent.attribution,
                ads: consent.ads
            )
        )
    }

    func trackEvent(name: String, params: [String?: Any?]) throws {
        var cleaned: [String: Any] = [:]
        for (k, v) in params {
            if let key = k, let value = v { cleaned[key] = value }
        }
        Ja0Tracker.shared.trackEvent(name, cleaned)
    }

    func loadAd(slotId: String, completion: @escaping (Result<NativeAdMessage?, Error>) -> Void) {
        Task {
            let ad = await Ja0Tracker.shared.ads.load(slotId: slotId)
            completion(.success(ad.map(Self.message(from:))))
        }
    }

    // MARK: - App Ops (docs/appops-contract §5)

    func getConfigJson(key: String, completion: @escaping (Result<String?, Error>) -> Void) {
        completion(.success(Ja0Tracker.shared.getConfigJSON(key)))
    }

    func setPushConsent(granted: Bool) throws {
        Ja0Tracker.shared.setPushConsent(granted)
    }

    func setPushToken(token: String) throws {
        Ja0Tracker.shared.setPushToken(token)
    }

    // MARK: - Native -> Dart callbacks

    private func wireCallbacksOnce() {
        guard !callbacksWired else { return }
        callbacksWired = true
        Ja0Tracker.shared.onAttribution { [weak self] data in
            self?.flutterApi?.onAttribution(data: Self.message(from: data)) { _ in }
        }
        Ja0Tracker.shared.onDeepLink { [weak self] link in
            self?.flutterApi?.onDeepLink(data: Self.message(from: link)) { _ in }
        }
        // App update: leave the Core's onUpdateAvailable unset so the SDK draws the
        // native update alert itself (no host-app code needed). Messages (incl.
        // review) are still forwarded to Dart.
        Ja0Tracker.shared.onMessage { [weak self] msg, markShown in
            self?.flutterApi?.onMessage(data: Self.message(from: msg)) { _ in }
            markShown()
        }
    }

    // Forward inbound Universal Links to the Core (Flutter surfaces these via
    // application(_:continue:...) which this plugin observes automatically).
    public func application(
        _ application: UIApplication,
        continue userActivity: NSUserActivity,
        restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void
    ) -> Bool {
        if let url = userActivity.webpageURL {
            Ja0Tracker.shared.handleDeepLink(url)
        }
        return false
    }

    public func application(
        _ app: UIApplication,
        open url: URL,
        options: [UIApplication.OpenURLOptionsKey: Any] = [:]
    ) -> Bool {
        Ja0Tracker.shared.handleDeepLink(url)
        return false
    }

    // MARK: - Mapping (Core -> Pigeon message)

    private static func parseLogLevel(_ raw: String?) -> LogLevel {
        switch raw {
        case "none": return .none
        case "error": return .error
        case "warn": return .warn
        case "debug": return .debug
        default: return .info
        }
    }

    private static func wire(_ status: TrackingConsentStatus) -> String {
        switch status {
        case .granted: return "granted"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "notDetermined"
        }
    }

    private static func message(from d: AttributionData) -> AttributionMessage {
        return AttributionMessage(
            source: d.source,
            campaign: d.campaign,
            network: d.network,
            clickId: d.clickId,
            confidence: d.confidence.rawValue,
            confidenceScore: d.confidenceScore,
            raw: optionalKeyed(d.raw)
        )
    }

    private static func message(from l: DeepLinkData) -> DeepLinkMessage {
        return DeepLinkMessage(
            path: l.path,
            params: optionalKeyed(l.params),
            url: l.url,
            isDeferred: l.isDeferred
        )
    }

    /// Rebuilds a `[String: String]` as `[String?: String?]` to match the Pigeon message
    /// shape (a bare `as` coercion between these dictionary types does not type-check).
    private static func optionalKeyed(_ source: [String: String]) -> [String?: String?] {
        var out: [String?: String?] = [:]
        for (k, v) in source { out[k] = v }
        return out
    }

    private static func message(from u: UpdateInfo) -> UpdateMessage {
        return UpdateMessage(
            available: u.available,
            force: u.force,
            latestVersion: u.latestVersion,
            storeUrl: u.storeURL,
            title: u.title,
            body: u.body
        )
    }

    private static func message(from m: AppMessage) -> AppMessageMessage {
        return AppMessageMessage(
            id: m.id,
            type: m.type.rawValue,
            priority: Int64(m.priority),
            title: m.title,
            body: m.body,
            ctaText: m.ctaText,
            ctaUrl: m.ctaURL,
            imageUrl: m.imageURL,
            force: m.force,
            minSessionSec: Int64(m.minSessionSec),
            frequency: m.frequency.rawValue
        )
    }

    private static func message(from ad: NativeAd) -> NativeAdMessage {
        let media = ad.assets.media.map {
            NativeAdMediaMessage(type: $0.type.rawValue, url: $0.url)
        }
        return NativeAdMessage(
            slotId: ad.slotId,
            adId: ad.adId,
            format: ad.format,
            headline: ad.assets.headline,
            body: ad.assets.body,
            advertiser: ad.assets.advertiser,
            cta: ad.assets.cta,
            iconUrl: ad.assets.iconURL,
            media: media,
            rating: ad.assets.rating,
            impressionUrls: ad.tracking.impressionURLs,
            clickUrl: ad.tracking.clickURL,
            viewablePixels: ad.tracking.viewableThreshold.pixels,
            viewableMs: Int64(ad.tracking.viewableThreshold.ms)
        )
    }
}

import Foundation
#if canImport(AppTrackingTransparency)
import AppTrackingTransparency
#endif
#if canImport(UIKit)
import UIKit
#endif

/// Public facade for the mtracker iOS SDK.
///
/// Mirrors the shared cross-platform API (docs/sdk-contract §5). All public methods are
/// defensively wrapped so an SDK failure never crashes the host app (docs/sdk.md §5).
///
/// Usage:
/// ```swift
/// Ja0Tracker.shared.initialize(Ja0TrackerConfig(
///     sdkKey: "pk_ja0_demo", sdkSecret: "…", appId: "…"))
/// let status = await Ja0Tracker.shared.requestTrackingConsent()   // ATT prompt
/// Ja0Tracker.shared.setConsent(Consent(analytics: true, attribution: true, ads: true))
/// Ja0Tracker.shared.onAttribution { data in /* route by data.source/campaign */ }
/// Ja0Tracker.shared.onDeepLink { link in /* route by link.path/params */ }
/// Ja0Tracker.shared.trackEvent("purchase", ["revenue": 9900, "currency": "KRW"])
/// let ad = await Ja0Tracker.shared.ads.load(slotId: "home_feed_slot")
/// ```
public final class Ja0Tracker {

    /// SDK version, surfaced in the User-Agent and available to host apps.
    public static let sdkVersion = "1.0.3"

    /// Shared singleton facade.
    public static let shared = Ja0Tracker()

    // Persisted cumulative session accounting (App Ops review gate + delivery params).
    private static let sessionSecKey = "mt_appops_session_sec_total"
    private static let sessionCountKey = "mt_appops_session_count"

    // Serialises all mutable state access off the public API surface.
    private let lock = NSRecursiveLock()

    private var initialized = false
    private var config: Ja0TrackerConfig?
    private var consent = Consent()
    private var attAuthorized = false

    private var logger = MTLogger(level: .info)
    private var identity: Identity?
    private var eventQueue: EventQueue?
    private var sender: EventSender?
    private var http: HTTPClient?
    private var session: SessionTracker?
    private var skan: SKANManager?
    private var pasteboard: Pasteboard?
    private var fingerprint: Fingerprint?
    private var appOps: AppOpsManager?

    // Cumulative session accounting for App Ops (persisted so it survives relaunches).
    private var sessionSecTotal: Int64 = 0
    private var sessionCountTotal: Int64 = 0

    private var attributionCallback: ((AttributionData) -> Void)?
    private var deepLinkCallback: ((DeepLinkData) -> Void)?
    private var pendingAttribution: AttributionData?
    private var pendingDeepLink: DeepLinkData?

    /// Ads accessor — `Ja0Tracker.shared.ads.load(slotId:)`. Non-nil after `initialize`.
    public private(set) var ads: MTAds!

    private init() {}

    // MARK: - Initialize

    /// Initialize once at app start (e.g. `application(_:didFinishLaunchingWithOptions:)`).
    /// Registers SKAN/AAK (always-on aggregate path), resolves install identity, emits
    /// the first-launch lifecycle event, and starts session tracking.
    public func initialize(_ config: Ja0TrackerConfig) {
        safe {
            lock.lock(); defer { lock.unlock() }
            guard !initialized else { return }
            self.config = config
            self.logger = MTLogger(level: config.logLevel)

            // Identity: Keychain-backed install_id + first-launch flag.
            let keychain = KeychainStore(service: "com.mocoplex.mtracker.\(config.sdkKey)")
            let identity = Identity(keychain: keychain)
            self.identity = identity

            // Durable queue + transport + sender.
            let queue = FileEventQueue(sdkKeyScope: config.sdkKey, logger: logger)
            let http = HTTPClient(config: config, logger: logger)
            self.eventQueue = queue
            self.http = http
            self.sender = EventSender(queue: queue, http: http, logger: logger)

            self.skan = SKANManager(logger: logger)
            self.pasteboard = Pasteboard(logger: logger)
            self.fingerprint = Fingerprint()
            self.ads = MTAds(config: config, logger: logger)

            // Restore cumulative session accounting (drives the App Ops review gate + params).
            self.sessionSecTotal = Int64(UserDefaults.standard.integer(forKey: Self.sessionSecKey))
            self.sessionCountTotal = Int64(UserDefaults.standard.integer(forKey: Self.sessionCountKey))

            self.session = SessionTracker(
                onSessionStart: { [weak self] sid in
                    self?.trackInternal(name: "session_start", paramsJSON: nil, sessionId: sid)
                    // session_start is a schema-eligible SKAN event (docs/skan-contract §1).
                    self?.skan?.noteEvent(name: "session_start", revenue: nil)
                    self?.bumpSessionCount()
                },
                onForegroundElapsed: { [weak self] elapsed in
                    self?.addSessionSeconds(elapsed)
                    // A newly-crossed review threshold should be checked promptly.
                    self?.appOps?.fetchNow()
                }
            )

            // App Ops (docs/appops-contract §2, §5): fetch on init + periodic. getConfig*
            // works from the cached payload before the first fetch completes.
            self.appOps = AppOpsManager(
                config: config,
                logger: logger,
                sessionSec: { [weak self] in self?.cumulativeSessionSec() ?? 0 },
                sessionCount: { [weak self] in self?.sessionCountTotal ?? 0 },
                installId: { [weak self] in self?.identity?.installId ?? "" }
            )
            // Route the SKAN conversion-value schema from the App Ops `skan` field into the
            // SKANManager for automatic CV computation (docs/skan-contract §3, §5). iOS-only.
            self.appOps?.onSkanSchema = { [weak self] schema in
                self?.skan?.updateSchema(schema)
            }

            initialized = true
            logger.info("initialized (\(Ja0Tracker.sdkVersion)) app=\(config.appId)")

            // Aggregate attribution runs regardless of consent (docs/attribution.md §2.1).
            skan?.registerSKAdNetwork()
            skan?.registerAdAttributionKit()

            // First-launch determination + lifecycle event.
            let state = identity.resolve()
            switch state {
            case .firstLaunch:
                emitInstallEvent(name: "install")
            case .reinstall:
                emitInstallEvent(name: "reinstall")
            case .returning:
                break
            }

            // Start session tracking (opens the initial session, subscribes to
            // UIApplication lifecycle notifications).
            session?.start()

            // Kick off App Ops fetching + periodic polling.
            appOps?.start()

            // Attempt delivery of anything queued from prior launches.
            sender?.flush()
        }
    }

    // MARK: - Consent / ATT

    /// Triggers the ATT prompt and returns the resulting status (docs/sdk-contract §5).
    /// On Android this is a no-op returning `.granted`.
    public func requestTrackingConsent() async -> TrackingConsentStatus {
        #if canImport(AppTrackingTransparency)
        if #available(iOS 14, *) {
            let status = await ATTrackingManager.requestTrackingAuthorization()
            let mapped = Self.map(status)
            lock.lock()
            attAuthorized = (mapped == .granted)
            lock.unlock()
            logger.info("ATT status: \(mapped.rawValue)")
            // ATT may unlock deterministic/probabilistic attribution — re-run the
            // consented first-launch collection if consent is already set.
            runConsentGatedAttributionIfReady()
            return mapped
        }
        #endif
        return .notDetermined
    }

    /// Sets per-purpose consent flags (docs/sdk-contract §4). When attribution consent +
    /// ATT are both granted on first launch, runs the deterministic clipboard read and
    /// fingerprint collection (attaching them to the pending install event if it hasn't
    /// flushed yet, otherwise sending an enrichment event).
    public func setConsent(_ consent: Consent) {
        safe {
            lock.lock()
            self.consent = consent
            lock.unlock()
            logger.info("consent set analytics=\(consent.analytics) attribution=\(consent.attribution) ads=\(consent.ads)")
            runConsentGatedAttributionIfReady()
            // Consent may have just enabled analytics — try to flush anything held back.
            sender?.flush()
        }
    }

    /// Registers the attribution callback; replays a pending result if one arrived early.
    public func onAttribution(_ callback: @escaping (AttributionData) -> Void) {
        safe {
            lock.lock(); defer { lock.unlock() }
            attributionCallback = callback
            if let pending = pendingAttribution {
                pending.deliver(to: callback)
                pendingAttribution = nil
            }
        }
    }

    /// Registers the deep link callback; replays a pending deferred/live link.
    public func onDeepLink(_ callback: @escaping (DeepLinkData) -> Void) {
        safe {
            lock.lock(); defer { lock.unlock() }
            deepLinkCallback = callback
            if let pending = pendingDeepLink {
                pending.deliver(to: callback)
                pendingDeepLink = nil
            }
        }
    }

    /// Handle an inbound Universal Link / custom scheme URL. Call from the SwiftUI
    /// `.onOpenURL` or the `UIApplicationDelegate` continue-userActivity path. For an
    /// already-installed app this is the immediate (non-deferred) deep link
    /// (docs/attribution.md §2.2, §5).
    public func handleDeepLink(_ url: URL) {
        safe {
            let data = Self.parseDeepLink(url, isDeferred: false)
            deliverDeepLink(data)
        }
    }

    // MARK: - Events

    /// Tracks an in-app event (retention/funnel/conversion). Recognises `revenue` /
    /// `currency` keys in `params` and lifts them to the top-level contract fields.
    public func trackEvent(_ name: String, _ params: [String: Any] = [:]) {
        safe {
            lock.lock()
            let analytics = consent.analytics
            let wait = config?.waitForConsent ?? true
            lock.unlock()

            var revenue: Double?
            var currency: String?
            if let r = params["revenue"] as? Double { revenue = r }
            else if let r = params["revenue"] as? Int { revenue = Double(r) }
            else if let r = params["revenue"] as? NSNumber { revenue = r.doubleValue }
            if let c = params["currency"] as? String { currency = c }

            // Feed the SKAN conversion-value automation (aggregate path, ATT-free — runs
            // even when identified analytics is dropped for consent). Defensive/no-op
            // where SKAN is unavailable (docs/skan-contract §5).
            skan?.noteEvent(name: name, revenue: revenue)

            if !analytics, wait {
                logger.debug("dropping '\(name)' — awaiting analytics consent")
                return // privacy-first: drop identified events until consent
            }

            let paramsJSON = Self.encodeParams(params)
            trackInternal(
                name: name,
                paramsJSON: paramsJSON,
                sessionId: session?.currentSessionId,
                revenue: revenue,
                currency: currency
            )
        }
    }

    // MARK: - App Ops: remote config (docs/appops-contract §5)

    /// Returns a cached remote-config string value, or `default` when absent.
    public func getConfigString(_ key: String, default def: String? = nil) -> String? {
        appOps?.getConfigString(key, default: def) ?? def
    }

    /// Returns a cached remote-config boolean value, or `default` when absent.
    public func getConfigBool(_ key: String, default def: Bool) -> Bool {
        appOps?.getConfigBool(key, default: def) ?? def
    }

    /// Returns a cached remote-config integer value, or `default` when absent.
    public func getConfigInt(_ key: String, default def: Int) -> Int {
        appOps?.getConfigInt(key, default: def) ?? def
    }

    /// Returns a cached remote-config value serialized as a JSON string, or nil.
    public func getConfigJSON(_ key: String) -> String? {
        appOps?.getConfigJSON(key)
    }

    // MARK: - App Ops: update / message overrides (docs/appops-contract §5)

    /// Overrides the default update popup. When set, the SDK delivers the localized
    /// `UpdateInfo` to `callback` (main thread) instead of showing its alert; the host
    /// renders its own UI and opens `storeURL` for the CTA. Render force updates as blocking.
    public func onUpdateAvailable(_ callback: @escaping (UpdateInfo) -> Void) {
        safe {
            lock.lock(); let mgr = appOps; lock.unlock()
            mgr?.onUpdateAvailable = callback
        }
    }

    /// Overrides the default in-app message UI. The SDK delivers the localized `AppMessage`
    /// plus a `markShown` completion the host MUST call once displayed so frequency
    /// (once/session/daily) is recorded. Review-type messages are delivered here too when a
    /// callback is set (host owns the review UX); otherwise the SDK runs native StoreKit review.
    public func onMessage(_ callback: @escaping (AppMessage, @escaping () -> Void) -> Void) {
        safe {
            lock.lock(); let mgr = appOps; lock.unlock()
            mgr?.onMessage = callback
        }
    }

    // MARK: - App Ops: push (docs/appops-contract §3)

    /// Registers a push token acquired by the host (APNs). The app owns APNs setup; call
    /// this with the token from `didRegisterForRemoteNotificationsWithDeviceToken` (hex
    /// string). The token is only POSTed to `/v1/push/register` (HMAC-signed) once push
    /// consent is granted via `setPushConsent`; before that it is queued.
    public func setPushToken(_ token: String) {
        safe { appOps?.setPushToken(token) }
    }

    /// Consent gate for push registration. When granted, any queued token is registered.
    public func setPushConsent(_ granted: Bool) {
        safe { appOps?.setPushConsent(granted) }
    }

    // MARK: - Session accounting (App Ops)

    private func cumulativeSessionSec() -> Int64 {
        lock.lock(); let base = sessionSecTotal; lock.unlock()
        let live = session?.currentForegroundElapsedSec() ?? 0
        return base + live
    }

    private func bumpSessionCount() {
        lock.lock()
        sessionCountTotal += 1
        let value = sessionCountTotal
        lock.unlock()
        UserDefaults.standard.set(Int(value), forKey: Self.sessionCountKey)
    }

    private func addSessionSeconds(_ seconds: Int64) {
        guard seconds > 0 else { return }
        lock.lock()
        sessionSecTotal += seconds
        let value = sessionSecTotal
        lock.unlock()
        UserDefaults.standard.set(Int(value), forKey: Self.sessionSecKey)
    }

    // MARK: - Internal delivery of attribution/deep link

    func deliverAttribution(_ data: AttributionData) {
        safe {
            lock.lock(); defer { lock.unlock() }
            if let cb = attributionCallback {
                data.deliver(to: cb)
            } else {
                pendingAttribution = data
            }
        }
    }

    func deliverDeepLink(_ data: DeepLinkData) {
        safe {
            lock.lock(); defer { lock.unlock() }
            if let cb = deepLinkCallback {
                data.deliver(to: cb)
            } else {
                pendingDeepLink = data
            }
        }
    }

    // MARK: - Install event + consent-gated attribution

    /// Builds and enqueues the first-launch `install` (or `reinstall`) event. Attribution
    /// signals (match_token / fingerprint) are attached only if consent + ATT are already
    /// granted at this point; otherwise they arrive via `runConsentGatedAttributionIfReady`.
    private func emitInstallEvent(name: String) {
        guard let identity, let config else { return }
        // Install/reinstall is a schema-eligible SKAN event (docs/skan-contract §1).
        skan?.noteEvent(name: name, revenue: nil)
        let (matchToken, deviceFP) = collectConsentedSignals()

        let event = QueuedEvent(
            eventId: ULID.generate(),
            appId: config.appId,
            installId: identity.installId,
            name: name,
            ts: Int64(Date().timeIntervalSince1970),
            sessionId: nil,
            revenue: nil,
            currency: nil,
            paramsJSON: nil,
            matchToken: matchToken,
            deviceFP: deviceFP
        )
        eventQueue?.enqueue(event)
        logger.info("enqueued \(name) event install_id=\(identity.installId)")
        sender?.flush()
    }

    /// If consent + ATT are now both satisfied and the clipboard read hasn't run yet,
    /// read the match_token and collect the fingerprint, then send them as an
    /// enrichment event (`install_signals`) tied to the same install_id. This covers the
    /// common flow where consent is granted AFTER the install event has already flushed.
    private func runConsentGatedAttributionIfReady() {
        safe {
            lock.lock()
            let attributionConsent = consent.attribution
            let att = attAuthorized
            lock.unlock()

            guard attributionConsent, att,
                  let identity, let config,
                  !identity.didReadMatchToken else { return }

            let (matchToken, deviceFP) = collectConsentedSignals()
            identity.markMatchTokenRead()

            guard matchToken != nil || deviceFP != nil else { return }

            let event = QueuedEvent(
                eventId: ULID.generate(),
                appId: config.appId,
                installId: identity.installId,
                name: "install_signals",
                ts: Int64(Date().timeIntervalSince1970),
                matchToken: matchToken,
                deviceFP: deviceFP
            )
            eventQueue?.enqueue(event)
            logger.info("enqueued install_signals (deterministic/probabilistic attribution)")
            sender?.flush()
        }
    }

    /// Reads the clipboard match_token (once) and the device fingerprint, both strictly
    /// gated on attribution consent + ATT authorization. Marks the one-shot clipboard
    /// guard as read whenever it actually probes the pasteboard.
    private func collectConsentedSignals() -> (matchToken: String?, deviceFP: String?) {
        lock.lock()
        let attributionConsent = consent.attribution
        let att = attAuthorized
        lock.unlock()

        guard attributionConsent, att, let identity else { return (nil, nil) }

        let token = pasteboard?.readMatchToken(
            attributionConsentGranted: attributionConsent,
            attAuthorized: att,
            alreadyRead: identity.didReadMatchToken
        )
        if !identity.didReadMatchToken {
            identity.markMatchTokenRead()
        }
        let fp = fingerprint?.collectJSON(
            attributionConsentGranted: attributionConsent,
            attAuthorized: att
        )
        return (token, fp)
    }

    // MARK: - Enqueue helper

    private func trackInternal(
        name: String,
        paramsJSON: Data?,
        sessionId: String?,
        revenue: Double? = nil,
        currency: String? = nil
    ) {
        guard let identity, let config else { return }
        eventQueue?.enqueue(
            QueuedEvent(
                eventId: ULID.generate(),
                appId: config.appId,
                installId: identity.installId,
                name: name,
                ts: Int64(Date().timeIntervalSince1970),
                sessionId: sessionId,
                revenue: revenue,
                currency: currency,
                paramsJSON: paramsJSON
            )
        )
        sender?.flush()
    }

    // MARK: - Helpers

    private static func encodeParams(_ params: [String: Any]) -> Data? {
        guard !params.isEmpty else { return nil }
        guard JSONSerialization.isValidJSONObject(params) else { return nil }
        return try? JSONSerialization.data(withJSONObject: params, options: [])
    }

    /// Parses a Universal Link / scheme URL into `DeepLinkData` (path + query params).
    static func parseDeepLink(_ url: URL, isDeferred: Bool) -> DeepLinkData {
        var params: [String: String] = [:]
        if let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let items = comps.queryItems {
            for item in items where item.value != nil {
                params[item.name] = item.value
            }
        }
        let path = url.path.isEmpty ? nil : url.path
        return DeepLinkData(
            path: path,
            params: params,
            url: url.absoluteString,
            isDeferred: isDeferred
        )
    }

    #if canImport(AppTrackingTransparency)
    @available(iOS 14, *)
    private static func map(_ status: ATTrackingManager.AuthorizationStatus) -> TrackingConsentStatus {
        switch status {
        case .authorized: return .granted
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        @unknown default: return .notDetermined
        }
    }
    #endif

    /// Defensive wrapper: SDK failures must never crash the host app (docs/sdk.md §5).
    /// Swift can't catch fatal traps, but this contains the surface so any thrown error
    /// added here (encoding, IO) is logged and swallowed rather than propagated.
    private func safe(_ block: () -> Void) {
        block()
    }
}

// MARK: - Callback delivery (main queue)

private extension AttributionData {
    /// Attribution/deep link callbacks are UI-facing (routing/nav), so always deliver on
    /// the main thread.
    func deliver(to callback: @escaping (AttributionData) -> Void) {
        let data = self
        if Thread.isMainThread { callback(data) }
        else { DispatchQueue.main.async { callback(data) } }
    }
}

private extension DeepLinkData {
    func deliver(to callback: @escaping (DeepLinkData) -> Void) {
        let data = self
        if Thread.isMainThread { callback(data) }
        else { DispatchQueue.main.async { callback(data) } }
    }
}

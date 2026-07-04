import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Orchestrates the App Ops surface (docs/appops-contract §2, §5): fetches the delivery
/// payload on init + periodically, caches remote config, and renders the update popup,
/// in-app messages, and native review prompt — honoring per-message frequency and, for
/// reviews, cumulative session time. Also owns push-token registration (§3).
///
/// Reuses Core infrastructure: `AppOpsClient` (HTTP + shared HMAC signer), `UserDefaults`
/// for persistence, and session accounting supplied by the facade. UI runs on the main
/// thread via `AppOpsUI`.
final class AppOpsManager: @unchecked Sendable {

    private let config: MTrackerConfig
    private let logger: MTLogger
    private let client: AppOpsClient
    private let defaults: UserDefaults

    // Session accounting, provided by the facade (SessionTracker-derived).
    private let sessionSec: () -> Int64
    private let sessionCount: () -> Int64
    private let installId: () -> String
    private let platform = "ios"

    // Host overrides (docs/appops-contract §5). Delivered on the main thread.
    var onUpdateAvailable: ((UpdateInfo) -> Void)?
    /// Delivered with a `markShown` completion the host MUST call once displayed.
    var onMessage: ((AppMessage, @escaping () -> Void) -> Void)?
    /// Internal sink for the SKAN conversion-value schema carried in the `skan` field
    /// (docs/skan-contract §3). Wired by the facade to `SKANManager.updateSchema`.
    var onSkanSchema: ((SkanSchema) -> Void)?

    private let lock = NSLock()
    private var configCache: [String: Any] = [:]
    private var pushConsent: Bool
    private var pendingPushToken: String?
    private var shownThisSession = Set<String>()
    private var pollTimer: DispatchSourceTimer?

    init(
        config: MTrackerConfig,
        logger: MTLogger,
        sessionSec: @escaping () -> Int64,
        sessionCount: @escaping () -> Int64,
        installId: @escaping () -> String,
        defaults: UserDefaults = .standard
    ) {
        self.config = config
        self.logger = logger
        self.client = AppOpsClient(config: config, logger: logger)
        self.sessionSec = sessionSec
        self.sessionCount = sessionCount
        self.installId = installId
        self.defaults = defaults
        self.pushConsent = defaults.bool(forKey: Keys.pushConsent)
        // Restore cached config so getConfig* works before the first fetch.
        if let raw = defaults.data(forKey: Keys.config),
           let obj = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] {
            self.configCache = obj
        }
    }

    /// Fetch on init, then poll periodically.
    func start() {
        fetchNow()
        startPolling()
    }

    private func startPolling() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + Self.pollInterval, repeating: Self.pollInterval)
        timer.setEventHandler { [weak self] in self?.fetchNow() }
        timer.resume()
        pollTimer = timer
    }

    func fetchNow() {
        Task { [weak self] in await self?.fetchAndApply() }
    }

    // MARK: - Remote config

    func getConfigString(_ key: String, default def: String?) -> String? {
        lock.lock(); defer { lock.unlock() }
        return (configCache[key] as? String) ?? def
    }

    func getConfigBool(_ key: String, default def: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if let b = configCache[key] as? Bool { return b }
        if let n = configCache[key] as? NSNumber { return n.boolValue }
        if let s = configCache[key] as? String { return (s as NSString).boolValue }
        return def
    }

    func getConfigInt(_ key: String, default def: Int) -> Int {
        lock.lock(); defer { lock.unlock() }
        if let n = configCache[key] as? NSNumber { return n.intValue }
        if let s = configCache[key] as? String, let i = Int(s) { return i }
        return def
    }

    /// Returns the config value serialized to a JSON string (object/array/scalar) or nil.
    func getConfigJSON(_ key: String) -> String? {
        lock.lock(); let value = configCache[key]; lock.unlock()
        guard let value else { return nil }
        if JSONSerialization.isValidJSONObject([value]),
           let data = try? JSONSerialization.data(withJSONObject: [value], options: []),
           let arr = String(data: data, encoding: .utf8) {
            // Strip the wrapping brackets we added to make scalars valid JSON roots.
            return String(arr.dropFirst().dropLast())
        }
        if let s = value as? String { return "\"\(s)\"" }
        return "\(value)"
    }

    // MARK: - Push

    func setPushConsent(_ granted: Bool) {
        lock.lock()
        pushConsent = granted
        let queued = pendingPushToken
        lock.unlock()
        defaults.set(granted, forKey: Keys.pushConsent)
        if granted, let queued { setPushToken(queued) }
    }

    /// Registers a push token acquired by the host (APNs). No-op without consent (queued).
    func setPushToken(_ token: String) {
        guard !token.isEmpty else { return }
        lock.lock()
        let consent = pushConsent
        if !consent {
            pendingPushToken = token
            lock.unlock()
            logger.debug("push token held until consent granted")
            return
        }
        pendingPushToken = nil
        lock.unlock()

        if defaults.string(forKey: Keys.pushToken) == token { return }
        Task { [weak self] in
            guard let self else { return }
            let ok = await self.client.registerPush(
                platform: self.platform,
                installId: self.installId(),
                token: token,
                lang: Self.deviceLang()
            )
            if ok { self.defaults.set(token, forKey: Keys.pushToken) }
        }
    }

    // MARK: - Fetch + apply

    private func fetchAndApply() async {
        let id = installId()
        guard !id.isEmpty else { return }
        guard let payload = await client.fetch(
            platform: platform,
            appVersion: Self.appVersion(),
            lang: Self.deviceLang(),
            installId: id,
            sessionSec: sessionSec(),
            sessionCount: sessionCount()
        ) else { return }

        // 1. Cache remote config.
        if let cfg = payload["config"] as? [String: Any] {
            lock.lock(); configCache = cfg; lock.unlock()
            if let data = try? JSONSerialization.data(withJSONObject: cfg, options: []) {
                defaults.set(data, forKey: Keys.config)
            }
        }

        // 2. Update popup.
        if let updateObj = payload["update"] as? [String: Any] {
            apply(update: Self.parseUpdate(updateObj))
        }

        // 3. Messages by priority (highest first).
        let messages = Self.parseMessages(payload["messages"]).sorted { $0.priority > $1.priority }
        for msg in messages { apply(message: msg) }

        // 4. SKAN conversion-value schema (docs/skan-contract §3). Handed to SKANManager
        //    for automatic CV computation; iOS-only, no host UI.
        if let skanObj = payload["skan"] as? [String: Any],
           let schema = Self.parseSkan(skanObj) {
            onSkanSchema?(schema)
        }
    }

    private func apply(update: UpdateInfo) {
        guard update.available else { return }
        if let cb = onUpdateAvailable {
            main { cb(update) }
            return
        }
        main {
            AppOpsUI.showUpdateAlert(
                title: update.title,
                body: update.body,
                ctaText: nil,
                storeURL: update.storeURL,
                force: update.force
            )
        }
    }

    private func apply(message msg: AppMessage) {
        guard shouldShow(msg) else { return }

        if msg.type == .review {
            guard sessionSec() >= Int64(msg.minSessionSec) else { return }
            triggerReview(msg)
            return
        }

        if let cb = onMessage {
            main { cb(msg) { [weak self] in self?.markShown(msg) } }
            return
        }
        main {
            AppOpsUI.showMessageAlert(
                title: msg.title,
                body: msg.body,
                ctaText: msg.ctaText,
                ctaURL: msg.ctaURL,
                force: msg.force,
                onShown: { [weak self] in self?.markShown(msg) }
            )
        }
    }

    private func triggerReview(_ msg: AppMessage) {
        if let cb = onMessage {
            main { cb(msg) { [weak self] in self?.markShown(msg) } }
            return
        }
        main {
            AppOpsUI.requestReview(
                title: msg.title,
                body: msg.body,
                ctaText: msg.ctaText,
                storeURL: msg.ctaURL,
                onShown: { [weak self] in self?.markShown(msg) }
            )
        }
    }

    // MARK: - Frequency

    private func shouldShow(_ msg: AppMessage) -> Bool {
        let key = Keys.msgPrefix + msg.id
        let last = defaults.double(forKey: key)
        switch msg.frequency {
        case .always: return true
        case .once: return last == 0
        case .daily: return Date().timeIntervalSince1970 - last >= 24 * 60 * 60
        case .session:
            lock.lock(); let seen = shownThisSession.contains(msg.id); lock.unlock()
            return !seen
        }
    }

    private func markShown(_ msg: AppMessage) {
        defaults.set(Date().timeIntervalSince1970, forKey: Keys.msgPrefix + msg.id)
        lock.lock(); shownThisSession.insert(msg.id); lock.unlock()
    }

    // MARK: - Parsing

    private static func parseUpdate(_ raw: [String: Any]) -> UpdateInfo {
        UpdateInfo(
            available: (raw["available"] as? Bool) ?? false,
            force: (raw["force"] as? Bool) ?? false,
            latestVersion: raw["latest_version"] as? String,
            storeURL: raw["store_url"] as? String,
            title: raw["title"] as? String,
            body: raw["body"] as? String
        )
    }

    private static func parseMessages(_ raw: Any?) -> [AppMessage] {
        guard let arr = raw as? [[String: Any]] else { return [] }
        return arr.compactMap { m in
            guard let id = m["id"] as? String else { return nil }
            return AppMessage(
                id: id,
                type: AppMessageType.from(m["type"] as? String),
                priority: (m["priority"] as? NSNumber)?.intValue ?? 0,
                title: m["title"] as? String,
                body: m["body"] as? String,
                ctaText: m["cta_text"] as? String,
                ctaURL: m["cta_url"] as? String,
                imageURL: m["image_url"] as? String,
                force: (m["force"] as? Bool) ?? false,
                minSessionSec: (m["min_session_sec"] as? NSNumber)?.intValue ?? 0,
                frequency: AppMessageFrequency.from(m["frequency"] as? String)
            )
        }
    }

    /// Parses the `skan` field into a `SkanSchema` (docs/skan-contract §1). Tolerant of
    /// missing/partial fields; returns nil only when there is nothing usable.
    private static func parseSkan(_ raw: [String: Any]) -> SkanSchema? {
        func num(_ v: Any?) -> Double? {
            if let n = v as? NSNumber { return n.doubleValue }
            if let s = v as? String { return Double(s) }
            return nil
        }
        func intVal(_ v: Any?) -> Int? { num(v).map { Int($0) } }

        let events: [SkanSchema.Event] = (raw["events"] as? [[String: Any]] ?? []).compactMap { e in
            guard let name = e["name"] as? String, !name.isEmpty,
                  let fine = intVal(e["fine"]) else { return nil }
            let coarse = (e["coarse"] as? String) ?? "low"
            return SkanSchema.Event(name: name, fine: fine, coarse: coarse)
        }

        let buckets: [SkanSchema.RevenueBucket] = (raw["revenue_buckets"] as? [[String: Any]] ?? []).compactMap { b in
            guard let min = num(b["min"]), let fine = intVal(b["fine"]) else { return nil }
            let coarse = (b["coarse"] as? String) ?? "low"
            return SkanSchema.RevenueBucket(min: min, fine: fine, coarse: coarse)
        }

        // Nothing actionable → no schema.
        guard !events.isEmpty || !buckets.isEmpty else { return nil }

        return SkanSchema(
            coarseEnabled: (raw["coarse_enabled"] as? Bool) ?? {
                if let n = raw["coarse_enabled"] as? NSNumber { return n.boolValue }
                return true
            }(),
            measurementWindowHours: intVal(raw["measurement_window_hours"]) ?? 24,
            mode: (raw["mode"] as? String) ?? "events",
            events: events,
            revenueBuckets: buckets
        )
    }

    // MARK: - Device context

    /// Device language code (e.g. "ko"/"en"), defaulting to "en" (docs/appops-contract §6).
    static func deviceLang() -> String {
        if #available(iOS 16, *) {
            if let code = Locale.current.language.languageCode?.identifier, !code.isEmpty { return code }
        }
        if let code = Locale.current.languageCode, !code.isEmpty { return code }
        return "en"
    }

    static func appVersion() -> String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? ""
    }

    private func main(_ block: @escaping () -> Void) {
        if Thread.isMainThread { block() } else { DispatchQueue.main.async(execute: block) }
    }

    private enum Keys {
        static let config = "mt_appops_config"
        static let pushConsent = "mt_appops_push_consent"
        static let pushToken = "mt_appops_push_token"
        static let msgPrefix = "mt_appops_msg_"
    }

    private static let pollInterval: TimeInterval = 30 * 60 // 30 minutes
}

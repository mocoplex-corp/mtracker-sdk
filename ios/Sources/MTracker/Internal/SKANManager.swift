import Foundation
#if canImport(StoreKit)
import StoreKit
#endif
#if canImport(AdAttributionKit)
import AdAttributionKit
#endif

/// SKAdNetwork + AdAttributionKit registration and **conversion-value automation** — the
/// **aggregate** attribution layer (docs/attribution.md §2.1, docs/skan-contract §5).
///
///  attribution.md §2.4 priority ladder (aggregate rung):
///    "신규 설치 → … → SKAN/AAK(집계, 항상)"
///
/// This layer is the DEFAULT, ALWAYS-ON path: it needs NO ATT authorization and is
/// App Store review-safe (attribution.md §2.1: "ATT 불필요 → 심사 안전"). SKAN and AAK
/// coexist — both are registered and reconciled in reports on the backend
/// (attribution.md §2.1: "SKAN과 공존 — 둘 다 등록하고 리포트에서 합산").
///
/// SKAN 4 provides hierarchical conversion values (coarse/fine), multiple postback
/// windows (0–2d / 3–7d / 8–35d) and `lockWindow`. The conversion-value **schema** (which
/// post-install events / revenue thresholds encode into which fine/coarse value) is
/// delivered remotely via the App Ops `skan` field (docs/skan-contract §1, §3). This
/// manager caches that schema and, on each tracked event / revenue, recomputes the target
/// fine/coarse and posts an update ONLY when the value increases within the measurement
/// window (docs/skan-contract §5).
///
/// All SKAN calls are guarded by `#available` and swallow errors so the host never crashes.
final class SKANManager: @unchecked Sendable {

    private let logger: MTLogger
    private let defaults: UserDefaults
    private let lock = NSLock()

    // Cached remote schema (nil until the first App Ops fetch delivers `skan`).
    private var schema: SkanSchema?

    // Persisted state (docs/skan-contract §5):
    //   - current fine (0–63) already posted to StoreKit
    //   - current coarse tier string that accompanied it
    //   - measurement-window start (install/first-launch time, epoch seconds)
    //   - set of event names seen so far in the window (drives events-mode max)
    //   - cumulative revenue seen so far in the window
    //   - whether we've already locked the window
    private var currentFine: Int
    private var currentCoarse: String
    private var windowStart: TimeInterval
    private var seenEvents: Set<String>
    private var cumulativeRevenue: Double
    private var windowLocked: Bool

    init(logger: MTLogger, defaults: UserDefaults = .standard) {
        self.logger = logger
        self.defaults = defaults
        // -1 means "nothing posted yet" so an initial fine of 0 still counts as an increase.
        self.currentFine = defaults.object(forKey: Keys.fine) as? Int ?? -1
        self.currentCoarse = defaults.string(forKey: Keys.coarse) ?? "low"
        let ws = defaults.double(forKey: Keys.windowStart)
        self.windowStart = ws > 0 ? ws : 0
        self.seenEvents = Set(defaults.stringArray(forKey: Keys.seenEvents) ?? [])
        self.cumulativeRevenue = defaults.double(forKey: Keys.revenue)
        self.windowLocked = defaults.bool(forKey: Keys.windowLocked)
    }

    // MARK: - Schema (delivered via App Ops `skan`)

    /// Installs/updates the remote conversion-value schema (docs/skan-contract §3). Called
    /// by AppOpsManager whenever the `/v1/appops` payload carries a `skan` field. Recomputes
    /// once so a value can be posted from already-observed events/revenue.
    func updateSchema(_ schema: SkanSchema) {
        lock.lock()
        self.schema = schema
        lock.unlock()
        logger.debug("SKAN schema updated (mode=\(schema.mode), events=\(schema.events.count), buckets=\(schema.revenueBuckets.count))")
        recomputeAndPost()
    }

    // MARK: - Registration

    /// Registers the app for SKAdNetwork attribution and posts the initial conversion
    /// value. Call once at init, before any conversion. Uses the SKAN 4 API when available
    /// and falls back through SKAN 3 / SKAN 2 for older OSes. Also seeds the measurement
    /// window start (docs/skan-contract §5) on first launch.
    func registerSKAdNetwork() {
        // Seed the measurement-window start on the very first launch.
        lock.lock()
        if windowStart <= 0 {
            windowStart = Date().timeIntervalSince1970
            defaults.set(windowStart, forKey: Keys.windowStart)
        }
        lock.unlock()

        #if canImport(StoreKit) && !targetEnvironment(macCatalyst)
        // SKAN 4 (iOS 16.1+): coarse + fine value, lockWindow, completion handler.
        if #available(iOS 16.1, *) {
            SKAdNetwork.updatePostbackConversionValue(0, coarseValue: .low, lockWindow: false) { [weak self] error in
                if let error = error {
                    self?.logger.warn("SKAN4 initial postback failed: \(error.localizedDescription)")
                } else {
                    self?.logger.debug("SKAN4 registered (initial conversion value 0)")
                }
            }
            markPosted(fine: 0, coarse: "low")
            return
        }
        // SKAN 3 (iOS 15.4+): fine value only, with completion handler.
        if #available(iOS 15.4, *) {
            SKAdNetwork.updatePostbackConversionValue(0) { [weak self] error in
                if let error = error {
                    self?.logger.warn("SKAN3 initial postback failed: \(error.localizedDescription)")
                }
            }
            markPosted(fine: 0, coarse: "low")
            return
        }
        // SKAN 2 (iOS 14+): register + set value separately (deprecated but supported).
        if #available(iOS 14.0, *) {
            SKAdNetwork.registerAppForAdNetworkAttribution()
            SKAdNetwork.updateConversionValue(0)
            markPosted(fine: 0, coarse: "low")
            return
        }
        #endif
        logger.debug("SKAdNetwork unavailable on this platform/OS")
    }

    // MARK: - Event / revenue hooks (docs/skan-contract §5)

    /// Notifies the manager that a named event occurred (with optional revenue). Records the
    /// event / accumulates revenue, then recomputes the target fine/coarse from the schema
    /// and posts an update if it increased within the window. Fully defensive.
    func noteEvent(name: String, revenue: Double?) {
        guard !name.isEmpty else { return }
        lock.lock()
        let insertedEvent = seenEvents.insert(name).inserted
        if insertedEvent {
            defaults.set(Array(seenEvents), forKey: Keys.seenEvents)
        }
        var revenueChanged = false
        if let revenue = revenue, revenue > 0 {
            cumulativeRevenue += revenue
            defaults.set(cumulativeRevenue, forKey: Keys.revenue)
            revenueChanged = true
        }
        lock.unlock()

        guard insertedEvent || revenueChanged else { return }
        recomputeAndPost()
    }

    // MARK: - CV computation + posting

    /// Recomputes the target (fine, coarse) from the cached schema against observed events /
    /// cumulative revenue and posts an update when it is HIGHER than what was last posted,
    /// provided we are still inside the measurement window (docs/skan-contract §5).
    private func recomputeAndPost() {
        lock.lock()
        guard let schema = schema else { lock.unlock(); return }
        let seen = seenEvents
        let revenue = cumulativeRevenue
        let inWindow = isInWindowLocked(schema: schema)
        let priorFine = currentFine
        lock.unlock()

        guard inWindow else {
            // Window elapsed — optionally lock once so the postback finalizes early.
            lockWindowIfNeeded(schema: schema)
            return
        }

        guard let target = Self.computeTarget(schema: schema, seenEvents: seen, cumulativeRevenue: revenue) else {
            return
        }

        // Post only on a strict increase (docs/skan-contract §1: "값이 커질 때만").
        guard target.fine > priorFine else { return }

        post(fine: target.fine, coarse: schema.coarseEnabled ? target.coarse : "low", lockWindow: false)
        markPosted(fine: target.fine, coarse: target.coarse)
    }

    /// Pure computation of the winning (fine, coarse):
    ///   - events: fine = max fine among triggered event names; coarse = that event's tier.
    ///   - revenue: highest bucket whose `min` ≤ cumulative revenue → its fine/coarse.
    ///   - both are evaluated and the higher fine wins (docs/skan-contract §1, §5).
    /// Returns nil when neither mapping yields a value.
    static func computeTarget(
        schema: SkanSchema,
        seenEvents: Set<String>,
        cumulativeRevenue: Double
    ) -> (fine: Int, coarse: String)? {
        var best: (fine: Int, coarse: String)?

        // Events mapping: max fine among triggered events, coarse of the winning event.
        for event in schema.events where seenEvents.contains(event.name) {
            let fine = clampFine(event.fine)
            if best == nil || fine > best!.fine {
                best = (fine, event.coarse)
            }
        }

        // Revenue mapping: highest bucket whose min ≤ cumulative revenue.
        if cumulativeRevenue > 0 || !schema.revenueBuckets.isEmpty {
            var bucketBest: (fine: Int, coarse: String)?
            var bucketMin = -Double.greatestFiniteMagnitude
            for bucket in schema.revenueBuckets where bucket.min <= cumulativeRevenue {
                if bucket.min >= bucketMin {
                    bucketMin = bucket.min
                    bucketBest = (clampFine(bucket.fine), bucket.coarse)
                }
            }
            if let bucketBest = bucketBest {
                // Take the max fine across events + revenue (docs/skan-contract §1).
                if best == nil || bucketBest.fine > best!.fine {
                    best = bucketBest
                }
            }
        }

        return best
    }

    /// Posts the conversion value across SKAN version fallbacks (docs/skan-contract §5).
    ///   - SKAN 4 (iOS 16.1+): `updatePostbackConversionValue(_:coarseValue:lockWindow:)`
    ///   - SKAN 3 (iOS 15.4+): `updatePostbackConversionValue(_:completionHandler:)` (fine)
    ///   - SKAN 2 (iOS 14+):   `updateConversionValue(_:)` (fine)
    private func post(fine fineValue: Int, coarse: String, lockWindow: Bool) {
        #if canImport(StoreKit) && !targetEnvironment(macCatalyst)
        let fine = Self.clampFine(fineValue)
        if #available(iOS 16.1, *) {
            let coarseValue = Self.coarse(coarse)
            SKAdNetwork.updatePostbackConversionValue(fine, coarseValue: coarseValue, lockWindow: lockWindow) { [weak self] error in
                if let error = error {
                    self?.logger.warn("SKAN4 conversion update failed: \(error.localizedDescription)")
                } else {
                    self?.logger.debug("SKAN4 conversion value updated fine=\(fine) coarse=\(coarse) lock=\(lockWindow)")
                }
            }
            return
        }
        if #available(iOS 15.4, *) {
            SKAdNetwork.updatePostbackConversionValue(fine) { [weak self] error in
                if let error = error {
                    self?.logger.warn("SKAN3 conversion update failed: \(error.localizedDescription)")
                }
            }
            return
        }
        if #available(iOS 14.0, *) {
            SKAdNetwork.updateConversionValue(fine)
        }
        #endif
    }

    /// Kept for API compatibility with any host/manual driver: updates the SKAN conversion
    /// value directly, honoring the same version fallbacks. The automated path uses
    /// `noteEvent` / the schema instead.
    func updateConversionValue(fineValue: Int, coarse: String, lockWindow: Bool) {
        post(fine: fineValue, coarse: coarse, lockWindow: lockWindow)
        markPosted(fine: Self.clampFine(fineValue), coarse: coarse)
    }

    // MARK: - Window management

    /// True while still inside the measurement window. Caller holds `lock`.
    private func isInWindowLocked(schema: SkanSchema) -> Bool {
        guard schema.measurementWindowHours > 0, windowStart > 0 else {
            // No window configured yet → treat as open so values can be posted.
            return true
        }
        let elapsedHours = (Date().timeIntervalSince1970 - windowStart) / 3600.0
        return elapsedHours <= Double(schema.measurementWindowHours)
    }

    /// When the measurement window has elapsed, post the final value once with
    /// `lockWindow: true` to finalize the postback early (docs/skan-contract §5).
    private func lockWindowIfNeeded(schema: SkanSchema) {
        lock.lock()
        if windowLocked {
            lock.unlock()
            return
        }
        // Only lock a window that was actually configured and has genuinely elapsed.
        guard schema.measurementWindowHours > 0, windowStart > 0 else {
            lock.unlock()
            return
        }
        let elapsedHours = (Date().timeIntervalSince1970 - windowStart) / 3600.0
        guard elapsedHours > Double(schema.measurementWindowHours) else {
            lock.unlock()
            return
        }
        windowLocked = true
        defaults.set(true, forKey: Keys.windowLocked)
        let fine = max(0, currentFine)
        let coarse = currentCoarse
        lock.unlock()

        post(fine: fine, coarse: schema.coarseEnabled ? coarse : "low", lockWindow: true)
        logger.debug("SKAN measurement window elapsed — locked at fine=\(fine)")
    }

    // MARK: - Persisted "current value"

    private func markPosted(fine: Int, coarse: String) {
        lock.lock()
        // Never regress the stored high-water mark.
        if fine > currentFine {
            currentFine = fine
            currentCoarse = coarse
            defaults.set(fine, forKey: Keys.fine)
            defaults.set(coarse, forKey: Keys.coarse)
        }
        lock.unlock()
    }

    private static func clampFine(_ v: Int) -> Int { max(0, min(63, v)) }

    #if canImport(StoreKit)
    @available(iOS 16.1, *)
    private static func coarse(_ s: String) -> SKAdNetwork.CoarseConversionValue {
        switch s.lowercased() {
        case "high": return .high
        case "medium": return .medium
        default: return .low
        }
    }
    #endif

    private enum Keys {
        static let fine = "mt_skan_fine"
        static let coarse = "mt_skan_coarse"
        static let windowStart = "mt_skan_window_start"
        static let seenEvents = "mt_skan_seen_events"
        static let revenue = "mt_skan_revenue"
        static let windowLocked = "mt_skan_window_locked"
    }

    // MARK: - AdAttributionKit (coexists with SKAN)

    /// Registers AdAttributionKit impressions/attribution (iOS 17.4+ for developer-mode
    /// / re-engagement primitives; full parity on iOS 18.4+). Coexists with SKAN — both
    /// register and the backend sums them in reports (attribution.md §2.1).
    ///
    /// AAK adds re-engagement, custom attribution windows, third-party stores, and
    /// conversion-tag-based re-engagement windows (attribution.md §2.1). For an install
    /// SDK the relevant call is updating the AAK conversion value on post-install events;
    /// impression registration happens on the ad-serving side (MTNativeAdView / adserver).
    func registerAdAttributionKit() {
        #if canImport(AdAttributionKit)
        if #available(iOS 17.4, *) {
            // AAK conversion updates mirror SKAN: post the initial (0) value so the
            // attribution window opens. Guarded so it is a no-op where AAK is absent.
            Task { [weak self] in
                do {
                    try await Postback.updateConversionValue(0, lockPostback: false)
                    self?.logger.debug("AdAttributionKit registered (initial conversion value 0)")
                } catch {
                    self?.logger.warn("AdAttributionKit registration failed: \(error.localizedDescription)")
                }
            }
            return
        }
        #endif
        logger.debug("AdAttributionKit unavailable (requires iOS 17.4+)")
    }

    /// Updates the AdAttributionKit conversion value alongside SKAN (attribution.md §2.1).
    func updateAAKConversionValue(_ value: Int, lockPostback: Bool) {
        #if canImport(AdAttributionKit)
        if #available(iOS 17.4, *) {
            Task { [weak self] in
                do {
                    try await Postback.updateConversionValue(value, lockPostback: lockPostback)
                } catch {
                    self?.logger.warn("AAK conversion update failed: \(error.localizedDescription)")
                }
            }
        }
        #endif
    }
}

import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Foreground/background session boundaries (docs/sdk-contract §4, docs/sdk.md §3.3).
///
/// Subscribes to `UIApplication` lifecycle notifications itself so the host app never
/// has to forward them. Each foreground entry that follows a background gap longer than
/// `sessionTimeout` opens a NEW session and fires `session_start` (carrying the session
/// id; the install_id is attached by the caller). A short background excursion
/// (< threshold) resumes the same session and emits nothing — matching the backend's
/// retention roll-up expectation ("짧은 백그라운드(<N초)는 동일 세션").
final class SessionTracker {

    private let sessionTimeout: TimeInterval
    private let onSessionStart: (String) -> Void
    private let onForegroundElapsed: (Int64) -> Void

    private(set) var currentSessionId: String?
    private var lastBackgroundedAt: Date?
    private var observersInstalled = false
    /// Wall-clock time at which the current foreground stint began (for elapsed accounting).
    private var foregroundStartedAt: Date?

    init(
        sessionTimeout: TimeInterval = 30,
        onSessionStart: @escaping (String) -> Void = { _ in },
        /// Reports elapsed foreground seconds on each background transition, so the App Ops
        /// layer can gate the review prompt on cumulative session time (docs/appops §5).
        onForegroundElapsed: @escaping (Int64) -> Void = { _ in }
    ) {
        self.sessionTimeout = sessionTimeout
        self.onSessionStart = onSessionStart
        self.onForegroundElapsed = onForegroundElapsed
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// Begins observing app lifecycle and opens the initial session synchronously
    /// (the app is foreground at init time). Idempotent.
    func start() {
        #if canImport(UIKit)
        guard !observersInstalled else { return }
        observersInstalled = true

        let nc = NotificationCenter.default
        nc.addObserver(self,
                       selector: #selector(handleForeground),
                       name: UIApplication.didBecomeActiveNotification,
                       object: nil)
        nc.addObserver(self,
                       selector: #selector(handleBackground),
                       name: UIApplication.didEnterBackgroundNotification,
                       object: nil)
        #endif
        // Open the first session immediately.
        onForeground()
    }

    #if canImport(UIKit)
    @objc private func handleForeground() { onForeground() }
    @objc private func handleBackground() { onBackground() }
    #endif

    /// Foreground transition. Opens a new session if none is active or the background
    /// gap exceeded the timeout; otherwise resumes the current one.
    func onForeground(now: Date = Date()) {
        foregroundStartedAt = now
        if currentSessionId != nil,
           let bg = lastBackgroundedAt,
           now.timeIntervalSince(bg) < sessionTimeout {
            lastBackgroundedAt = nil
            return // same session resumed — no event
        }
        let id = ULID.generate(now: now)
        currentSessionId = id
        lastBackgroundedAt = nil
        onSessionStart(id)
    }

    /// Background transition. Records the time so a quick return keeps the session, and
    /// reports the just-completed foreground stint's duration.
    func onBackground(now: Date = Date()) {
        lastBackgroundedAt = now
        if let start = foregroundStartedAt, now > start {
            onForegroundElapsed(Int64(now.timeIntervalSince(start)))
        }
        foregroundStartedAt = nil
    }

    /// Foreground seconds elapsed in the CURRENT (still-open) stint, or 0 when backgrounded.
    func currentForegroundElapsedSec(now: Date = Date()) -> Int64 {
        guard let start = foregroundStartedAt, now > start else { return 0 }
        return Int64(now.timeIntervalSince(start))
    }
}

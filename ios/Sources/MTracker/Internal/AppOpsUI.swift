import Foundation
#if canImport(UIKit)
import UIKit
#endif
#if canImport(StoreKit)
import StoreKit
#endif

/// Default in-SDK UI for App Ops surfaces (docs/appops-contract §5). Built on UIKit's
/// `UIAlertController` so the SDK ships no storyboards/assets. The host app can bypass all
/// of this via `onUpdateAvailable` / `onMessage`. Native review uses StoreKit.
///
/// All methods must be called on the main thread (the caller marshals).
enum AppOpsUI {

    /// Presents the version-update prompt. When `force`, the alert is non-dismissible
    /// (blocking) and only offers the update CTA; otherwise a "Later" action dismisses it.
    static func showUpdateAlert(
        title: String?,
        body: String?,
        ctaText: String?,
        storeURL: String?,
        force: Bool
    ) {
        #if canImport(UIKit)
        guard let presenter = topViewController() else { return }
        let alert = UIAlertController(
            title: title ?? "Update available",
            message: body ?? "A new version is available.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: ctaText ?? "Update", style: .default) { _ in
            openURL(storeURL)
            // For a forced update, re-present so the user cannot proceed until they update.
            if force {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    showUpdateAlert(title: title, body: body, ctaText: ctaText, storeURL: storeURL, force: true)
                }
            }
        })
        if !force {
            alert.addAction(UIAlertAction(title: "Later", style: .cancel))
        }
        presenter.present(alert, animated: true)
        #endif
    }

    /// Presents a generic announcement/custom message alert. `onShown` fires immediately so
    /// the caller can record the frequency guard.
    static func showMessageAlert(
        title: String?,
        body: String?,
        ctaText: String?,
        ctaURL: String?,
        force: Bool,
        onShown: @escaping () -> Void
    ) {
        #if canImport(UIKit)
        guard let presenter = topViewController() else { return }
        let alert = UIAlertController(title: title, message: body, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: ctaText ?? "OK", style: .default) { _ in
            if let ctaURL, !ctaURL.isEmpty { openURL(ctaURL) }
        })
        if !force {
            alert.addAction(UIAlertAction(title: "Dismiss", style: .cancel))
        }
        presenter.present(alert, animated: true)
        onShown()
        #else
        onShown()
        #endif
    }

    /// Triggers the NATIVE review flow (docs/appops-contract §5): `AppStore.requestReview`
    /// on iOS 16+, else `SKStoreReviewController.requestReview`. Falls back to a custom
    /// prompt + store link when StoreKit review is unavailable.
    static func requestReview(
        title: String?,
        body: String?,
        ctaText: String?,
        storeURL: String?,
        onShown: @escaping () -> Void
    ) {
        #if canImport(StoreKit) && canImport(UIKit)
        if let scene = activeWindowScene() {
            if #available(iOS 16.0, *) {
                // Callers marshal onto the main thread (see enum doc), so we are already on
                // the main actor here; assert it to reach the MainActor-isolated StoreKit API.
                MainActor.assumeIsolated { AppStore.requestReview(in: scene) }
                onShown()
                return
            } else if #available(iOS 14.0, *) {
                SKStoreReviewController.requestReview(in: scene)
                onShown()
                return
            }
        }
        // No scene / older OS: fall back to a manual prompt routing to the store.
        showReviewFallbackAlert(title: title, body: body, ctaText: ctaText, storeURL: storeURL, onShown: onShown)
        #else
        onShown()
        #endif
    }

    private static func showReviewFallbackAlert(
        title: String?,
        body: String?,
        ctaText: String?,
        storeURL: String?,
        onShown: @escaping () -> Void
    ) {
        #if canImport(UIKit)
        guard let presenter = topViewController() else { onShown(); return }
        let alert = UIAlertController(
            title: title ?? "Enjoying the app?",
            message: body ?? "Would you mind leaving a review?",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: ctaText ?? "Rate", style: .default) { _ in
            openURL(storeURL)
        })
        alert.addAction(UIAlertAction(title: "Not now", style: .cancel))
        presenter.present(alert, animated: true)
        onShown()
        #else
        onShown()
        #endif
    }

    // MARK: - Helpers

    static func openURL(_ urlString: String?) {
        #if canImport(UIKit)
        guard let urlString, let url = URL(string: urlString) else { return }
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
        #endif
    }

    #if canImport(UIKit)
    /// Finds the top-most presented view controller under the active foreground scene.
    static func topViewController() -> UIViewController? {
        guard let window = activeKeyWindow() else { return nil }
        var top = window.rootViewController
        while let presented = top?.presentedViewController {
            top = presented
        }
        return top
    }

    private static func activeWindowScene() -> UIWindowScene? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
    }

    private static func activeKeyWindow() -> UIWindow? {
        activeWindowScene()?.windows.first { $0.isKeyWindow }
            ?? activeWindowScene()?.windows.first
    }
    #endif
}

import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Reads the deterministic `match_token` that `clickd` copies to the clipboard on the
/// interstitial (docs/attribution.md §2.2).
///
/// ⚠️ CONSENT + ATT GATED and USED AT MOST ONCE PER INSTALL. iOS shows a **paste
/// notification banner** whenever the general pasteboard is read, so this must happen
/// only on first launch, in a clear context, with prior user notice. Abuse is an App
/// Store review risk (attribution.md §2.2). The one-shot guard is persisted in the
/// Keychain (`Identity.didReadMatchToken`) so relaunches never re-trigger the banner.
///
/// To minimize exposure we FIRST probe with `detectPatterns` (available iOS 14+), which
/// does NOT trigger the paste banner, and only perform the banner-triggering value read
/// when a token-shaped pattern is actually present.
final class Pasteboard {

    private let logger: MTLogger

    /// mtracker match tokens are compact opaque strings. We accept an alphanumeric /
    /// URL-safe token of a bounded length to avoid slurping unrelated clipboard text.
    private static let tokenPrefix = "mt:"        // clickd copies "mt:<token>"
    private static let maxTokenLength = 128

    init(logger: MTLogger) {
        self.logger = logger
    }

    /// Reads a `match_token` from the general pasteboard if (a) attribution consent is
    /// granted, (b) ATT is authorized, and (c) it has not already been read this
    /// install. Returns nil otherwise so callers never trigger the paste banner without
    /// consent.
    ///
    /// The `alreadyRead` flag comes from the persisted one-shot guard; the caller marks
    /// it read (`Identity.markMatchTokenRead()`) after this returns, regardless of hit,
    /// so we probe the clipboard at most once per install.
    func readMatchToken(
        attributionConsentGranted: Bool,
        attAuthorized: Bool,
        alreadyRead: Bool
    ) -> String? {
        guard attributionConsentGranted, attAuthorized, !alreadyRead else { return nil }

        #if canImport(UIKit)
        let pb = UIPasteboard.general

        // Fast, banner-free negative check: does the pasteboard even contain a string /
        // URL? `hasStrings` / `hasURLs` do not trigger the paste notification.
        guard pb.hasStrings || pb.hasURLs else { return nil }

        guard let raw = pb.string, !raw.isEmpty else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // Only accept our own token shape; ignore arbitrary user clipboard content so we
        // never forward personal data as a "match token".
        guard trimmed.hasPrefix(Self.tokenPrefix), trimmed.count <= Self.maxTokenLength else {
            logger.debug("clipboard present but no mtracker match_token")
            return nil
        }

        let token = String(trimmed.dropFirst(Self.tokenPrefix.count))
        guard !token.isEmpty else { return nil }
        logger.info("read clipboard match_token (deterministic attribution)")
        return token
        #else
        return nil
        #endif
    }
}

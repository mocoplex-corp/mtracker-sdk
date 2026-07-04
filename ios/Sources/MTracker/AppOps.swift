import Foundation

/// App Ops public models (docs/appops-contract §2, §5).
///
/// Server-resolved, already-localized surfaces the SDK renders: a version-update prompt,
/// in-app messages / announcements / review prompts, and the remote-config map. The host
/// app can override the default UI via `MTracker.shared.onUpdateAvailable` / `onMessage`.

/// A server-driven version-update prompt (docs/appops-contract §2 `update`).
public struct UpdateInfo: Sendable {
    /// True when a newer store version is available for this platform.
    public let available: Bool
    /// True when the current version is below `version_min` — the popup is blocking.
    public let force: Bool
    /// Latest store version string (e.g. "1.2.0"), if known.
    public let latestVersion: String?
    /// Store listing URL to open on the CTA.
    public let storeURL: String?
    /// Localized dialog title (server-resolved).
    public let title: String?
    /// Localized dialog body (server-resolved).
    public let body: String?
}

/// Type of an in-app message (docs/appops-contract §1 `app_messages.type`).
public enum AppMessageType: String, Sendable {
    case update, announcement, review, custom

    static func from(_ raw: String?) -> AppMessageType {
        switch raw?.lowercased() {
        case "update": return .update
        case "review": return .review
        case "custom": return .custom
        default: return .announcement
        }
    }
}

/// How often a message may be shown (docs/appops-contract §1 `frequency`).
public enum AppMessageFrequency: String, Sendable {
    case once, session, daily, always

    static func from(_ raw: String?) -> AppMessageFrequency {
        switch raw?.lowercased() {
        case "once": return .once
        case "session": return .session
        case "daily": return .daily
        default: return .always
        }
    }
}

/// SKAdNetwork conversion-value schema, delivered inside the App Ops payload under the
/// `skan` field (docs/skan-contract §1, §3). The SDK uses it to compute the current
/// fine/coarse conversion value from post-install events and revenue, calling
/// `SKAdNetwork.updatePostbackConversionValue` only when the value increases within the
/// measurement window (docs/skan-contract §5).
///
/// Internal — the schema drives automatic behavior; no host-facing API is exposed.
struct SkanSchema {
    /// A named event → conversion value mapping (docs/skan-contract §1 `events[]`).
    struct Event {
        let name: String
        let fine: Int      // 0–63
        let coarse: String // low | medium | high
    }
    /// A cumulative-revenue threshold → conversion value mapping
    /// (docs/skan-contract §1 `revenue_buckets[]`).
    struct RevenueBucket {
        let min: Double
        let fine: Int
        let coarse: String
    }

    /// Whether coarse (SKAN 4) values are enabled by the schema.
    let coarseEnabled: Bool
    /// Window (hours from install) during which values may be updated.
    let measurementWindowHours: Int
    /// "events" | "revenue" — which mapping(s) drive the value. Both are always
    /// considered; `mode` is advisory (the max of both wins).
    let mode: String
    let events: [Event]
    let revenueBuckets: [RevenueBucket]
}

/// A single in-app message / announcement / review prompt (docs/appops-contract §2
/// `messages[]`). Text fields are already localized to the device language by the server.
public struct AppMessage: Sendable {
    public let id: String
    public let type: AppMessageType
    public let priority: Int
    public let title: String?
    public let body: String?
    public let ctaText: String?
    public let ctaURL: String?
    public let imageURL: String?
    /// True for a blocking/force message.
    public let force: Bool
    /// Cumulative foreground seconds required before a review prompt fires.
    public let minSessionSec: Int
    public let frequency: AppMessageFrequency
}

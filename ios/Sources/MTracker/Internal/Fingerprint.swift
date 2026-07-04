import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Device signals for probabilistic click↔install matching (docs/attribution.md §3).
///
/// Collection is CONSENT + ATT gated: signals are gathered ONLY with `attribution`
/// consent AND ATT authorization (attribution.md §2.3: "ATT 미동의 시에는 사용하지 않음").
/// IP (or /24 subnet) is added server-side from the request, never on-device.
///
/// The signal set matches attribution.md §3: OS version, device model, screen
/// resolution/scale, language, timezone, and (when available) carrier. These are the
/// entropy sources the backend scores against the click-time fingerprint index.
struct DeviceFingerprint: Codable {
    let osVersion: String
    let deviceModel: String
    let screenWidth: Int
    let screenHeight: Int
    let scale: Double
    let language: String
    let timezone: String
    let carrier: String?

    private enum CodingKeys: String, CodingKey {
        case osVersion = "os"
        case deviceModel = "model"
        case screenWidth = "sw"
        case screenHeight = "sh"
        case scale
        case language = "lang"
        case timezone = "tz"
        case carrier
    }
}

final class Fingerprint {

    /// Collects signals only when BOTH `attributionConsentGranted` and `attAuthorized`.
    /// Returns nil otherwise so signals are never transmitted without consent + ATT.
    func collect(attributionConsentGranted: Bool, attAuthorized: Bool) -> DeviceFingerprint? {
        guard attributionConsentGranted, attAuthorized else { return nil }

        #if canImport(UIKit)
        let device = UIDevice.current
        let screen = UIScreen.main
        // Points × native scale gives native pixel dimensions (matches §3 "해상도·밀도").
        let bounds = screen.nativeBounds
        let scale = Double(screen.nativeScale)

        return DeviceFingerprint(
            osVersion: device.systemVersion,
            deviceModel: Self.hardwareModel(),
            screenWidth: Int(bounds.width),
            screenHeight: Int(bounds.height),
            scale: scale,
            language: Locale.preferredLanguages.first ?? Locale.current.identifier,
            timezone: TimeZone.current.identifier,
            carrier: nil // CTCarrier is deprecated/returns nil on iOS 16+; omitted.
        )
        #else
        return nil
        #endif
    }

    /// Serialises the fingerprint to a compact JSON string for the event's `device_fp`
    /// field (the backend carries it as an opaque JSON string).
    func collectJSON(attributionConsentGranted: Bool, attAuthorized: Bool) -> String? {
        guard let fp = collect(attributionConsentGranted: attributionConsentGranted,
                               attAuthorized: attAuthorized) else { return nil }
        guard let data = try? JSONEncoder().encode(fp) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Returns the low-level hardware model identifier (e.g. "iPhone15,3"), which is
    /// higher entropy than `UIDevice.model` ("iPhone"). Read via `uname`.
    private static func hardwareModel() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let mirror = Mirror(reflecting: systemInfo.machine)
        let identifier = mirror.children.reduce(into: "") { partial, element in
            guard let value = element.value as? Int8, value != 0 else { return }
            partial.append(Character(UnicodeScalar(UInt8(value))))
        }
        return identifier.isEmpty ? "unknown" : identifier
    }
}

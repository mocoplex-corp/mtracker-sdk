# mtracker (Flutter) — iOS plugin bridge

Thin Pigeon + PlatformView bridge exposing the native iOS Core (`sdk/ios`, the `Ja0Tracker`
Swift package / XCFramework) to Flutter. It **delegates** to the Core — no Core logic is
duplicated.

## Files

- `mtracker.podspec` — the plugin pod; `s.dependency 'Ja0Tracker'` pulls in the shared Core.
- `Classes/Ja0TrackerPlugin.swift` — `FlutterPlugin` implementing the Pigeon `Ja0TrackerHostApi`
  by delegating to `Ja0Tracker.shared` (`initialize`, `requestTrackingConsent`, `setConsent`,
  `trackEvent`, `loadAd`) and pushing `onAttribution`/`onDeepLink` back through the generated
  `Ja0TrackerFlutterApi`. Registers the ad PlatformView factory and forwards inbound URLs
  (Universal Links / custom schemes) to `Ja0Tracker.shared.handleDeepLink`.
- `Classes/Messages.g.swift` — Pigeon output (hand-written to match `dart run pigeon`;
  regenerate to overwrite).
- `Classes/MTNativeAdViewFactory.swift` — `FlutterPlatformViewFactory` registering
  `io.ja0tracker/native_ad_view`, wrapping `MTNativeAdView` from `sdk/ios`.

## How it wires to the Core

`import Ja0TrackerSDK` then direct calls to `Ja0Tracker.shared`. `requestTrackingConsent`/`loadAd`
bridge the Core's `async` API into the async Pigeon callbacks via `Task`. Callbacks are
registered once and relayed through `Ja0TrackerFlutterApi`.

## Client build steps

1. Ship an `Ja0TrackerSDK.podspec` (XCFramework/source) from `sdk/ios` so the pod `s.dependency
   'Ja0Tracker'` resolves (or add the Ja0Tracker SwiftPM package to the app project).
2. `cd ios && pod install`, then `flutter run`.
3. Set `NSUserTrackingUsageDescription` in the host `Info.plist` (for the ATT prompt) and
   add `associated-domains` (`applinks:go-mtracker.ja0.com`) for Universal-Link deep links.
   `PrivacyInfo.xcprivacy` ships as a resource of the `Ja0TrackerSDK` pod.

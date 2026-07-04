# mtracker (Flutter) — iOS plugin bridge

Thin Pigeon + PlatformView bridge exposing the native iOS Core (`sdk/ios`, the `MTracker`
Swift package / XCFramework) to Flutter. It **delegates** to the Core — no Core logic is
duplicated.

## Files

- `mtracker.podspec` — the plugin pod; `s.dependency 'MTracker'` pulls in the shared Core.
- `Classes/MtrackerPlugin.swift` — `FlutterPlugin` implementing the Pigeon `MtrackerHostApi`
  by delegating to `MTracker.shared` (`initialize`, `requestTrackingConsent`, `setConsent`,
  `trackEvent`, `loadAd`) and pushing `onAttribution`/`onDeepLink` back through the generated
  `MtrackerFlutterApi`. Registers the ad PlatformView factory and forwards inbound URLs
  (Universal Links / custom schemes) to `MTracker.shared.handleDeepLink`.
- `Classes/Messages.g.swift` — Pigeon output (hand-written to match `dart run pigeon`;
  regenerate to overwrite).
- `Classes/MTNativeAdViewFactory.swift` — `FlutterPlatformViewFactory` registering
  `io.mtracker/native_ad_view`, wrapping `MTNativeAdView` from `sdk/ios`.

## How it wires to the Core

`import MTracker` then direct calls to `MTracker.shared`. `requestTrackingConsent`/`loadAd`
bridge the Core's `async` API into the async Pigeon callbacks via `Task`. Callbacks are
registered once and relayed through `MtrackerFlutterApi`.

## Client build steps

1. Ship an `MTracker.podspec` (XCFramework/source) from `sdk/ios` so the pod `s.dependency
   'MTracker'` resolves (or add the MTracker SwiftPM package to the app project).
2. `cd ios && pod install`, then `flutter run`.
3. Set `NSUserTrackingUsageDescription` in the host `Info.plist` (for the ATT prompt) and
   add `associated-domains` (`applinks:go-mtracker.ja0.com`) for Universal-Link deep links.
   `PrivacyInfo.xcprivacy` ships as a resource of the `MTracker` pod.

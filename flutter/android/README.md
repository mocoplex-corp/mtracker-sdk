# mtracker (Flutter) — Android plugin bridge

Thin Pigeon + PlatformView bridge exposing the native Android Core (`sdk/android`, the
`io.ja0tracker.sdk` AAR) to Flutter. It **delegates** every call to the Core — no HMAC,
queue, attribution, session, or ad-render logic is duplicated here.

## Files

- `build.gradle` — depends on `io.ja0tracker:ja0tracker-android` (the shared Core AAR) +
  coroutines.
- `src/main/kotlin/io/mtracker/flutter/MtrackerPlugin.kt` — `FlutterPlugin` implementing the
  Pigeon `MtrackerHostApi` by delegating to `io.ja0tracker.sdk.Ja0Tracker` (`initialize`,
  `requestTrackingConsent`, `setConsent`, `trackEvent`, `loadAd`) and pushing
  `onAttribution`/`onDeepLink` back through the generated `MtrackerFlutterApi`. Registers
  the ad PlatformView factory.
- `src/main/kotlin/io/mtracker/flutter/Messages.g.kt` — Pigeon output (hand-written to match
  `dart run pigeon`; regenerate to overwrite).
- `src/main/kotlin/io/mtracker/flutter/MTNativeAdViewFactory.kt` — `PlatformViewFactory`
  registering `io.mtracker/native_ad_view`, wrapping `io.ja0tracker.sdk.ads.MTNativeAdView`.

## How it wires to the Core

`MtrackerPlugin` holds an `io.ja0tracker.sdk.Ja0Tracker` reference and forwards Host API calls
straight to it. `requestTrackingConsent` and `loadAd` bridge the Core's `suspend fun`s onto
a coroutine and complete the async Pigeon callback. Attribution/deep-link callbacks are
registered once against the Core and relayed via `MtrackerFlutterApi`.

## Client build steps

1. Publish `sdk/android` to a Maven repo the app resolves, or `includeBuild("sdk/android")`
   in the monorepo (the coordinate is `io.ja0tracker:ja0tracker-android:1.0.0`).
2. `flutter pub get && flutter run` — Flutter autolinks the plugin.
3. Add deep-link `<intent-filter>` for `go-mtracker.ja0.com` to the host app's launcher
   Activity (and call `Ja0Tracker.handleDeepLink(intent)` from `onNewIntent` for live links).

## Notes

- `TODO(core)`: `MTNativeAdView` does not yet expose click/impression listeners; the
  `MTNativeAd(onAdClicked:)` widget callback is not fired until the Core adds them. Beacons
  still fire inside the Core view.

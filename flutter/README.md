# mtracker (Flutter)

Flutter SDK for mtracker — mobile attribution, in-app events, deferred deep links, and
native ad slots. A **thin Pigeon + PlatformView wrapper** over the native iOS/Android
cores (`sdk/ios`, `sdk/android`).

> The public Dart API, the Pigeon schema, the generated-style message code (Dart/Kotlin/
> Swift), and the native Android + iOS plugin bridges are all implemented and delegate to
> the shared cores. `lib/src/messages.g.dart`, `android/.../Messages.g.kt`, and
> `ios/Classes/Messages.g.swift` are hand-written to match `dart run pigeon` output — run
> pigeon to regenerate. Nothing is compiled in this scaffolding environment (no Flutter/
> native toolchain) — build it in your app.

> **Build & release:** see [`docs/sdk-build-release.md`](../../docs/sdk-build-release.md).
> Official distribution + integration guide: <https://mtracker.ja0.com/sdk>.

## Install

```yaml
dependencies:
  mtracker:
    git: https://github.com/mocoplex/mtracker.git   # path: sdk/flutter
```

### Client build steps

1. Provide the native cores so the plugin can resolve them:
   - **Android** — publish `sdk/android` to a Maven repo (coordinate
     `io.ja0tracker:ja0tracker-android:1.0.0`) or `includeBuild("sdk/android")` in the monorepo.
   - **iOS** — ship an `MTracker.podspec` (XCFramework/source) from `sdk/ios`, so
     `s.dependency 'MTracker'` in `ios/mtracker.podspec` resolves; then `cd ios && pod install`.
2. `flutter pub get`, then `flutter run` — Flutter autolinks the plugin on both platforms.
3. (Optional) regenerate the Pigeon code: `dart run pigeon --input pigeons/messages.dart`.

## Usage

```dart
import 'package:mtracker/mtracker.dart';

// 1. Initialize once at app start (sdkKey + sdkSecret + appId are all required)
await MTracker.instance.initialize(
  const MTrackerConfig(
    sdkKey: 'APP_SDK_KEY',
    sdkSecret: 'APP_SDK_SECRET',
    appId: 'APP_UUID',
    waitForConsent: true,
  ),
);

// 2. Consent (iOS shows the ATT prompt; Android resolves to granted)
final status = await MTracker.instance.requestTrackingConsent();
await MTracker.instance.setConsent(
  const Consent(analytics: true, attribution: true, ads: true),
);

// 3. Attribution + deferred deep link callbacks
MTracker.instance.onAttribution((data) { /* data.source, data.campaign, data.confidence */ });
MTracker.instance.onDeepLink((link) { /* route by link.path + link.params */ });

// 4. In-app events
MTracker.instance.trackEvent('purchase', {'revenue': 9900, 'currency': 'KRW'});

// 5. Native ads (docs/ads.md)
final ad = await MTracker.instance.ads.load('home_feed_slot');   // imperative
// or render the widget:
const MTNativeAd(slotId: 'home_feed_slot');
```

See `example/lib/main.dart` for a runnable-shaped minimal app.

## Architecture

- `lib/mtracker.dart` — public Dart facade + types + `MTNativeAd` PlatformView widget.
- `pigeons/messages.dart` — Pigeon schema (Host + Flutter APIs). Regenerate with
  `dart run pigeon --input pigeons/messages.dart`.
- `lib/src/messages.g.dart` — Pigeon output, hand-written to match `dart run pigeon`
  (Dart/Kotlin/Swift sides ship matching codecs so it builds without running pigeon).
- `android/`, `ios/` — thin native plugin bridges that implement the Pigeon `MtrackerHostApi`
  by delegating to the shared cores, and register the `MTNativeAd` PlatformView (see READMEs).

## Backend endpoints

- Ingest: `https://ingest-mtracker.ja0.com` (batch `POST /v1/events`, JSON + SDK key + HMAC)
- clickd / deep links: `https://go-mtracker.ja0.com`

Override via `MTrackerConfig(ingestBaseUrl: ..., clickdBaseUrl: ...)`.

## Client build / pre-release tasks

- Provide the native cores so the plugin resolves them: publish the
  `io.ja0tracker:ja0tracker-android` AAR from `sdk/android`, and ship an `MTracker.podspec`
  (XCFramework/source) from `sdk/ios` so `s.dependency 'MTracker'` resolves.
- Host-app config: deep-link `<intent-filter>` for `go-mtracker.ja0.com` (Android) and
  `associated-domains` (`applinks:go-mtracker.ja0.com`) + `NSUserTrackingUsageDescription`
  (iOS). `PrivacyInfo.xcprivacy` ships as a resource of the `MTracker` pod.
- (Optional) regenerate the Pigeon code: `dart run pigeon --input pigeons/messages.dart`.
- `TODO(core)`: `MTNativeAdView` does not yet expose click/impression listeners, so
  `MTNativeAd(onAdClicked:)` is not fired until the Core adds them (beacons still fire).
- `TODO(release)` set `publish_to` and publish to pub.dev.

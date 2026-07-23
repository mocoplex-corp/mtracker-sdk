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
  ja0tracker:
    git: https://github.com/mocoplex/mtracker.git   # path: sdk/flutter
```

### Client build steps

1. Provide the native cores so the plugin can resolve them:
   - **Android** — publish `sdk/android` to a Maven repo (coordinate
     `io.ja0tracker:ja0tracker-android:1.0.3`) or `includeBuild("sdk/android")` in the monorepo.
   - **iOS** — ship an `Ja0TrackerSDK.podspec` (XCFramework/source) from `sdk/ios`, so
     `s.dependency 'Ja0TrackerSDK'` in `ios/ja0tracker.podspec` resolves; then `cd ios && pod install`.
2. `flutter pub get`, then `flutter run` — Flutter autolinks the plugin on both platforms.
3. (Optional) regenerate the Pigeon code: `dart run pigeon --input pigeons/messages.dart`.

## Usage

```dart
import 'package:ja0tracker/ja0tracker.dart';

// 1. Initialize once at app start (sdkKey + sdkSecret + appId are all required)
await Ja0Tracker.instance.initialize(
  const Ja0TrackerConfig(
    sdkKey: 'APP_SDK_KEY',
    sdkSecret: 'APP_SDK_SECRET',
    appId: 'APP_UUID',
    waitForConsent: true,
  ),
);

// 2. Consent (iOS shows the ATT prompt; Android resolves to granted)
final status = await Ja0Tracker.instance.requestTrackingConsent();
await Ja0Tracker.instance.setConsent(
  const Consent(analytics: true, attribution: true, ads: true),
);

// 3. Attribution + deferred deep link callbacks
Ja0Tracker.instance.onAttribution((data) { /* data.source, data.campaign, data.confidence */ });
Ja0Tracker.instance.onDeepLink((link) { /* route by link.path + link.params */ });

// 4. In-app events
Ja0Tracker.instance.trackEvent('purchase', {'revenue': 9900, 'currency': 'KRW'});

// 5. Native ads (docs/ads.md)
final ad = await Ja0Tracker.instance.ads.load('home_feed_slot');   // imperative
// or render the widget:
const MTNativeAd(slotId: 'home_feed_slot');
```

On Android, granting attribution or ads consent enables collection of the
resettable Google Advertising ID (AAID). The plugin omits deleted, zeroed, or
limited identifiers, adds an `adid` field to subsequent event parameters and
native-ad request context, and emits one `adid_sync` event so the identifier can
be associated with the SDK install ID. Apps targeting Android 13+ must declare
Advertising ID use in Google Play Console; the plugin manifest supplies the
required `com.google.android.gms.permission.AD_ID` permission.

See `example/lib/main.dart` for a runnable-shaped minimal app.

## Desktop (Windows / macOS / Linux)

There is **no native core** on desktop, so the SDK runs these features in **pure Dart**:

- **House ads** — `MTNativeAd(slotId: ...)` fetches the ad from the adserver over HTTP and
  renders it with a Dart widget. A tap opens the campaign's **web landing** via clickd
  (set *웹 랜딩 URL* on the house campaign in the console). Impressions/clicks are tracked.
- **App update prompt** — polled from App Ops on init; the SDK draws the update dialog and
  its CTA opens the download page. Desktop has no app store, so configure an **update
  message** in the console whose **CTA URL** is your Windows/macOS download link.
- **Review request** — a `review`-type App Ops message draws a Dart dialog whose CTA opens
  your review page (`cta_url`).

Prompts respect their `frequency` (`once`/`daily`/`session` — persisted via
`shared_preferences`) and `min_session_sec` (shown after N seconds of use, not instantly),
matching the native mobile behavior.

Two things to wire up in the host app:

```dart
// 1. Attach the SDK navigator key so it can draw its own dialogs (no host UI code).
MaterialApp(navigatorKey: Ja0Tracker.navigatorKey, ...);

// 2. Initialize as usual. appVersion is auto-read (package_info_plus); override if needed.
await Ja0Tracker.instance.initialize(const Ja0TrackerConfig(
  sdkKey: 'APP_SDK_KEY', sdkSecret: 'APP_SDK_SECRET', appId: 'APP_UUID',
  // appVersion: '1.2.0',          // optional override
  // enableDesktopAppOps: true,    // default; set false to draw update/review yourself
));
```

If `navigatorKey` is not attached, the update/review prompts fall back to the
`onUpdateAvailable` / `onMessage` callbacks so the host can draw them. Web (Flutter web)
is not supported (the SDK uses `dart:io`).

## Architecture

- `lib/mtracker.dart` — public Dart facade + types + `MTNativeAd` PlatformView widget.
- `pigeons/messages.dart` — Pigeon schema (Host + Flutter APIs). Regenerate with
  `dart run pigeon --input pigeons/messages.dart`.
- `lib/src/messages.g.dart` — Pigeon output, hand-written to match `dart run pigeon`
  (Dart/Kotlin/Swift sides ship matching codecs so it builds without running pigeon).
- `android/`, `ios/` — thin native plugin bridges that implement the Pigeon `Ja0TrackerHostApi`
  by delegating to the shared cores, and register the `MTNativeAd` PlatformView (see READMEs).

## Backend endpoints

- Ingest: `https://ingest-mtracker.ja0.com` (batch `POST /v1/events`, JSON + SDK key + HMAC)
- App Ops — remote config / in-app messages / update prompts / push register:
  `https://api-mtracker.ja0.com` (`GET /v1/appops`, `POST /v1/push/register`). Served by the
  **api** service (not ingest); the native cores default to this host.
- Native ad slots: `https://ad-mtracker.ja0.com` (`POST /v1/ad`)
- clickd / deep links: `https://go-mtracker.ja0.com`

Override the ingest/clickd hosts via `Ja0TrackerConfig(ingestBaseUrl: ..., clickdBaseUrl: ...)`.
The App Ops host defaults to the api service and normally needs no override.

## Client build / pre-release tasks

- Provide the native cores so the plugin resolves them: publish the
  `io.ja0tracker:ja0tracker-android` AAR from `sdk/android`, and ship an `Ja0TrackerSDK.podspec`
  (XCFramework/source) from `sdk/ios` so `s.dependency 'Ja0TrackerSDK'` resolves.
- Host-app config: deep-link `<intent-filter>` for `go-mtracker.ja0.com` (Android) and
  `associated-domains` (`applinks:go-mtracker.ja0.com`) + `NSUserTrackingUsageDescription`
  (iOS). `PrivacyInfo.xcprivacy` ships as a resource of the `Ja0TrackerSDK` pod.
- (Optional) regenerate the Pigeon code: `dart run pigeon --input pigeons/messages.dart`.
- `MTNativeAd(onAdClicked:, onAdImpression:)` are wired: the Core `MTNativeAdView`
  exposes `onImpression`/`onClick`, and the PlatformView forwards them to Dart over a
  per-view MethodChannel (`io.ja0tracker/native_ad_view_<id>`).
- `TODO(release)` set `publish_to` and publish to pub.dev.

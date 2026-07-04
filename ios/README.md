# mtracker iOS SDK (Swift Package)

Native Core for mtracker on iOS — attribution (SKAdNetwork 4 + AdAttributionKit +
clipboard match token + device fingerprint), a durable offline event queue, session
tracking, deferred/live deep links, and native ad slots. The React Native and Flutter
wrappers bind to this library.

Apple frameworks only — **no third-party dependencies** (CryptoKit, StoreKit,
AdAttributionKit, AppTrackingTransparency, UIKit, Security).

> **Build & release:** see [`docs/sdk-build-release.md`](../../docs/sdk-build-release.md).
> Official distribution + integration guide: <https://mtracker.ja0.com/sdk>.

## Requirements

- iOS 15+
- Swift 5.9+, distributed via SPM (and optionally an XCFramework for CocoaPods — docs/sdk.md §4)

## Install (Swift Package Manager)

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/mocoplex-corp/mtracker-sdk.git", from: "1.0.0")
]
```

## Usage

Initialize once, as early as possible, with the three credentials issued in the mtracker
dashboard (`/dashboard/mtracker/apps`): the public `sdkKey`, the one-time `sdkSecret`
(HMAC secret), and the `appId` (UUID).

### UIKit (`AppDelegate`)

```swift
import Ja0TrackerSDK

func application(_ app: UIApplication,
                didFinishLaunchingWithOptions opts: [...]?) -> Bool {
    Ja0Tracker.shared.initialize(Ja0TrackerConfig(
        sdkKey:    "pk_ja0_demo",
        sdkSecret: "sk_ja0_demo_secret_change_me",   // from dashboard (shown once)
        appId:     "00000000-0000-0000-0000-0000000000a2",
        waitForConsent: true
    ))
    return true
}
```

### SwiftUI (`App`)

```swift
@main
struct DemoApp: App {
    init() {
        Ja0Tracker.shared.initialize(Ja0TrackerConfig(
            sdkKey: "pk_ja0_demo",
            sdkSecret: "sk_ja0_demo_secret_change_me",
            appId: "00000000-0000-0000-0000-0000000000a2"))
    }
    var body: some Scene {
        WindowGroup {
            ContentView()
                .onOpenURL { url in Ja0Tracker.shared.handleDeepLink(url) }   // Universal Links
        }
    }
}
```

### Consent (ATT + GDPR)

```swift
Task {
    let status = await Ja0Tracker.shared.requestTrackingConsent()   // ATT system prompt
    Ja0Tracker.shared.setConsent(Consent(analytics: true, attribution: true, ads: true))
}
```

- SKAdNetwork/AdAttributionKit (aggregate attribution) run **regardless of consent** and
  need no ATT — review-safe (docs/attribution.md §2.1).
- Clipboard `match_token` (deterministic) and device fingerprint (probabilistic) are read
  **only** when `attribution` consent AND ATT authorization are both granted, at most once
  per install (docs/attribution.md §2.2–2.3). The clipboard read triggers the iOS paste
  banner, so prime the user with context before calling `requestTrackingConsent()`.

### Attribution + deep links

```swift
Ja0Tracker.shared.onAttribution { data in /* data.source, data.campaign, data.confidence */ }
Ja0Tracker.shared.onDeepLink   { link in /* route by link.path + link.params */ }
```

### In-app events

```swift
Ja0Tracker.shared.trackEvent("level_up", ["level": 5])
Ja0Tracker.shared.trackEvent("purchase", ["revenue": 9900, "currency": "KRW", "itemId": "sku_1"])
```

`revenue` / `currency` in the params are lifted to the top-level contract fields. Events
are enqueued to a durable file-backed queue and flushed in batches with exponential
backoff; nothing is lost across relaunches or offline periods.

### Native ads (docs/ads.md)

```swift
Task {
    if let ad = await Ja0Tracker.shared.ads.load(slotId: "home_feed_slot") {
        let adView = MTNativeAdView()
        adView.bind(ad)          // renders assets; fires viewability impression + click beacons
        // add adView to your hierarchy, or read `ad.assets` and render fully custom
    }
}
```

## What the SDK sends (backend contract)

Batch `POST {ingestBaseURL}/v1/events` with headers (docs/sdk-contract §2):

```
X-MT-Key:        <sdkKey>
X-MT-Timestamp:  <unix seconds>
X-MT-Signature:  hex(HMAC-SHA256(sdkSecret, "<ts>." + <raw body bytes>))
Content-Type:    application/json
```

Body: `{ "sdk_key", "platform":"ios", "events":[ { event_id, app_id, install_id, name,
ts, session_id?, revenue?, currency?, params?, match_token?, device_fp? } ] }`.

- First launch persists a ULID `install_id` in the Keychain and enqueues an `install`
  event (delete→reinstall is detected as `reinstall`).
- Foreground entries after a >30s background gap emit `session_start`.
- Success `200 {accepted, duplicates}`; `401` = bad key/HMAC (delivery pauses, events
  retained); `429` honours `Retry-After`.

Base URLs are overridable via `Ja0TrackerConfig(ingestBaseURL:clickdBaseURL:adBaseURL:)`.

## Info.plist — ATT usage string (required for the prompt)

The host app **must** add an ATT purpose string or the system prompt won't show:

```xml
<key>NSUserTrackingUsageDescription</key>
<string>We use your data to measure ad performance and attribute your install to the
campaign that brought you here.</string>
```

(The RN Expo config plugin / Flutter plugin inject this automatically.)

## Privacy manifest

`PrivacyInfo.xcprivacy` is **required** and bundled as a package resource (declared in
`Package.swift`). It declares collected data types (device ID, product interaction,
advertising data, diagnostic/fingerprint), tracking domains, and required-reason APIs
(UserDefaults, system boot time, disk space). Review/trim it if you disable a feature
before release (docs/sdk.md §4, §6).

## Build (for the app developer)

The client only needs to build — no code changes required.

```bash
# From an Xcode-equipped machine:
cd sdk/ios
swift build                 # compile the library
swift test                  # run the unit tests (HMAC, ULID, batch encoding, ad parsing)
```

Or add the package in Xcode: **File ▸ Add Package Dependencies…** and point at this repo /
the published Git URL, then `import Ja0TrackerSDK`.

To ship a binary for CocoaPods, build an XCFramework:

```bash
xcodebuild archive -scheme Ja0TrackerSDK -destination "generic/platform=iOS" \
  -archivePath build/ios -SKIP_INSTALL=NO BUILD_LIBRARY_FOR_DISTRIBUTION=YES
xcodebuild archive -scheme Ja0TrackerSDK -destination "generic/platform=iOS Simulator" \
  -archivePath build/sim -SKIP_INSTALL=NO BUILD_LIBRARY_FOR_DISTRIBUTION=YES
xcodebuild -create-xcframework \
  -framework build/ios.xcarchive/Products/Library/Frameworks/Ja0TrackerSDK.framework \
  -framework build/sim.xcarchive/Products/Library/Frameworks/Ja0TrackerSDK.framework \
  -output Ja0TrackerSDK.xcframework
```

## Demo credentials

`sdkKey` = `pk_ja0_demo`, iOS `appId` = `00000000-0000-0000-0000-0000000000a2`, secret from
the dashboard (seed: `sk_ja0_demo_secret_change_me`). Real apps use their own issued keys.
```

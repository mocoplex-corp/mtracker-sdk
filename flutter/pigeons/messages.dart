// Pigeon schema for the mtracker Flutter <-> native bridge (docs/sdk.md §4).
//
// Generate the platform channel code with:
//   dart run pigeon --input pigeons/messages.dart
//
// Output targets are configured below. The generated Dart lands in
// lib/src/messages.g.dart (a hand-written stub currently ships there — TODO run pigeon).
//
// Host API  = Dart -> native calls (initialize, setConsent, trackEvent, loadAd, ...).
// Flutter API = native -> Dart callbacks (onAttribution, onDeepLink), delivered as
//               method callbacks; a Flutter EventChannel is an alternative (docs/sdk.md §4).

import 'package:pigeon/pigeon.dart';

@ConfigurePigeon(
  PigeonOptions(
    dartOut: 'lib/src/messages.g.dart',
    dartOptions: DartOptions(),
    kotlinOut:
        'android/src/main/kotlin/io/ja0tracker/flutter/Messages.g.kt',
    kotlinOptions: KotlinOptions(package: 'io.ja0tracker.flutter'),
    swiftOut: 'ios/Classes/Messages.g.swift',
    swiftOptions: SwiftOptions(),
    dartPackageName: 'ja0tracker',
  ),
)

// ---- Data classes (mirror the shared cross-platform models) ----

class ConfigMessage {
  ConfigMessage({
    required this.sdkKey,
    this.sdkSecret,
    this.appId,
    this.logLevel,
    this.waitForConsent,
    this.ingestBaseUrl,
    this.clickdBaseUrl,
  });

  String sdkKey;
  String? sdkSecret;
  String? appId;
  String? logLevel;
  bool? waitForConsent;
  String? ingestBaseUrl;
  String? clickdBaseUrl;
}

class ConsentMessage {
  ConsentMessage({
    required this.analytics,
    required this.attribution,
    required this.ads,
  });

  bool analytics;
  bool attribution;
  bool ads;
}

class AttributionMessage {
  AttributionMessage({
    this.source,
    this.campaign,
    this.network,
    this.clickId,
    required this.confidence,
    this.confidenceScore,
    this.raw,
  });

  String? source;
  String? campaign;
  String? network;
  String? clickId;
  String confidence; // deterministic | probabilistic | aggregate | organic
  double? confidenceScore;
  Map<String?, String?>? raw;
}

class DeepLinkMessage {
  DeepLinkMessage({
    this.path,
    this.params,
    this.url,
    required this.isDeferred,
  });

  String? path;
  Map<String?, String?>? params;
  String? url;
  bool isDeferred;
}

class NativeAdMediaMessage {
  NativeAdMediaMessage({required this.type, required this.url});
  String type; // image | video
  String url;
}

class NativeAdMessage {
  NativeAdMessage({
    required this.slotId,
    required this.adId,
    required this.format,
    this.headline,
    this.body,
    this.advertiser,
    this.cta,
    this.iconUrl,
    this.media,
    this.rating,
    required this.impressionUrls,
    required this.clickUrl,
    required this.viewablePixels,
    required this.viewableMs,
  });

  String slotId;
  String adId;
  String format;
  String? headline;
  String? body;
  String? advertiser;
  String? cta;
  String? iconUrl;
  NativeAdMediaMessage? media;
  double? rating;
  List<String?> impressionUrls;
  String clickUrl;
  double viewablePixels;
  int viewableMs;
}

// ---- App Ops (docs/appops-contract.md §2, §5) ----

class UpdateMessage {
  UpdateMessage({
    required this.available,
    required this.force,
    this.latestVersion,
    this.storeUrl,
    this.title,
    this.body,
  });

  bool available;
  bool force;
  String? latestVersion;
  String? storeUrl;
  String? title;
  String? body;
}

class AppMessageMessage {
  AppMessageMessage({
    required this.id,
    required this.type,
    required this.priority,
    this.title,
    this.body,
    this.ctaText,
    this.ctaUrl,
    this.imageUrl,
    required this.force,
    required this.minSessionSec,
    required this.frequency,
  });

  String id;
  String type; // update | announcement | review | custom
  int priority;
  String? title;
  String? body;
  String? ctaText;
  String? ctaUrl;
  String? imageUrl;
  bool force;
  int minSessionSec;
  String frequency; // once | session | daily | always
}

// ---- Host API: Dart -> native ----

@HostApi()
abstract class Ja0TrackerHostApi {
  void initialize(ConfigMessage config);

  @async
  String requestTrackingConsent(); // granted | denied | restricted | notDetermined

  void setConsent(ConsentMessage consent);

  void trackEvent(String name, Map<String?, Object?> params);

  @async
  NativeAdMessage? loadAd(String slotId);

  // App Ops
  @async
  String? getConfigJson(String key);

  void setPushConsent(bool granted);

  void setPushToken(String token);
}

// ---- Flutter API: native -> Dart callbacks ----

@FlutterApi()
abstract class Ja0TrackerFlutterApi {
  void onAttribution(AttributionMessage data);
  void onDeepLink(DeepLinkMessage data);
  void onUpdateAvailable(UpdateMessage data);
  void onMessage(AppMessageMessage data);
}

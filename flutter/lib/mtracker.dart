/// mtracker Flutter SDK — public API.
///
/// Mirrors the shared cross-platform facade (docs/sdk.md §2). A thin Pigeon/PlatformView
/// wrapper over the native iOS/Android cores (`sdk/ios`, `sdk/android`). All public calls
/// are defensively wrapped so SDK failures never crash the host app (docs/sdk.md §5).
library mtracker;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'src/messages.g.dart';

// ---- Public types (mirror Android/iOS/RN models) ----

enum LogLevel { none, error, warn, info, debug }

class MTrackerConfig {
  const MTrackerConfig({
    required this.sdkKey,
    required this.sdkSecret,
    required this.appId,
    this.logLevel = LogLevel.info,
    this.waitForConsent = true,
    this.ingestBaseUrl = defaultIngestBaseUrl,
    this.clickdBaseUrl = defaultClickdBaseUrl,
  });

  static const String defaultIngestBaseUrl = 'https://ingest-mtracker.ja0.com';
  static const String defaultClickdBaseUrl = 'https://go-mtracker.ja0.com';

  /// Tenant SDK public key issued by the dashboard. Required (SDK contract §5).
  final String sdkKey;

  /// Tenant HMAC secret issued alongside [sdkKey] (SDK contract §2); the native Core
  /// signs event batches with it. Required — the cores refuse to initialize without it.
  final String sdkSecret;

  /// App id (UUID) issued by the dashboard (SDK contract §3). Required.
  final String appId;

  final LogLevel logLevel;
  final bool waitForConsent;
  final String ingestBaseUrl;
  final String clickdBaseUrl;
}

class Consent {
  const Consent({
    this.analytics = false,
    this.attribution = false,
    this.ads = false,
  });

  final bool analytics;
  final bool attribution;
  final bool ads;
}

enum TrackingConsentStatus { granted, denied, restricted, notDetermined }

enum AttributionConfidence { deterministic, probabilistic, aggregate, organic }

class AttributionData {
  const AttributionData({
    this.source,
    this.campaign,
    this.network,
    this.clickId,
    required this.confidence,
    this.confidenceScore,
    this.raw = const <String, String>{},
  });

  final String? source;
  final String? campaign;
  final String? network;
  final String? clickId;
  final AttributionConfidence confidence;
  final double? confidenceScore;
  final Map<String, String> raw;
}

class DeepLinkData {
  const DeepLinkData({
    this.path,
    this.params = const <String, String>{},
    this.url,
    this.isDeferred = false,
  });

  final String? path;
  final Map<String, String> params;
  final String? url;
  final bool isDeferred;
}

// Native ad asset model (docs/ads.md §6).
enum NativeAdMediaType { image, video }

class NativeAdMedia {
  const NativeAdMedia({required this.type, required this.url});
  final NativeAdMediaType type;
  final String url;
}

class NativeAd {
  const NativeAd({
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
    this.viewablePixels = 0.5,
    this.viewableMs = 1000,
  });

  final String slotId;
  final String adId;
  final String format;
  final String? headline;
  final String? body;
  final String? advertiser;
  final String? cta;
  final String? iconUrl;
  final NativeAdMedia? media;
  final double? rating;
  final List<String> impressionUrls;
  final String clickUrl;
  final double viewablePixels;
  final int viewableMs;
}

// ---- App Ops types (docs/appops-contract.md §2, §5) ----

/// Server-driven version-update prompt (already localized to the device language).
class UpdateInfo {
  const UpdateInfo({
    required this.available,
    required this.force,
    this.latestVersion,
    this.storeUrl,
    this.title,
    this.body,
  });

  final bool available;
  final bool force;
  final String? latestVersion;
  final String? storeUrl;
  final String? title;
  final String? body;
}

enum AppMessageType { update, announcement, review, custom }

enum AppMessageFrequency { once, session, daily, always }

/// In-app message / announcement / review prompt (already localized).
class AppMessage {
  const AppMessage({
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

  final String id;
  final AppMessageType type;
  final int priority;
  final String? title;
  final String? body;
  final String? ctaText;
  final String? ctaUrl;
  final String? imageUrl;
  final bool force;
  final int minSessionSec;
  final AppMessageFrequency frequency;
}

typedef AttributionCallback = void Function(AttributionData data);
typedef DeepLinkCallback = void Function(DeepLinkData data);
typedef UpdateCallback = void Function(UpdateInfo data);
typedef MessageCallback = void Function(AppMessage data);

// ---- Public facade ----

/// Ads accessor, reached via `MTracker.instance.ads` (docs/ads.md).
class MTAds {
  MTAds._(this._host);
  final MtrackerHostApi _host;

  /// Load a native ad by slot ID. Resolves null on no-fill (docs/ads.md §3, §4).
  Future<NativeAd?> load(String slotId) async {
    try {
      final msg = await _host.loadAd(slotId);
      if (msg == null) return null;
      return _mapAd(msg);
    } catch (_) {
      return null;
    }
  }
}

class MTracker {
  MTracker._() {
    // Register a handler to receive native -> Dart callbacks. Pigeon's
    // MtrackerFlutterApi is an interface with `onAttribution(AttributionMessage)` /
    // `onDeepLink(DeepLinkMessage)`; those method names collide with the public
    // `onAttribution(cb)` / `onDeepLink(cb)` registration API, so the interface is
    // implemented by a separate [_FlutterApiHandler] that forwards into this facade.
    MtrackerFlutterApi.setUp(_FlutterApiHandler(this));
    ads = MTAds._(_host);
  }

  static final MTracker instance = MTracker._();

  final MtrackerHostApi _host = MtrackerHostApi();
  late final MTAds ads;

  AttributionCallback? _attributionCallback;
  DeepLinkCallback? _deepLinkCallback;
  AttributionData? _pendingAttribution;
  DeepLinkData? _pendingDeepLink;

  UpdateCallback? _updateCallback;
  MessageCallback? _messageCallback;
  UpdateInfo? _pendingUpdate;
  final List<AppMessage> _pendingMessages = <AppMessage>[];

  /// Initialize once at app start.
  Future<void> initialize(MTrackerConfig config) async {
    try {
      await _host.initialize(ConfigMessage(
        sdkKey: config.sdkKey,
        sdkSecret: config.sdkSecret,
        appId: config.appId,
        logLevel: config.logLevel.name,
        waitForConsent: config.waitForConsent,
        ingestBaseUrl: config.ingestBaseUrl,
        clickdBaseUrl: config.clickdBaseUrl,
      ));
    } catch (e, s) {
      _swallow(e, s);
    }
  }

  /// iOS: triggers the ATT prompt. Android: resolves to [TrackingConsentStatus.granted].
  Future<TrackingConsentStatus> requestTrackingConsent() async {
    try {
      final status = await _host.requestTrackingConsent();
      return _parseStatus(status);
    } catch (_) {
      return TrackingConsentStatus.notDetermined;
    }
  }

  Future<void> setConsent(Consent consent) async {
    try {
      await _host.setConsent(ConsentMessage(
        analytics: consent.analytics,
        attribution: consent.attribution,
        ads: consent.ads,
      ));
    } catch (e, s) {
      _swallow(e, s);
    }
  }

  /// Register the attribution callback; replays a pending result if one arrived early.
  void onAttribution(AttributionCallback cb) {
    _attributionCallback = cb;
    final pending = _pendingAttribution;
    if (pending != null) {
      cb(pending);
      _pendingAttribution = null;
    }
  }

  /// Register the deferred/live deep link callback; replays a pending link.
  void onDeepLink(DeepLinkCallback cb) {
    _deepLinkCallback = cb;
    final pending = _pendingDeepLink;
    if (pending != null) {
      cb(pending);
      _pendingDeepLink = null;
    }
  }

  Future<void> trackEvent(String name,
      [Map<String, Object?> params = const <String, Object?>{}]) async {
    try {
      await _host.trackEvent(name, params);
    } catch (e, s) {
      _swallow(e, s);
    }
  }

  // ---- App Ops: remote config (docs/appops-contract.md §5) ----

  /// Returns a cached remote-config string, or [defaultValue] when absent.
  Future<String?> getConfigString(String key, [String? defaultValue]) async {
    final raw = await _configRaw(key);
    return raw ?? defaultValue;
  }

  /// Returns a cached remote-config boolean, or [defaultValue] when absent.
  Future<bool> getConfigBool(String key, bool defaultValue) async {
    final raw = await _configRaw(key);
    if (raw == null) return defaultValue;
    return raw == 'true' || raw == '1';
  }

  /// Returns a cached remote-config integer, or [defaultValue] when absent.
  Future<int> getConfigInt(String key, int defaultValue) async {
    final raw = await _configRaw(key);
    if (raw == null) return defaultValue;
    return int.tryParse(raw) ?? defaultValue;
  }

  /// Returns a cached remote-config value parsed from JSON, or null when absent.
  Future<Object?> getConfigJson(String key) async {
    final raw = await _configRaw(key);
    if (raw == null) return null;
    try {
      return jsonDecode(raw);
    } catch (_) {
      return raw;
    }
  }

  Future<String?> _configRaw(String key) async {
    try {
      return await _host.getConfigJson(key);
    } catch (_) {
      return null;
    }
  }

  // ---- App Ops: update / message callbacks (docs/appops-contract.md §5) ----

  /// Override the default update popup. Receives the localized [UpdateInfo]; render your
  /// own UI and open `storeUrl` for the CTA (make `force` updates blocking). Replays a
  /// pending prompt if one arrived before registration.
  void onUpdateAvailable(UpdateCallback cb) {
    _updateCallback = cb;
    final pending = _pendingUpdate;
    if (pending != null) {
      cb(pending);
      _pendingUpdate = null;
    }
  }

  /// Override the default in-app message UI. Receives the localized [AppMessage]. The
  /// native side records frequency on delivery. Replays any messages buffered before
  /// registration.
  void onMessage(MessageCallback cb) {
    _messageCallback = cb;
    if (_pendingMessages.isNotEmpty) {
      final buffered = List<AppMessage>.from(_pendingMessages);
      _pendingMessages.clear();
      for (final m in buffered) {
        cb(m);
      }
    }
  }

  // ---- App Ops: push (docs/appops-contract.md §3) ----

  /// Consent gate for push registration; queued tokens are sent once granted.
  Future<void> setPushConsent(bool granted) async {
    try {
      await _host.setPushConsent(granted);
    } catch (e, s) {
      _swallow(e, s);
    }
  }

  /// Register an FCM/APNs token (host owns push setup). POSTed once consent is granted.
  Future<void> setPushToken(String token) async {
    try {
      await _host.setPushToken(token);
    } catch (e, s) {
      _swallow(e, s);
    }
  }

  // ---- native -> Dart dispatch (called by _FlutterApiHandler) ----
  // Pigeon delivers the wire message types; we map them to public models and dispatch
  // (or buffer until a callback is registered).

  void _dispatchAttribution(AttributionMessage data) {
    final model = _mapAttribution(data);
    final cb = _attributionCallback;
    if (cb != null) {
      cb(model);
    } else {
      _pendingAttribution = model;
    }
  }

  void _dispatchDeepLink(DeepLinkMessage data) {
    final model = _mapDeepLink(data);
    final cb = _deepLinkCallback;
    if (cb != null) {
      cb(model);
    } else {
      _pendingDeepLink = model;
    }
  }

  void _dispatchUpdate(UpdateMessage data) {
    final model = _mapUpdate(data);
    final cb = _updateCallback;
    if (cb != null) {
      cb(model);
    } else {
      _pendingUpdate = model;
    }
  }

  void _dispatchMessage(AppMessageMessage data) {
    final model = _mapMessage(data);
    final cb = _messageCallback;
    if (cb != null) {
      cb(model);
    } else {
      _pendingMessages.add(model);
    }
  }

  void _swallow(Object e, StackTrace s) {
    // SDK failures must never crash the host app (docs/sdk.md §5).
    if (kDebugMode) {
      debugPrint('[mtracker] swallowed error: $e');
    }
  }
}

/// Implements the Pigeon-generated [MtrackerFlutterApi] (native -> Dart) and forwards
/// each callback into the [MTracker] facade. Kept separate from [MTracker] because the
/// interface method names (`onAttribution`/`onDeepLink`) collide with the facade's
/// public callback-registration methods of the same name.
class _FlutterApiHandler implements MtrackerFlutterApi {
  _FlutterApiHandler(this._owner);
  final MTracker _owner;

  @override
  void onAttribution(AttributionMessage data) => _owner._dispatchAttribution(data);

  @override
  void onDeepLink(DeepLinkMessage data) => _owner._dispatchDeepLink(data);

  @override
  void onUpdateAvailable(UpdateMessage data) => _owner._dispatchUpdate(data);

  @override
  void onMessage(AppMessageMessage data) => _owner._dispatchMessage(data);
}

// ---- Mapping helpers (message <-> public model) ----

TrackingConsentStatus _parseStatus(String raw) {
  switch (raw) {
    case 'granted':
      return TrackingConsentStatus.granted;
    case 'denied':
      return TrackingConsentStatus.denied;
    case 'restricted':
      return TrackingConsentStatus.restricted;
    default:
      return TrackingConsentStatus.notDetermined;
  }
}

AttributionConfidence _parseConfidence(String raw) {
  switch (raw) {
    case 'deterministic':
      return AttributionConfidence.deterministic;
    case 'probabilistic':
      return AttributionConfidence.probabilistic;
    case 'aggregate':
      return AttributionConfidence.aggregate;
    default:
      return AttributionConfidence.organic;
  }
}

AttributionData _mapAttribution(AttributionMessage m) => AttributionData(
      source: m.source,
      campaign: m.campaign,
      network: m.network,
      clickId: m.clickId,
      confidence: _parseConfidence(m.confidence),
      confidenceScore: m.confidenceScore,
      raw: <String, String>{
        for (final e in (m.raw ?? const <String?, String?>{}).entries)
          if (e.key != null && e.value != null) e.key!: e.value!,
      },
    );

DeepLinkData _mapDeepLink(DeepLinkMessage m) => DeepLinkData(
      path: m.path,
      params: <String, String>{
        for (final e in (m.params ?? const <String?, String?>{}).entries)
          if (e.key != null && e.value != null) e.key!: e.value!,
      },
      url: m.url,
      isDeferred: m.isDeferred,
    );

UpdateInfo _mapUpdate(UpdateMessage m) => UpdateInfo(
      available: m.available,
      force: m.force,
      latestVersion: m.latestVersion,
      storeUrl: m.storeUrl,
      title: m.title,
      body: m.body,
    );

AppMessageType _parseMessageType(String raw) {
  switch (raw) {
    case 'update':
      return AppMessageType.update;
    case 'review':
      return AppMessageType.review;
    case 'custom':
      return AppMessageType.custom;
    default:
      return AppMessageType.announcement;
  }
}

AppMessageFrequency _parseFrequency(String raw) {
  switch (raw) {
    case 'once':
      return AppMessageFrequency.once;
    case 'session':
      return AppMessageFrequency.session;
    case 'daily':
      return AppMessageFrequency.daily;
    default:
      return AppMessageFrequency.always;
  }
}

AppMessage _mapMessage(AppMessageMessage m) => AppMessage(
      id: m.id,
      type: _parseMessageType(m.type),
      priority: m.priority,
      title: m.title,
      body: m.body,
      ctaText: m.ctaText,
      ctaUrl: m.ctaUrl,
      imageUrl: m.imageUrl,
      force: m.force,
      minSessionSec: m.minSessionSec,
      frequency: _parseFrequency(m.frequency),
    );

NativeAd _mapAd(NativeAdMessage m) => NativeAd(
      slotId: m.slotId,
      adId: m.adId,
      format: m.format,
      headline: m.headline,
      body: m.body,
      advertiser: m.advertiser,
      cta: m.cta,
      iconUrl: m.iconUrl,
      media: m.media == null
          ? null
          : NativeAdMedia(
              type: m.media!.type == 'video'
                  ? NativeAdMediaType.video
                  : NativeAdMediaType.image,
              url: m.media!.url,
            ),
      rating: m.rating,
      impressionUrls: <String>[
        for (final u in m.impressionUrls)
          if (u != null) u,
      ],
      clickUrl: m.clickUrl,
      viewablePixels: m.viewablePixels,
      viewableMs: m.viewableMs,
    );

// ---- Native ad widget (PlatformView) ----

/// `MTNativeAd(slotId: 'home_feed_slot')` — renders a native ad via a PlatformView
/// (`AndroidView` / `UiKitView`) backed by the native `MTNativeAdView`
/// (`sdk/ios`, `sdk/android`). The native side owns rendering + impression/click
/// beacons (docs/ads.md §6).
class MTNativeAd extends StatelessWidget {
  const MTNativeAd({
    super.key,
    required this.slotId,
    this.useDefaultTemplate = true,
    this.onAdClicked,
  });

  final String slotId;

  /// Use the SDK's built-in template (true) vs. app-custom rendering (false).
  final bool useDefaultTemplate;

  /// Fired when the user taps the ad.
  final void Function(String adId)? onAdClicked;

  static const String _viewType = 'io.mtracker/native_ad_view';

  @override
  Widget build(BuildContext context) {
    final creationParams = <String, Object?>{
      'slotId': slotId,
      'useDefaultTemplate': useDefaultTemplate,
    };

    // TODO(native): implement the PlatformViewFactory on both platforms:
    //   - Android: register `_viewType` -> a PlatformView wrapping MTNativeAdView.
    //   - iOS: register `_viewType` -> a FlutterPlatformView wrapping MTNativeAdView.
    // Ad tap/impression events flow back via a per-view MethodChannel (onAdClicked).
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return AndroidView(
          viewType: _viewType,
          creationParams: creationParams,
          creationParamsCodec: const StandardMessageCodec(),
        );
      case TargetPlatform.iOS:
        return UiKitView(
          viewType: _viewType,
          creationParams: creationParams,
          creationParamsCodec: const StandardMessageCodec(),
        );
      default:
        // TODO(native): unsupported platform — render a benign empty box.
        return const SizedBox.shrink();
    }
  }
}

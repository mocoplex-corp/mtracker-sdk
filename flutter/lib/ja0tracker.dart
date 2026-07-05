/// mtracker Flutter SDK — public API.
///
/// Mirrors the shared cross-platform facade (docs/sdk.md §2). A thin Pigeon/PlatformView
/// wrapper over the native iOS/Android cores (`sdk/ios`, `sdk/android`). All public calls
/// are defensively wrapped so SDK failures never crash the host app (docs/sdk.md §5).
library mtracker;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:in_app_review/in_app_review.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import 'src/messages.g.dart';

// ---- Public types (mirror Android/iOS/RN models) ----

enum LogLevel { none, error, warn, info, debug }

class Ja0TrackerConfig {
  const Ja0TrackerConfig({
    required this.sdkKey,
    required this.sdkSecret,
    required this.appId,
    this.logLevel = LogLevel.info,
    this.waitForConsent = true,
    this.ingestBaseUrl = defaultIngestBaseUrl,
    this.clickdBaseUrl = defaultClickdBaseUrl,
    this.adBaseUrl = defaultAdBaseUrl,
    this.appOpsBaseUrl = defaultAppOpsBaseUrl,
    this.autoRegisterPush = true,
    this.enableDesktopAppOps = true,
    this.appVersion,
  });

  static const String defaultIngestBaseUrl = 'https://ingest-mtracker.ja0.com';
  static const String defaultClickdBaseUrl = 'https://go-mtracker.ja0.com';
  static const String defaultAdBaseUrl = 'https://ad-mtracker.ja0.com';
  static const String defaultAppOpsBaseUrl = 'https://api-mtracker.ja0.com';

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

  /// Native ad request base host (adserver): `POST {adBaseUrl}/v1/ad`. Used by the
  /// pure-Dart desktop (Windows/macOS/Linux) ad path — mobile uses the native core.
  final String adBaseUrl;

  /// App Ops delivery host (api): `GET {appOpsBaseUrl}/v1/appops`. On desktop the
  /// SDK polls this itself (there is no native core) to draw update/review prompts.
  final String appOpsBaseUrl;

  /// Desktop only (no-op on mobile, where the native core owns App Ops). When true
  /// (default) the SDK fetches App Ops on init and draws the update prompt + review
  /// request itself. Requires [Ja0Tracker.navigatorKey] to be attached to the app's
  /// `MaterialApp(navigatorKey: ...)` so the SDK has a context to show dialogs.
  final bool enableDesktopAppOps;

  /// Optional app version (e.g. "1.2.0") reported to App Ops for the update check.
  /// When null the SDK reads it from the platform via `package_info_plus`.
  final String? appVersion;

  /// When true (default), the SDK auto-registers the app's FCM push token on init via
  /// `firebase_messaging` — you do NOT need to call [Ja0Tracker.setPushToken] yourself.
  /// Requires the host app to have Firebase set up (`Firebase.initializeApp()` before
  /// `initialize`). It is a no-op if Firebase isn't configured. Set false to register
  /// push manually (or to opt out of push entirely).
  final bool autoRegisterPush;
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

/// Ads accessor, reached via `Ja0Tracker.instance.ads` (docs/ads.md).
class MTAds {
  MTAds._(this._host, this._owner);
  final Ja0TrackerHostApi _host;
  final Ja0Tracker _owner;

  /// Load a native ad by slot ID. Resolves null on no-fill (docs/ads.md §3, §4).
  ///
  /// On desktop (Windows/macOS/Linux) there is no native ad core, so the ad is
  /// fetched directly from the adserver over HTTP (pure Dart); a click lands on
  /// the house campaign's web URL via clickd.
  Future<NativeAd?> load(String slotId) async {
    if (_owner._isDesktop) {
      return _owner._loadAdOverHttp(slotId);
    }
    try {
      final msg = await _host.loadAd(slotId);
      if (msg == null) return null;
      return _mapAd(msg);
    } catch (_) {
      return null;
    }
  }
}

class Ja0Tracker {
  Ja0Tracker._() {
    // Register a handler to receive native -> Dart callbacks. Pigeon's
    // Ja0TrackerFlutterApi is an interface with `onAttribution(AttributionMessage)` /
    // `onDeepLink(DeepLinkMessage)`; those method names collide with the public
    // `onAttribution(cb)` / `onDeepLink(cb)` registration API, so the interface is
    // implemented by a separate [_FlutterApiHandler] that forwards into this facade.
    Ja0TrackerFlutterApi.setUp(_FlutterApiHandler(this));
    ads = MTAds._(_host, this);
  }

  static final Ja0Tracker instance = Ja0Tracker._();

  /// Attach this to your `MaterialApp(navigatorKey: Ja0Tracker.navigatorKey)` so
  /// the SDK can draw its own dialogs (desktop update prompt / review request)
  /// without host UI code. Optional — when absent the SDK forwards to the
  /// [onUpdateAvailable] / [onMessage] callbacks instead.
  static final GlobalKey<NavigatorState> navigatorKey =
      GlobalKey<NavigatorState>();

  final Ja0TrackerHostApi _host = Ja0TrackerHostApi();
  late final MTAds ads;

  /// True on desktop (Flutter Windows/macOS/Linux), where there is no native core
  /// and ads / App Ops run in pure Dart. Web is not supported (this SDK uses
  /// dart:io); it reports false there.
  bool get _isDesktop =>
      !kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux);

  AttributionCallback? _attributionCallback;
  DeepLinkCallback? _deepLinkCallback;
  AttributionData? _pendingAttribution;
  DeepLinkData? _pendingDeepLink;

  UpdateCallback? _updateCallback;
  MessageCallback? _messageCallback;
  UpdateInfo? _pendingUpdate;
  final List<AppMessage> _pendingMessages = <AppMessage>[];

  /// Initialize once at app start.
  Future<void> initialize(Ja0TrackerConfig config) async {
    // Capture config up front so the pure-Dart desktop paths (ads / App Ops) keep
    // working even when the native bridge is unavailable — on desktop there is no
    // native core, so _host.initialize below throws MissingPluginException.
    _sdkKey = config.sdkKey;
    _appId = config.appId;
    _adBaseUrl = config.adBaseUrl;
    _appOpsBaseUrl = config.appOpsBaseUrl;
    _configAppVersion = config.appVersion;
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
      if (config.autoRegisterPush) {
        // Fire-and-forget: must never block or throw into initialize().
        unawaited(_autoRegisterPush());
      }
    } catch (e, s) {
      _swallow(e, s);
    }
    // Desktop (Windows/macOS/Linux): no native core, so poll App Ops and draw the
    // update prompt + review request ourselves in pure Dart.
    if (_isDesktop && config.enableDesktopAppOps) {
      unawaited(_runDesktopAppOps());
    }
  }

  /// Auto-registers the app's FCM/APNs push token so the console can send pushes
  /// without any per-app push code. Uses the host app's Firebase Messaging; silently
  /// skips if Firebase isn't set up. Re-registers on token refresh.
  Future<void> _autoRegisterPush() async {
    try {
      final fm = FirebaseMessaging.instance;
      await setPushConsent(true);
      // iOS returns a token only after notification permission is granted; request it
      // up front so a token exists (Android grants silently — effectively a no-op there).
      await fm.requestPermission();
      final token = await fm.getToken();
      if (token != null && token.isNotEmpty) {
        await setPushToken(token);
        debugPrint('[ja0] push token auto-registered (len=${token.length})');
      } else {
        debugPrint('[ja0] push auto-register: FCM token is null — '
            'iOS needs notification permission granted; Android needs google-services.json + valid FCM setup.');
      }
      fm.onTokenRefresh.listen((t) {
        setPushToken(t);
        debugPrint('[ja0] push token refreshed');
      });
      // Show ja0 pushes even while the app is in the foreground (the OS only
      // auto-draws them in background/terminated state).
      await _setupForegroundDisplay(fm);
    } catch (e) {
      // Firebase not configured in the host app (or push unavailable). The host can still
      // register manually via setPushToken(); we log so this is diagnosable, not silent.
      debugPrint('[ja0] push auto-register skipped: $e — '
          'is Firebase.initializeApp() awaited BEFORE Ja0Tracker.initialize()?');
    }
  }

  final FlutterLocalNotificationsPlugin _localNotifications =
      FlutterLocalNotificationsPlugin();
  bool _androidDisplayReady = false;

  /// SDK public key (captured at initialize) for the unauthenticated push-click
  /// beacon. The App Ops / api host the beacon is sent to.
  String? _sdkKey;
  static const String _apiBaseUrl = 'https://api-mtracker.ja0.com';

  /// Config captured at initialize for the pure-Dart desktop paths.
  String? _appId;
  String _adBaseUrl = Ja0TrackerConfig.defaultAdBaseUrl;
  String _appOpsBaseUrl = Ja0TrackerConfig.defaultAppOpsBaseUrl;
  String? _configAppVersion;

  /// Makes ja0-sent pushes visible while the app is in the foreground. iOS shows
  /// the banner natively via presentation options; Android has no such behavior
  /// for FCM notification messages, so we render a local notification. Only
  /// messages tagged source=mtracker are drawn — the host app owns its own.
  Future<void> _setupForegroundDisplay(FirebaseMessaging fm) async {
    try {
      await fm.setForegroundNotificationPresentationOptions(
          alert: true, badge: true, sound: true);

      if (Platform.isAndroid && !_androidDisplayReady) {
        const channel = AndroidNotificationChannel(
          'ja0_default',
          'Notifications',
          importance: Importance.high,
        );
        final android =
            _localNotifications.resolvePlatformSpecificImplementation<
                AndroidFlutterLocalNotificationsPlugin>();
        await android?.createNotificationChannel(channel);
        await _localNotifications.initialize(const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        ));
        _androidDisplayReady = true;
      }

      FirebaseMessaging.onMessage.listen((RemoteMessage m) {
        if (m.data['source'] != 'mtracker') return; // host app owns its own pushes
        final n = m.notification;
        if (n == null) return;
        if (Platform.isAndroid) {
          _localNotifications.show(
            n.hashCode,
            n.title,
            n.body,
            const NotificationDetails(
              android: AndroidNotificationDetails(
                'ja0_default',
                'Notifications',
                importance: Importance.high,
                priority: Priority.high,
              ),
            ),
          );
        }
        // iOS: setForegroundNotificationPresentationOptions already shows it.
      });

      // Report taps on ja0 pushes (background tap + cold-start tap) for the
      // console's click report.
      FirebaseMessaging.onMessageOpenedApp.listen(_reportPushClick);
      final initial = await FirebaseMessaging.instance.getInitialMessage();
      if (initial != null) _reportPushClick(initial);
    } catch (e) {
      debugPrint('[ja0] foreground push display setup skipped: $e');
    }
  }

  /// Reports a tap on a ja0-sent push (source=mtracker) to the console's click
  /// report. Best-effort, unauthenticated beacon (a click count is low-stakes).
  Future<void> _reportPushClick(RemoteMessage m) async {
    try {
      if (m.data['source'] != 'mtracker') return;
      final campaignId = m.data['campaign_id'];
      final key = _sdkKey;
      if (campaignId == null || campaignId.isEmpty || key == null) return;
      final client = HttpClient();
      final req = await client.postUrl(Uri.parse('$_apiBaseUrl/v1/push/click'));
      req.headers.contentType = ContentType.json;
      req.add(utf8.encode(jsonEncode({'sdk_key': key, 'campaign_id': campaignId})));
      final resp = await req.close();
      await resp.drain<void>();
      client.close();
      debugPrint('[ja0] push click reported ($campaignId)');
    } catch (_) {/* beacon is best-effort */}
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
    // Review prompts are handled natively by the SDK: trigger the OS in-app
    // review (App Store / Play In-App Review) instead of forwarding to the host
    // app, so a proper "leave a review" flow always shows (not just a dialog).
    if (model.type == AppMessageType.review) {
      unawaited(_requestReview(model));
      return;
    }
    final cb = _messageCallback;
    if (cb != null) {
      cb(model);
    } else {
      _pendingMessages.add(model);
    }
  }

  /// Shows the native in-app review flow (App Store / Play In-App Review). Falls
  /// back to opening the store listing when the in-app flow is unavailable
  /// (quota, unsupported OS). Best-effort — never throws into the host app.
  Future<void> _requestReview(AppMessage msg) async {
    try {
      final review = InAppReview.instance;
      if (await review.isAvailable()) {
        await review.requestReview();
      } else if (msg.ctaUrl != null && msg.ctaUrl!.isNotEmpty) {
        await review.openStoreListing();
      }
    } catch (e) {
      debugPrint('[ja0] review request skipped: $e');
    }
  }

  // ==========================================================================
  // Desktop (Windows/macOS/Linux) pure-Dart paths. There is no native core on
  // desktop, so ads, the app-update prompt and the review request are all
  // implemented here in Dart. Nothing below runs on mobile (guarded by
  // [_isDesktop]).
  // ==========================================================================

  /// Fetches App Ops on desktop and draws the update prompt + review request
  /// itself (announcements/custom go to the host [onMessage] handler).
  Future<void> _runDesktopAppOps() async {
    try {
      final appId = _appId;
      if (appId == null || appId.isEmpty) return;
      final version = await _resolveAppVersion();
      final uri = Uri.parse('$_appOpsBaseUrl/v1/appops').replace(queryParameters: {
        'app_id': appId,
        'platform': _desktopPlatformName(),
        'lang': _deviceLang(),
        if (version != null && version.isNotEmpty) 'app_version': version,
      });
      final data = await _httpGetJson(uri);
      if (data == null) return;

      // New version released → draw the update dialog (CTA opens the download URL).
      final upd = data['update'];
      if (upd is Map && upd['available'] == true) {
        await _showDesktopUpdateDialog(
          title: upd['title'] as String?,
          body: upd['body'] as String?,
          ctaText: upd['cta_text'] as String?,
          storeUrl: upd['store_url'] as String?,
          force: upd['force'] == true,
        );
      }

      final msgs = data['messages'];
      if (msgs is List) {
        for (final m in msgs) {
          if (m is! Map) continue;
          final type = m['type'] as String?;
          if (type == 'review') {
            await _showDesktopReviewDialog(
              title: m['title'] as String?,
              body: m['body'] as String?,
              ctaText: m['cta_text'] as String?,
              ctaUrl: m['cta_url'] as String?,
            );
          } else {
            // announcement / custom: hand to the host's onMessage handler.
            final model = AppMessage(
              id: (m['id'] as String?) ?? '',
              type: _parseMessageType(type ?? 'announcement'),
              priority: (m['priority'] as num?)?.toInt() ?? 0,
              title: m['title'] as String?,
              body: m['body'] as String?,
              ctaText: m['cta_text'] as String?,
              ctaUrl: m['cta_url'] as String?,
              imageUrl: m['image_url'] as String?,
              force: m['force'] == true,
              minSessionSec: (m['min_session_sec'] as num?)?.toInt() ?? 0,
              frequency: _parseFrequency((m['frequency'] as String?) ?? 'always'),
            );
            final cb = _messageCallback;
            if (cb != null) {
              cb(model);
            } else {
              _pendingMessages.add(model);
            }
          }
        }
      }
    } catch (e) {
      debugPrint('[ja0] desktop app-ops skipped: $e');
    }
  }

  /// Requests an ad from the adserver over HTTP (desktop). Returns null on no-fill.
  Future<NativeAd?> _loadAdOverHttp(String slotId) async {
    final appId = _appId;
    if (appId == null || appId.isEmpty) return null;
    final data = await _httpPostJson(Uri.parse('$_adBaseUrl/v1/ad'), {
      'slot_key': slotId,
      'slot_id': slotId, // the adserver resolves a non-UUID slot_id as a slot key
      'app_id': appId,
      'user': _adUser(),
      'platform': _desktopPlatformName(),
      'lang': _deviceLang(),
    });
    if (data == null) return null;
    return _adFromJson(slotId, data);
  }

  /// Parses an adserver /v1/ad response into a [NativeAd].
  NativeAd? _adFromJson(String slotId, Map<String, dynamic> m) {
    try {
      final assets = (m['assets'] as Map?)?.cast<String, dynamic>() ?? const {};
      final tracking = (m['tracking'] as Map?)?.cast<String, dynamic>() ?? const {};
      NativeAdMedia? media;
      final mediaRaw = assets['media'];
      if (mediaRaw is Map) {
        final url = mediaRaw['url'] as String?;
        if (url != null && url.isNotEmpty) {
          media = NativeAdMedia(
            type: mediaRaw['type'] == 'video'
                ? NativeAdMediaType.video
                : NativeAdMediaType.image,
            url: url,
          );
        }
      }
      final vt = (tracking['viewableThreshold'] as Map?)?.cast<String, dynamic>();
      return NativeAd(
        slotId: (m['slotId'] as String?) ?? slotId,
        adId: (m['adId'] as String?) ?? '',
        format: (m['format'] as String?) ?? 'native',
        headline: assets['headline'] as String?,
        body: assets['body'] as String?,
        advertiser: assets['advertiser'] as String?,
        cta: assets['cta'] as String?,
        iconUrl: assets['icon'] as String?,
        media: media,
        rating: (assets['rating'] as num?)?.toDouble(),
        impressionUrls: <String>[
          for (final u in (tracking['impression'] as List? ?? const []))
            if (u is String) u,
        ],
        clickUrl: (tracking['click'] as String?) ?? '',
        viewablePixels: (vt?['pixels'] as num?)?.toDouble() ?? 0.5,
        viewableMs: (vt?['ms'] as num?)?.toInt() ?? 1000,
      );
    } catch (_) {
      return null;
    }
  }

  /// Fires the viewability-gated impression beacons for a desktop-rendered ad.
  void _fireImpressions(NativeAd ad) {
    for (final u in ad.impressionUrls) {
      if (u.isNotEmpty) unawaited(_fireBeacon(u));
    }
  }

  /// Opens an external URL (ad landing / update download / review page) in the
  /// system browser. Best-effort — never throws into the host app.
  Future<void> _openUrl(String url) async {
    try {
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } catch (e) {
      debugPrint('[ja0] open url failed: $e');
    }
  }

  // ---- desktop dialogs (drawn by the SDK via [navigatorKey]) ----

  Future<void> _showDesktopUpdateDialog({
    String? title,
    String? body,
    String? ctaText,
    String? storeUrl,
    bool force = false,
  }) async {
    // A host override (onUpdateAvailable) takes precedence — it draws its own UI.
    final cb = _updateCallback;
    if (cb != null) {
      cb(UpdateInfo(
          available: true, force: force, storeUrl: storeUrl, title: title, body: body));
      return;
    }
    final ctx = await _awaitNavigatorContext();
    if (ctx == null) return;
    final isKo = _deviceLang() == 'ko';
    await showDialog<void>(
      context: ctx,
      barrierDismissible: !force,
      builder: (dc) => PopScope(
        canPop: !force,
        child: AlertDialog(
          title: Text(title ?? (isKo ? '업데이트 안내' : 'Update Available')),
          content: Text(body ??
              (isKo
                  ? '새로운 버전이 출시되었습니다. 지금 업데이트해 주세요.'
                  : 'A new version is available. Please update now.')),
          actions: [
            if (!force)
              TextButton(
                onPressed: () => Navigator.of(dc).pop(),
                child: Text(isKo ? '나중에' : 'Later'),
              ),
            FilledButton(
              onPressed: () {
                Navigator.of(dc).pop();
                if (storeUrl != null && storeUrl.isNotEmpty) _openUrl(storeUrl);
              },
              child: Text(ctaText ?? (isKo ? '업데이트' : 'Update')),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showDesktopReviewDialog({
    String? title,
    String? body,
    String? ctaText,
    String? ctaUrl,
  }) async {
    final ctx = await _awaitNavigatorContext();
    if (ctx == null) return;
    final isKo = _deviceLang() == 'ko';
    await showDialog<void>(
      context: ctx,
      builder: (dc) => AlertDialog(
        title: Text(title ?? (isKo ? '리뷰를 남겨주세요' : 'Enjoying the app?')),
        content: Text(body ??
            (isKo
                ? '앱이 마음에 드셨다면 리뷰를 남겨주세요. 큰 힘이 됩니다.'
                : 'If you like the app, please leave us a review.')),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dc).pop(),
            child: Text(isKo ? '닫기' : 'Not now'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.of(dc).pop();
              if (ctaUrl != null && ctaUrl.isNotEmpty) _openUrl(ctaUrl);
            },
            child: Text(ctaText ?? (isKo ? '리뷰 남기기' : 'Leave a review')),
          ),
        ],
      ),
    );
  }

  /// Waits (up to ~10s) for the app's navigator to mount so the SDK can show a
  /// dialog right after startup. Returns null if [navigatorKey] was never attached.
  Future<BuildContext?> _awaitNavigatorContext() async {
    for (var i = 0; i < 20; i++) {
      final ctx = navigatorKey.currentContext;
      if (ctx != null) return ctx;
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    debugPrint('[ja0] navigatorKey not attached — '
        'pass MaterialApp(navigatorKey: Ja0Tracker.navigatorKey) to show SDK dialogs.');
    return null;
  }

  // ---- desktop helpers (HTTP / platform) ----

  String? _adUserId;
  String _adUser() =>
      _adUserId ??= 'desktop-${DateTime.now().microsecondsSinceEpoch}';

  Future<String?> _resolveAppVersion() async {
    final override = _configAppVersion;
    if (override != null && override.isNotEmpty) return override;
    try {
      final info = await PackageInfo.fromPlatform();
      return info.version;
    } catch (_) {
      return null;
    }
  }

  String _desktopPlatformName() {
    if (Platform.isWindows) return 'windows';
    if (Platform.isMacOS) return 'macos';
    if (Platform.isLinux) return 'linux';
    return 'web';
  }

  String _deviceLang() {
    try {
      return Platform.localeName.split(RegExp(r'[_.\-]')).first.toLowerCase();
    } catch (_) {
      return '';
    }
  }

  Future<Map<String, dynamic>?> _httpGetJson(Uri uri) async {
    HttpClient? client;
    try {
      client = HttpClient();
      final resp = await (await client.getUrl(uri)).close();
      if (resp.statusCode != 200) {
        await resp.drain<void>();
        return null;
      }
      final text = await resp.transform(utf8.decoder).join();
      final decoded = jsonDecode(text);
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      return null;
    } finally {
      client?.close();
    }
  }

  Future<Map<String, dynamic>?> _httpPostJson(
      Uri uri, Map<String, dynamic> body) async {
    HttpClient? client;
    try {
      client = HttpClient();
      final req = await client.postUrl(uri);
      req.headers.contentType = ContentType.json;
      req.add(utf8.encode(jsonEncode(body)));
      final resp = await req.close();
      if (resp.statusCode != 200) {
        await resp.drain<void>(); // 204 = no-fill, or an error
        return null;
      }
      final text = await resp.transform(utf8.decoder).join();
      final decoded = jsonDecode(text);
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      return null;
    } finally {
      client?.close();
    }
  }

  Future<void> _fireBeacon(String url) async {
    HttpClient? client;
    try {
      client = HttpClient();
      final resp = await (await client.getUrl(Uri.parse(url))).close();
      await resp.drain<void>();
    } catch (_) {
      /* best-effort */
    } finally {
      client?.close();
    }
  }

  void _swallow(Object e, StackTrace s) {
    // SDK failures must never crash the host app (docs/sdk.md §5).
    if (kDebugMode) {
      debugPrint('[mtracker] swallowed error: $e');
    }
  }
}

/// Implements the Pigeon-generated [Ja0TrackerFlutterApi] (native -> Dart) and forwards
/// each callback into the [Ja0Tracker] facade. Kept separate from [Ja0Tracker] because the
/// interface method names (`onAttribution`/`onDeepLink`) collide with the facade's
/// public callback-registration methods of the same name.
class _FlutterApiHandler implements Ja0TrackerFlutterApi {
  _FlutterApiHandler(this._owner);
  final Ja0Tracker _owner;

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
    this.onAdImpression,
  });

  final String slotId;

  /// Use the SDK's built-in template (true) vs. app-custom rendering (false).
  final bool useDefaultTemplate;

  /// Fired when the user taps the ad.
  final void Function(String adId)? onAdClicked;

  /// Fired once when the viewability-gated impression beacon fires.
  final void Function(String adId)? onAdImpression;

  static const String _viewType = 'io.ja0tracker/native_ad_view';

  /// Wires a per-view MethodChannel so the native ad view can surface
  /// impression/click events to Dart (the native Core owns the actual tracking).
  void _onPlatformViewCreated(int id) {
    final channel = MethodChannel('io.ja0tracker/native_ad_view_$id');
    channel.setMethodCallHandler((call) async {
      final args = call.arguments;
      final adId = (args is Map) ? (args['adId'] as String? ?? '') : '';
      switch (call.method) {
        case 'onAdClicked':
          onAdClicked?.call(adId);
          break;
        case 'onAdImpression':
          onAdImpression?.call(adId);
          break;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final creationParams = <String, Object?>{
      'slotId': slotId,
      'useDefaultTemplate': useDefaultTemplate,
    };

    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return AndroidView(
          viewType: _viewType,
          creationParams: creationParams,
          creationParamsCodec: const StandardMessageCodec(),
          onPlatformViewCreated: _onPlatformViewCreated,
        );
      case TargetPlatform.iOS:
        return UiKitView(
          viewType: _viewType,
          creationParams: creationParams,
          creationParamsCodec: const StandardMessageCodec(),
          onPlatformViewCreated: _onPlatformViewCreated,
        );
      default:
        // Desktop (Windows/macOS/Linux) and other non-mobile targets have no
        // native ad view — render + track the ad in pure Dart. A click lands on
        // the house campaign's web URL (via clickd).
        return _Ja0DartNativeAd(
          slotId: slotId,
          onAdClicked: onAdClicked,
          onAdImpression: onAdImpression,
        );
    }
  }
}

/// Pure-Dart native-ad renderer for desktop (Windows/macOS/Linux), where there is
/// no native ad view. Fetches the ad via [Ja0Tracker.instance.ads], renders a
/// simple card, fires impression beacons on display, and opens the (web) landing
/// through clickd on tap.
class _Ja0DartNativeAd extends StatefulWidget {
  const _Ja0DartNativeAd({
    required this.slotId,
    this.onAdClicked,
    this.onAdImpression,
  });

  final String slotId;
  final void Function(String adId)? onAdClicked;
  final void Function(String adId)? onAdImpression;

  @override
  State<_Ja0DartNativeAd> createState() => _Ja0DartNativeAdState();
}

class _Ja0DartNativeAdState extends State<_Ja0DartNativeAd> {
  NativeAd? _ad;
  bool _impressionSent = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final ad = await Ja0Tracker.instance.ads.load(widget.slotId);
    if (!mounted) return;
    setState(() => _ad = ad);
    if (ad != null && !_impressionSent) {
      _impressionSent = true;
      Ja0Tracker.instance._fireImpressions(ad);
      widget.onAdImpression?.call(ad.adId);
    }
  }

  void _onTap() {
    final ad = _ad;
    if (ad == null) return;
    if (ad.clickUrl.isNotEmpty) Ja0Tracker.instance._openUrl(ad.clickUrl);
    widget.onAdClicked?.call(ad.adId);
  }

  @override
  Widget build(BuildContext context) {
    final ad = _ad;
    if (ad == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return InkWell(
      onTap: _onTap,
      child: Card(
        clipBehavior: Clip.antiAlias,
        margin: EdgeInsets.zero,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (ad.media != null && ad.media!.type == NativeAdMediaType.image)
              Image.network(
                ad.media!.url,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => const SizedBox.shrink(),
              ),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  if (ad.iconUrl != null && ad.iconUrl!.isNotEmpty) ...[
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Image.network(
                        ad.iconUrl!,
                        width: 44,
                        height: 44,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) =>
                            const SizedBox(width: 44, height: 44),
                      ),
                    ),
                    const SizedBox(width: 12),
                  ],
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (ad.headline != null && ad.headline!.isNotEmpty)
                          Text(ad.headline!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.titleSmall
                                  ?.copyWith(fontWeight: FontWeight.w600)),
                        if (ad.body != null && ad.body!.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text(ad.body!,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodySmall),
                          ),
                        if (ad.advertiser != null && ad.advertiser!.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Text(ad.advertiser!,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.labelSmall
                                    ?.copyWith(color: theme.hintColor)),
                          ),
                      ],
                    ),
                  ),
                  if (ad.cta != null && ad.cta!.isNotEmpty) ...[
                    const SizedBox(width: 8),
                    FilledButton(onPressed: _onTap, child: Text(ad.cta!)),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

package io.ja0tracker.flutter

import android.content.Context
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.BinaryMessenger
import io.ja0tracker.sdk.AppMessage
import io.ja0tracker.sdk.Consent
import io.ja0tracker.sdk.LogLevel
import io.ja0tracker.sdk.Ja0Tracker
import io.ja0tracker.sdk.Ja0TrackerConfig
import io.ja0tracker.sdk.TrackingConsentStatus
import io.ja0tracker.sdk.UpdateInfo
import io.ja0tracker.sdk.ads.NativeAd
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

/**
 * mtracker Flutter plugin (Android).
 *
 * Implements the Pigeon [Ja0TrackerHostApi] by DELEGATING to the shared Android Core
 * (`io.ja0tracker.sdk.Ja0Tracker`) — HMAC signing, the event queue, attribution, sessions and
 * ad rendering all live in the Core. Native -> Dart callbacks (`onAttribution` /
 * `onDeepLink`) are pushed through the generated [Ja0TrackerFlutterApi]. Registers the
 * [MTNativeAdViewFactory] PlatformView for `MTNativeAd`.
 */
class Ja0TrackerPlugin : FlutterPlugin, Ja0TrackerHostApi, ActivityAware {

    private var applicationContext: Context? = null
    private var flutterApi: Ja0TrackerFlutterApi? = null
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private var callbacksWired = false

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        applicationContext = binding.applicationContext
        val messenger: BinaryMessenger = binding.binaryMessenger

        Ja0TrackerHostApi.setUp(messenger, this)
        flutterApi = Ja0TrackerFlutterApi(messenger)

        // Register the native ad PlatformView (docs/ads.md §6). The factory wraps the Core's
        // io.ja0tracker.sdk.ads.MTNativeAdView.
        binding.platformViewRegistry.registerViewFactory(
            MTNativeAdViewFactory.VIEW_TYPE,
            MTNativeAdViewFactory(messenger),
        )
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        Ja0TrackerHostApi.setUp(binding.binaryMessenger, null)
        flutterApi = null
        applicationContext = null
    }

    // ---- Ja0TrackerHostApi (Dart -> native): delegate to the Core ----

    override fun initialize(config: ConfigMessage) {
        val context = applicationContext ?: return
        // sdkKey / sdkSecret / appId are all required by the Core (contract §5); bail if any
        // is missing rather than letting the Core throw on its require(...) guards.
        val sdkSecret = config.sdkSecret ?: return
        val appId = config.appId ?: return
        val core = Ja0TrackerConfig(
            sdkKey = config.sdkKey,
            sdkSecret = sdkSecret,
            appId = appId,
            logLevel = parseLogLevel(config.logLevel),
            waitForConsent = config.waitForConsent ?: true,
            ingestBaseUrl = config.ingestBaseUrl ?: Ja0TrackerConfig.DEFAULT_INGEST_BASE_URL,
            clickdBaseUrl = config.clickdBaseUrl ?: Ja0TrackerConfig.DEFAULT_CLICKD_BASE_URL,
        )
        Ja0Tracker.initialize(context, core)
        wireCallbacksOnce()
    }

    override fun requestTrackingConsent(callback: (Result<String>) -> Unit) {
        scope.launch {
            try {
                val status = Ja0Tracker.requestTrackingConsent()
                callback(Result.success(status.toWire()))
            } catch (t: Throwable) {
                callback(Result.success(TrackingConsentStatus.NOT_DETERMINED.toWire()))
            }
        }
    }

    override fun setConsent(consent: ConsentMessage) {
        Ja0Tracker.setConsent(
            Consent(
                analytics = consent.analytics,
                attribution = consent.attribution,
                ads = consent.ads,
            )
        )
    }

    override fun trackEvent(name: String, params: Map<String?, Any?>) {
        @Suppress("UNCHECKED_CAST")
        Ja0Tracker.trackEvent(name, params.filterKeys { it != null } as Map<String, Any?>)
    }

    override fun loadAd(slotId: String, callback: (Result<NativeAdMessage?>) -> Unit) {
        scope.launch {
            try {
                // Pass the device language so the adserver serves localized (house-ad)
                // copy — the prebuilt core forwards context.lang to the request.
                val ad = Ja0Tracker.ads.load(
                    slotId,
                    context = mapOf("lang" to java.util.Locale.getDefault().language),
                )
                callback(Result.success(ad?.toMessage()))
            } catch (t: Throwable) {
                callback(Result.success(null)) // no-fill on error
            }
        }
    }

    // ---- App Ops (docs/appops-contract.md §5) ----

    override fun getConfigJson(key: String, callback: (Result<String?>) -> Unit) {
        callback(Result.success(Ja0Tracker.getConfigJson(key)))
    }

    override fun setPushConsent(granted: Boolean) {
        Ja0Tracker.setPushConsent(granted)
    }

    override fun setPushToken(token: String) {
        Ja0Tracker.setPushToken(token)
    }

    // ---- Native -> Dart callbacks ----

    private fun wireCallbacksOnce() {
        if (callbacksWired) return
        callbacksWired = true
        Ja0Tracker.onAttribution { data -> flutterApi?.onAttribution(data.toMessage()) {} }
        Ja0Tracker.onDeepLink { link -> flutterApi?.onDeepLink(link.toMessage()) {} }
        // App update: leave the Core's onUpdateAvailable unset so the SDK draws the
        // native update dialog itself (no host-app code needed).
        // Messages (incl. review) are forwarded to Dart: review triggers the native
        // in-app review; other messages reach the host onMessage handler.
        Ja0Tracker.onMessage { msg, markShown ->
            flutterApi?.onMessage(msg.toMessage()) {}
            markShown()
        }
    }

    // ActivityAware: the host Activity is where inbound deep-link intents arrive; forward
    // them to the Core so live/deferred links are delivered.
    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        // TODO(host): to route live App Links, call Ja0Tracker.handleDeepLink(intent) from the
        // Activity's onNewIntent. The plugin cannot intercept that without an intent listener
        // wired by the host; documented in android/README.md.
    }

    override fun onDetachedFromActivityForConfigChanges() {}
    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {}
    override fun onDetachedFromActivity() {}

    private fun parseLogLevel(value: String?): LogLevel = when (value) {
        "none" -> LogLevel.NONE
        "error" -> LogLevel.ERROR
        "warn" -> LogLevel.WARN
        "debug" -> LogLevel.DEBUG
        else -> LogLevel.INFO
    }
}

// ---- Core model -> Pigeon message mappers ----

private fun TrackingConsentStatus.toWire(): String = when (this) {
    TrackingConsentStatus.GRANTED -> "granted"
    TrackingConsentStatus.DENIED -> "denied"
    TrackingConsentStatus.RESTRICTED -> "restricted"
    TrackingConsentStatus.NOT_DETERMINED -> "notDetermined"
}

private fun io.ja0tracker.sdk.AttributionData.toMessage(): AttributionMessage = AttributionMessage(
    source = source,
    campaign = campaign,
    network = network,
    clickId = clickId,
    confidence = confidence.name.lowercase(),
    confidenceScore = confidenceScore,
    // Widen to the Pigeon message's nullable key/value map type (Map key type is invariant
    // in Kotlin, so Map<String,String> is not assignable to Map<String?,String?> directly).
    raw = raw.toNullableMap(),
)

private fun io.ja0tracker.sdk.DeepLinkData.toMessage(): DeepLinkMessage = DeepLinkMessage(
    path = path,
    params = params.toNullableMap(),
    url = url,
    isDeferred = isDeferred,
)

private fun Map<String, String>.toNullableMap(): Map<String?, String?> =
    LinkedHashMap<String?, String?>(this)

private fun UpdateInfo.toMessage(): UpdateMessage = UpdateMessage(
    available = available,
    force = force,
    latestVersion = latestVersion,
    storeUrl = storeUrl,
    title = title,
    body = body,
)

private fun AppMessage.toMessage(): AppMessageMessage = AppMessageMessage(
    id = id,
    type = type.name.lowercase(),
    priority = priority.toLong(),
    title = title,
    body = body,
    ctaText = ctaText,
    ctaUrl = ctaUrl,
    imageUrl = imageUrl,
    force = force,
    minSessionSec = minSessionSec.toLong(),
    frequency = frequency.name.lowercase(),
)

private fun NativeAd.toMessage(): NativeAdMessage = NativeAdMessage(
    slotId = slotId,
    adId = adId,
    format = format,
    headline = assets.headline,
    body = assets.body,
    advertiser = assets.advertiser,
    cta = assets.cta,
    iconUrl = assets.iconUrl,
    media = assets.media?.let { NativeAdMediaMessage(type = it.type.name.lowercase(), url = it.url) },
    rating = assets.rating,
    impressionUrls = tracking.impressionUrls,
    clickUrl = tracking.clickUrl,
    viewablePixels = tracking.viewableThreshold.pixels,
    viewableMs = tracking.viewableThreshold.ms,
)

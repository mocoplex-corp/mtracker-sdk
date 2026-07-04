package io.ja0tracker.flutter

import android.content.Context
import android.view.View
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory
import io.ja0tracker.sdk.Ja0Tracker
import io.ja0tracker.sdk.ads.MTNativeAdView
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

/**
 * PlatformViewFactory for the `MTNativeAd` Flutter widget. Registered under
 * [VIEW_TYPE] (matching `_viewType` in lib/ja0tracker.dart). Each view wraps the Core's
 * [io.ja0tracker.sdk.ads.MTNativeAdView] — the Core owns rendering + impression/click
 * beacons (docs/ads.md §6); this factory requests the ad, hosts the Core view, and
 * forwards impression/click callbacks to Dart over a per-view MethodChannel.
 */
class MTNativeAdViewFactory(
    private val messenger: BinaryMessenger,
) : PlatformViewFactory(StandardMessageCodec.INSTANCE) {

    override fun create(context: Context, viewId: Int, args: Any?): PlatformView {
        @Suppress("UNCHECKED_CAST")
        val params = args as? Map<String, Any?> ?: emptyMap()
        val slotId = params["slotId"] as? String
        return MTNativeAdPlatformView(context, messenger, viewId, slotId)
    }

    companion object {
        const val VIEW_TYPE = "io.ja0tracker/native_ad_view"
    }
}

private class MTNativeAdPlatformView(
    context: Context,
    messenger: BinaryMessenger,
    viewId: Int,
    slotId: String?,
) : PlatformView {

    private val adView = MTNativeAdView(context)
    private val channel = MethodChannel(messenger, "io.ja0tracker/native_ad_view_$viewId")
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)

    init {
        if (!slotId.isNullOrEmpty()) {
            scope.launch {
                val ad = Ja0Tracker.ads.load(
                    slotId,
                    context = mapOf("lang" to java.util.Locale.getDefault().language),
                )
                if (ad != null) {
                    // Core beacons fire regardless; forward the events to Dart (main thread).
                    adView.onImpression = { channel.invokeMethod("onAdImpression", mapOf("adId" to ad.adId)) }
                    adView.onClick = { channel.invokeMethod("onAdClicked", mapOf("adId" to ad.adId)) }
                    adView.bind(ad)
                }
            }
        }
    }

    override fun getView(): View = adView

    override fun dispose() {
        // Core view has no explicit teardown; coroutine scope is short-lived.
    }
}

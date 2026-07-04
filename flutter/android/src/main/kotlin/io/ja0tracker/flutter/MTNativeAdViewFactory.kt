package io.ja0tracker.flutter

import android.content.Context
import android.view.View
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
 * [VIEW_TYPE] (matching `_viewType` in lib/mtracker.dart). Each view wraps the Core's
 * [io.ja0tracker.sdk.ads.MTNativeAdView] — the Core owns rendering + impression/click
 * beacons (docs/ads.md §6); this factory only requests the ad and hosts the Core view.
 */
class MTNativeAdViewFactory :
    PlatformViewFactory(StandardMessageCodec.INSTANCE) {

    override fun create(context: Context, viewId: Int, args: Any?): PlatformView {
        @Suppress("UNCHECKED_CAST")
        val params = args as? Map<String, Any?> ?: emptyMap()
        val slotId = params["slotId"] as? String
        return MTNativeAdPlatformView(context, slotId)
    }

    companion object {
        const val VIEW_TYPE = "io.ja0tracker/native_ad_view"
    }
}

private class MTNativeAdPlatformView(
    context: Context,
    slotId: String?,
) : PlatformView {

    private val adView = MTNativeAdView(context)
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)

    init {
        if (!slotId.isNullOrEmpty()) {
            scope.launch {
                val ad = Ja0Tracker.ads.load(slotId)
                if (ad != null) adView.bind(ad)
            }
        }
    }

    override fun getView(): View = adView

    override fun dispose() {
        // Core view has no explicit teardown; coroutine scope is short-lived.
    }
}

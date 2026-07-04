import Flutter
import UIKit
import MTracker

/// FlutterPlatformViewFactory for the `MTNativeAd` Flutter widget. Registered under
/// [viewType] (matching `_viewType` in lib/mtracker.dart). Each view wraps the Core's
/// `MTNativeAdView` — the Core owns rendering + impression/click beacons (docs/ads.md §6);
/// this factory only requests the ad and hosts the Core view.
class MTNativeAdViewFactory: NSObject, FlutterPlatformViewFactory {

    static let viewType = "io.mtracker/native_ad_view"

    private let messenger: FlutterBinaryMessenger

    init(messenger: FlutterBinaryMessenger) {
        self.messenger = messenger
        super.init()
    }

    func create(
        withFrame frame: CGRect,
        viewIdentifier viewId: Int64,
        arguments args: Any?
    ) -> FlutterPlatformView {
        let params = args as? [String: Any]
        let slotId = params?["slotId"] as? String
        return MTNativeAdPlatformView(frame: frame, slotId: slotId)
    }

    func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
        return FlutterStandardMessageCodec.sharedInstance()
    }
}

private class MTNativeAdPlatformView: NSObject, FlutterPlatformView {

    private let adView: MTNativeAdView

    init(frame: CGRect, slotId: String?) {
        self.adView = MTNativeAdView(frame: frame)
        super.init()
        if let slotId, !slotId.isEmpty {
            Task { @MainActor in
                if let ad = await MTracker.shared.ads.load(slotId) {
                    self.adView.bind(ad)
                }
            }
        }
    }

    func view() -> UIView {
        return adView
    }
}

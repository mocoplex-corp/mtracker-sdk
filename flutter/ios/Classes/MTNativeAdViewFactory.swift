import Flutter
import UIKit
import Ja0TrackerSDK

/// FlutterPlatformViewFactory for the `MTNativeAd` Flutter widget. Registered under
/// [viewType] (matching `_viewType` in lib/mtracker.dart). Each view wraps the Core's
/// `MTNativeAdView` — the Core owns rendering + impression/click beacons (docs/ads.md §6);
/// this factory only requests the ad and hosts the Core view.
class MTNativeAdViewFactory: NSObject, FlutterPlatformViewFactory {

    static let viewType = "io.ja0tracker/native_ad_view"

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
        return MTNativeAdPlatformView(frame: frame, viewId: viewId, messenger: messenger, slotId: slotId)
    }

    func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
        return FlutterStandardMessageCodec.sharedInstance()
    }
}

private class MTNativeAdPlatformView: NSObject, FlutterPlatformView {

    private let adView: MTNativeAdView
    private let channel: FlutterMethodChannel

    init(frame: CGRect, viewId: Int64, messenger: FlutterBinaryMessenger, slotId: String?) {
        self.adView = MTNativeAdView(frame: frame)
        self.channel = FlutterMethodChannel(
            name: "io.ja0tracker/native_ad_view_\(viewId)", binaryMessenger: messenger)
        super.init()
        if let slotId, !slotId.isEmpty {
            Task { @MainActor in
                if let ad = await Ja0Tracker.shared.ads.load(slotId) {
                    // Core beacons fire regardless; forward the events to Dart (main thread).
                    self.adView.onImpression = { [weak self] in
                        self?.channel.invokeMethod("onAdImpression", arguments: ["adId": ad.adId])
                    }
                    self.adView.onClick = { [weak self] in
                        self?.channel.invokeMethod("onAdClicked", arguments: ["adId": ad.adId])
                    }
                    self.adView.bind(ad)
                }
            }
        }
    }

    func view() -> UIView {
        return adView
    }
}

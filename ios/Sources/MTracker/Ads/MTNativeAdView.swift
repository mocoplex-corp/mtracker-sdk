import Foundation
#if canImport(AdAttributionKit)
import AdAttributionKit
#endif
#if canImport(UIKit)
import UIKit

/// UIView that renders a `NativeAd`'s assets and fires impression/click beacons.
///
/// Rendering contract (docs/ads.md §6): apps may render assets fully custom by reading
/// `NativeAd.assets` directly; this default view binds headline/body/icon/media/cta into
/// a simple vertical template for fast adoption. Regardless of who renders, the SDK owns
/// ONLY the viewability-gated impression beacons and click routing through clickd
/// (`go-mtracker.ja0.com/ad/...`), which joins the attribution pipeline — the ad→install
/// closed loop (docs/ads.md §4).
public final class MTNativeAdView: UIView {

    private var ad: NativeAd?
    private var impressionFired = false

    // Kept as Any so the SDK can retain an AppImpression while preserving its
    // iOS 15 deployment target; every cast/use is guarded by iOS 17.4 runtime
    // availability. View operations are serialized through a task chain.
    private var aakImpression: Any?
    private var aakViewActive = false
    private var aakTapInFlight = false
    private var aakViewTask: Task<Void, Never>?

    /// Fired once when the viewability-gated impression beacon fires (main thread).
    public var onImpression: (() -> Void)?

    /// Fired when the ad is tapped, alongside click routing to the store (main thread).
    public var onClick: (() -> Void)?

    /// Viewability tracking: the ad must be ≥ `pixels` fraction on-screen continuously
    /// for `ms` before the impression counts (docs/ads.md §4, §6).
    private var viewabilityTimer: Timer?
    private var visibilityMonitor: Timer?
    private var visibleSince: Date?

    private let beaconSession: URLSession = {
        let sc = URLSessionConfiguration.default
        sc.timeoutIntervalForRequest = 10
        return URLSession(configuration: sc)
    }()

    // Template subviews.
    private let iconView = UIImageView()
    private let headlineLabel = UILabel()
    private let bodyLabel = UILabel()
    private let advertiserLabel = UILabel()
    private let mediaView = UIImageView()
    private let ctaButton = UIButton(type: .system)
    private let stack = UIStackView()
    private let eventAttributionView = UIEventAttributionView()

    public override init(frame: CGRect) {
        super.init(frame: frame)
        setupTemplate()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupTemplate()
    }

    deinit {
        viewabilityTimer?.invalidate()
        visibilityMonitor?.invalidate()
    }

    // MARK: - Binding

    /// Binds an ad and populates the template. Loads remote icon/media asynchronously.
    /// Resets impression state so a reused view (cell recycling) re-qualifies.
    public func bind(_ ad: NativeAd) {
        endAAKViewIfNeeded()
        self.ad = ad
        self.impressionFired = false
        self.visibleSince = nil
        self.aakImpression = nil
        self.aakTapInFlight = false

        headlineLabel.text = ad.assets.headline
        bodyLabel.text = ad.assets.body
        advertiserLabel.text = ad.assets.advertiser
        ctaButton.setTitle(ad.assets.cta ?? "Learn more", for: .normal)

        iconView.isHidden = ad.assets.iconURL == nil
        mediaView.isHidden = ad.assets.media == nil

        if let iconURL = ad.assets.iconURL, let url = URL(string: iconURL) {
            loadImage(url, into: iconView)
        }
        if let media = ad.assets.media, media.type == .image, let url = URL(string: media.url) {
            loadImage(url, into: mediaView)
        }
        configureAAKImpression(for: ad)
        // Kick off viewability evaluation.
        evaluateViewability()
    }

    // MARK: - Template

    private func setupTemplate() {
        stack.axis = .vertical
        stack.spacing = 8
        stack.alignment = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])

        iconView.contentMode = .scaleAspectFit
        iconView.setContentHuggingPriority(.required, for: .vertical)
        NSLayoutConstraint.activate([
            iconView.heightAnchor.constraint(equalToConstant: 40),
        ])

        headlineLabel.font = .preferredFont(forTextStyle: .headline)
        headlineLabel.numberOfLines = 2
        bodyLabel.font = .preferredFont(forTextStyle: .subheadline)
        bodyLabel.numberOfLines = 3
        bodyLabel.textColor = .secondaryLabel
        advertiserLabel.font = .preferredFont(forTextStyle: .caption1)
        advertiserLabel.textColor = .tertiaryLabel

        mediaView.contentMode = .scaleAspectFill
        mediaView.clipsToBounds = true
        NSLayoutConstraint.activate([
            mediaView.heightAnchor.constraint(equalToConstant: 160),
        ])

        ctaButton.titleLabel?.font = .preferredFont(forTextStyle: .body)
        ctaButton.contentEdgeInsets = UIEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        ctaButton.addTarget(self, action: #selector(handleTap), for: .touchUpInside)

        [iconView, headlineLabel, advertiserLabel, bodyLabel, mediaView, ctaButton]
            .forEach { stack.addArrangedSubview($0) }

        // AdAttributionKit requires the user interaction to pass through a
        // UIEventAttributionView before handleTap(). The overlay doesn't consume
        // touches, so the button/card handlers below continue to receive them.
        eventAttributionView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(eventAttributionView)
        NSLayoutConstraint.activate([
            eventAttributionView.topAnchor.constraint(equalTo: topAnchor),
            eventAttributionView.leadingAnchor.constraint(equalTo: leadingAnchor),
            eventAttributionView.trailingAnchor.constraint(equalTo: trailingAnchor),
            eventAttributionView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        // Whole-card tap also routes the click (native ads are tappable everywhere).
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        addGestureRecognizer(tap)
        isUserInteractionEnabled = true
    }

    // MARK: - Viewability + impression

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            visibilityMonitor?.invalidate()
            visibilityMonitor = nil
        } else {
            startVisibilityMonitorIfNeeded()
        }
        evaluateViewability()
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        evaluateViewability()
    }

    /// Evaluates whether the view currently meets the viewability threshold; starts a
    /// timer that fires the impression once the threshold has been met continuously for
    /// the required duration.
    private func evaluateViewability() {
        guard let ad else {
            endAAKViewIfNeeded()
            return
        }
        let visibleFraction = onScreenFraction()
        let meets = visibleFraction >= ad.tracking.viewableThreshold.pixels

        if meets {
            beginAAKViewIfNeeded()
        } else {
            endAAKViewIfNeeded()
        }

        guard !impressionFired else { return }
        if meets {
            if visibleSince == nil { visibleSince = Date() }
            if viewabilityTimer == nil {
                let interval = Double(ad.tracking.viewableThreshold.ms) / 1000.0
                let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
                    self?.confirmImpression()
                }
                RunLoop.main.add(timer, forMode: .common)
                viewabilityTimer = timer
            }
        } else {
            // Fell below threshold before the dwell completed — reset.
            visibleSince = nil
            viewabilityTimer?.invalidate()
            viewabilityTimer = nil
        }
    }

    private func confirmImpression() {
        viewabilityTimer?.invalidate()
        viewabilityTimer = nil
        // Re-check we're still visible at fire time.
        guard let ad, !impressionFired,
              onScreenFraction() >= ad.tracking.viewableThreshold.pixels else {
            visibleSince = nil
            return
        }
        impressionFired = true
        for urlString in ad.tracking.impressionURLs {
            fireBeacon(urlString, method: "POST")
        }
        onImpression?()
    }

    /// Scrolling doesn't necessarily trigger layoutSubviews on a reused native
    /// ad view. Poll while attached so both the custom beacon timer and Apple's
    /// beginView/endView lifecycle observe ancestor clipping accurately.
    private func startVisibilityMonitorIfNeeded() {
        guard visibilityMonitor == nil, window != nil else { return }
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.evaluateViewability()
        }
        RunLoop.main.add(timer, forMode: .common)
        visibilityMonitor = timer
    }

    /// Fraction of this view's area currently visible within its window.
    private func onScreenFraction() -> Double {
        guard let window = window, !isHidden, alpha > 0.01, bounds.area > 0 else { return 0 }
        let inWindow = convert(bounds, to: window)
        var visibleRect = inWindow.intersection(window.bounds)
        var ancestor = superview
        while let view = ancestor, view !== window {
            if view.clipsToBounds {
                visibleRect = visibleRect.intersection(view.convert(view.bounds, to: window))
            }
            if visibleRect.isNull || visibleRect.isEmpty { return 0 }
            ancestor = view.superview
        }
        guard !visibleRect.isNull else { return 0 }
        return Double(visibleRect.area / inWindow.area)
    }

    // MARK: - Click

    @objc private func handleTap() {
        guard let ad else { return }
        onClick?()
        // GET the click beacon (clickd 302-redirects; joins attribution pipeline).
        guard let url = URL(string: ad.tracking.clickURL) else { return }
        fireBeacon(ad.tracking.clickURL, method: "GET")

        #if canImport(AdAttributionKit)
        if #available(iOS 17.4, *),
           let impression = aakImpression as? AppImpression,
           !aakTapInFlight {
            aakTapInFlight = true
            Task { [weak self] in
                do {
                    // AdAttributionKit records the click and opens the installed
                    // app or preferred marketplace using the signed item id.
                    try await impression.handleTap()
                } catch {
                    // Preserve legacy click routing if the system rejects the
                    // impression or the current device doesn't support it.
                    UIApplication.shared.open(url, options: [:], completionHandler: nil)
                }
                self?.aakTapInFlight = false
            }
            return
        }
        #endif

        // Open the click URL in the browser; clickd resolves the final destination
        // (store page / universal link) via its 302 redirect.
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
    }

    // MARK: - AdAttributionKit

    private func configureAAKImpression(for ad: NativeAd) {
        #if canImport(AdAttributionKit)
        guard #available(iOS 17.4, *),
              AppImpression.isSupported,
              let attribution = ad.attribution,
              attribution.provider.lowercased() == "adattributionkit" else { return }

        let adID = ad.adId
        Task { [weak self] in
            do {
                let impression = try await AppImpression(compactJWS: attribution.compactJWS)
                guard let self, self.ad?.adId == adID else { return }
                self.aakImpression = impression
                self.evaluateViewability()
            } catch {
                // Invalid/expired JWS must never break host rendering. The
                // existing click/impression beacons remain as the fallback.
            }
        }
        #endif
    }

    private func beginAAKViewIfNeeded() {
        #if canImport(AdAttributionKit)
        guard #available(iOS 17.4, *),
              let impression = aakImpression as? AppImpression,
              !aakViewActive else { return }

        aakViewActive = true
        let previous = aakViewTask
        aakViewTask = Task { [weak self] in
            _ = await previous?.result
            do {
                try await impression.beginView()
            } catch {
                if let current = self?.aakImpression as? AppImpression,
                   current == impression {
                    self?.aakViewActive = false
                }
            }
        }
        #endif
    }

    private func endAAKViewIfNeeded() {
        #if canImport(AdAttributionKit)
        guard #available(iOS 17.4, *),
              let impression = aakImpression as? AppImpression,
              aakViewActive else { return }

        aakViewActive = false
        let previous = aakViewTask
        aakViewTask = Task {
            _ = await previous?.result
            try? await impression.endView()
        }
        #endif
    }

    // MARK: - Beacons

    private func fireBeacon(_ urlString: String, method: String) {
        guard let url = URL(string: urlString) else { return }
        var req = URLRequest(url: url)
        req.httpMethod = method
        beaconSession.dataTask(with: req).resume()
    }

    private func loadImage(_ url: URL, into imageView: UIImageView) {
        beaconSession.dataTask(with: url) { data, _, _ in
            guard let data, let image = UIImage(data: data) else { return }
            DispatchQueue.main.async { imageView.image = image }
        }.resume()
    }
}

private extension CGRect {
    var area: CGFloat { width * height }
}
#endif

import XCTest
import CryptoKit
@testable import MTracker

final class MTrackerTests: XCTestCase {

    // MARK: - Config

    func testConfigDefaults() {
        let config = MTrackerConfig(sdkKey: "pk_ja0_demo", sdkSecret: "secret", appId: "app-1")
        XCTAssertEqual(config.ingestBaseURL, "https://ingest-mtracker.ja0.com")
        XCTAssertEqual(config.clickdBaseURL, "https://go-mtracker.ja0.com")
        XCTAssertTrue(config.waitForConsent)
        XCTAssertEqual(config.sdkKey, "pk_ja0_demo")
        XCTAssertEqual(config.appId, "app-1")
    }

    func testConsentDefaultsToPrivacyFirst() {
        let consent = Consent()
        XCTAssertFalse(consent.analytics)
        XCTAssertFalse(consent.attribution)
        XCTAssertFalse(consent.ads)
    }

    // MARK: - HMAC signing (byte-exact with backend authx.VerifyRequest)

    /// The signed message must be exactly `"{ts}." + body`, HMAC-SHA256 keyed by the
    /// secret, lowercase hex. This mirrors `pkg/authx/hmac.go` VerifyRequest. If this
    /// test's expectation ever diverges from the backend, live requests would 401.
    func testHMACSignatureMatchesContract() {
        let secret = "sk_ja0_demo_secret_change_me"
        let ts: Int64 = 1_700_000_000
        let body = Data(#"{"sdk_key":"pk_ja0_demo","platform":"ios","events":[]}"#.utf8)

        // Reference computation done the same way the Go server does it.
        var message = Data("\(ts).".utf8)
        message.append(body)
        let key = SymmetricKey(data: Data(secret.utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: message, using: key)
        let expected = mac.map { String(format: "%02x", $0) }.joined()

        let actual = HTTPClient.sign(secret: secret, timestamp: ts, body: body)
        XCTAssertEqual(actual, expected)
        XCTAssertEqual(actual.count, 64) // 32 bytes hex
        XCTAssertEqual(actual, actual.lowercased())
    }

    // MARK: - Batch encoding (contract §3 wire shape)

    func testBatchEnvelopeShape() throws {
        let config = MTrackerConfig(sdkKey: "pk_ja0_demo", sdkSecret: "s", appId: "app-1")
        let http = HTTPClient(config: config, logger: MTLogger(level: .none))

        let params = try JSONSerialization.data(withJSONObject: ["level": 5])
        let event = QueuedEvent(
            eventId: "01HZ_EVENT", appId: "app-1", installId: "01HZ_INSTALL",
            name: "purchase", ts: 1_700_000_000, sessionId: "sess-1",
            revenue: 99.0, currency: "KRW", paramsJSON: params
        )
        let data = try http.encodeBatch([event])
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(obj["sdk_key"] as? String, "pk_ja0_demo")
        XCTAssertEqual(obj["platform"] as? String, "ios")
        let events = obj["events"] as! [[String: Any]]
        XCTAssertEqual(events.count, 1)
        let e = events[0]
        XCTAssertEqual(e["event_id"] as? String, "01HZ_EVENT")
        XCTAssertEqual(e["app_id"] as? String, "app-1")
        XCTAssertEqual(e["install_id"] as? String, "01HZ_INSTALL")
        XCTAssertEqual(e["name"] as? String, "purchase")
        XCTAssertEqual(e["ts"] as? Int, 1_700_000_000)
        XCTAssertEqual(e["session_id"] as? String, "sess-1")
        XCTAssertEqual(e["revenue"] as? Double, 99.0)
        XCTAssertEqual(e["currency"] as? String, "KRW")
        XCTAssertEqual((e["params"] as? [String: Any])?["level"] as? Int, 5)
    }

    func testBatchOmitsEmptyOptionalFields() throws {
        let config = MTrackerConfig(sdkKey: "k", sdkSecret: "s", appId: "app-1")
        let http = HTTPClient(config: config, logger: MTLogger(level: .none))
        let event = QueuedEvent(
            eventId: "e", appId: "app-1", installId: "i", name: "install", ts: 1
        )
        let data = try http.encodeBatch([event])
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let e = (obj["events"] as! [[String: Any]])[0]
        XCTAssertNil(e["session_id"])
        XCTAssertNil(e["revenue"])
        XCTAssertNil(e["currency"])
        XCTAssertNil(e["match_token"])
        XCTAssertNil(e["device_fp"])
        XCTAssertNil(e["params"])
    }

    // MARK: - ULID

    func testULIDFormat() {
        let id = ULID.generate()
        XCTAssertEqual(id.count, 26)
        // Crockford base32 alphabet only.
        let allowed = CharacterSet(charactersIn: "0123456789ABCDEFGHJKMNPQRSTVWXYZ")
        XCTAssertTrue(id.unicodeScalars.allSatisfy { allowed.contains($0) })
    }

    func testULIDMonotonicAndUnique() {
        var seen = Set<String>()
        var previous = ""
        for _ in 0..<10_000 {
            let id = ULID.generate()
            XCTAssertFalse(seen.contains(id), "ULID collision")
            seen.insert(id)
            if !previous.isEmpty {
                XCTAssertGreaterThan(id, previous, "ULIDs must be lexicographically increasing")
            }
            previous = id
        }
    }

    func testULIDTimestampSortsAcrossTime() {
        let early = ULID.generate(now: Date(timeIntervalSince1970: 1_000_000))
        let late = ULID.generate(now: Date(timeIntervalSince1970: 2_000_000))
        XCTAssertLessThan(early, late)
    }

    // MARK: - Deep link parsing

    func testDeepLinkParsing() {
        let url = URL(string: "https://go-mtracker.ja0.com/product/123?promo=SUMMER&ref=abc")!
        let link = MTracker.parseDeepLink(url, isDeferred: false)
        XCTAssertEqual(link.path, "/product/123")
        XCTAssertEqual(link.params["promo"], "SUMMER")
        XCTAssertEqual(link.params["ref"], "abc")
        XCTAssertFalse(link.isDeferred)
        XCTAssertEqual(link.url, url.absoluteString)
    }

    // MARK: - Fingerprint gating

    func testFingerprintRequiresConsentAndATT() {
        let fp = Fingerprint()
        XCTAssertNil(fp.collect(attributionConsentGranted: false, attAuthorized: true))
        XCTAssertNil(fp.collect(attributionConsentGranted: true, attAuthorized: false))
        XCTAssertNil(fp.collect(attributionConsentGranted: false, attAuthorized: false))
    }

    // MARK: - Ad parsing (docs/ads.md §6)

    func testNativeAdParsing() {
        let json = """
        {
          "slotId": "home_feed_slot",
          "adId": "01J_AD",
          "format": "native",
          "assets": {
            "headline": "Install now", "body": "Great app", "advertiser": "Acme",
            "cta": "Install", "icon": "https://x/icon.png",
            "media": { "type": "image", "url": "https://x/m.png" },
            "rating": 4.6
          },
          "tracking": {
            "impression": ["https://ingest-mtracker.ja0.com/i/abc"],
            "click": "https://go-mtracker.ja0.com/ad/xyz",
            "viewableThreshold": { "pixels": 0.5, "ms": 1000 }
          }
        }
        """.data(using: .utf8)!
        let ad = MTAds.parse(json, fallbackSlotId: "fallback")
        XCTAssertNotNil(ad)
        XCTAssertEqual(ad?.adId, "01J_AD")
        XCTAssertEqual(ad?.assets.headline, "Install now")
        XCTAssertEqual(ad?.assets.media?.type, .image)
        XCTAssertEqual(ad?.assets.rating, 4.6)
        XCTAssertEqual(ad?.tracking.clickURL, "https://go-mtracker.ja0.com/ad/xyz")
        XCTAssertEqual(ad?.tracking.impressionURLs.first, "https://ingest-mtracker.ja0.com/i/abc")
        XCTAssertEqual(ad?.tracking.viewableThreshold.pixels, 0.5)
    }
}

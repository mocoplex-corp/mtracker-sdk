import Foundation

/// How an install was matched to a click. Ordered by precedence
/// (docs/attribution.md §7): deterministic > probabilistic > aggregate > organic.
public enum AttributionConfidence: String, Sendable {
    case deterministic   // clipboard match_token / Universal Link (iOS)
    case probabilistic   // fingerprint window match (has a confidence score)
    case aggregate       // SKAN / AAK campaign-level
    case organic         // no match
}

/// Attribution result delivered to `onAttribution`. Represents the campaign/source
/// that drove the install (last-touch by default).
public struct AttributionData: Sendable {
    public let source: String?
    public let campaign: String?
    public let network: String?
    public let clickId: String?
    public let confidence: AttributionConfidence
    /// 0.0–1.0, meaningful only for `.probabilistic` matches.
    public let confidenceScore: Double?
    /// Raw extra fields the backend returned (adgroup, creative, ...).
    public let raw: [String: String]

    public init(
        source: String?,
        campaign: String?,
        network: String?,
        clickId: String?,
        confidence: AttributionConfidence,
        confidenceScore: Double? = nil,
        raw: [String: String] = [:]
    ) {
        self.source = source
        self.campaign = campaign
        self.network = network
        self.clickId = clickId
        self.confidence = confidence
        self.confidenceScore = confidenceScore
        self.raw = raw
    }
}

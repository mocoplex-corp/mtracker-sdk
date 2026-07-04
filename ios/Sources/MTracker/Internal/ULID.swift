import Foundation
import Security

/// A real ULID (Universally Unique Lexicographically Sortable Identifier) generator.
///
/// ULID layout (128 bits, encoded as 26 Crockford base32 chars):
///   - 48 bits: millisecond Unix timestamp (10 chars)
///   - 80 bits: cryptographic randomness (16 chars)
///
/// Used for `install_id` and every `event_id` (docs/sdk-contract §3): the server
/// treats `event_id` as an idempotent dedup key, so collisions must be effectively
/// impossible while remaining time-sortable for stable batch ordering.
///
/// This implementation is monotonic within a process: if two ULIDs are generated in
/// the same millisecond, the random component is incremented rather than regenerated,
/// preserving strict lexicographic ordering (spec §monotonicity).
enum ULID {

    /// Crockford base32 alphabet (excludes I, L, O, U to avoid ambiguity).
    private static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    private static let lock = NSLock()
    private static var lastTimeMs: UInt64 = 0
    private static var lastRandom: [UInt8] = [UInt8](repeating: 0, count: 10)

    /// Generates a new ULID string (26 chars).
    static func generate(now: Date = Date()) -> String {
        lock.lock(); defer { lock.unlock() }

        let timeMs = UInt64(max(0, now.timeIntervalSince1970 * 1000))
        var random: [UInt8]

        if timeMs == lastTimeMs {
            // Same millisecond: increment the previous randomness (monotonic).
            random = increment(lastRandom)
        } else {
            random = randomBytes(10)
            lastTimeMs = timeMs
        }
        lastRandom = random

        return encode(timeMs: timeMs, random: random)
    }

    // MARK: - Encoding

    private static func encode(timeMs: UInt64, random: [UInt8]) -> String {
        var chars = [Character]()
        chars.reserveCapacity(26)

        // 48-bit timestamp -> 10 base32 chars (big-endian, 5 bits per char).
        // Extract from the most significant 5-bit group down.
        var t = timeMs & 0xFFFF_FFFF_FFFF // 48 bits
        var timeChars = [Character](repeating: "0", count: 10)
        var i = 9
        while i >= 0 {
            timeChars[i] = alphabet[Int(t & 0x1F)]
            t >>= 5
            i -= 1
        }
        chars.append(contentsOf: timeChars)

        // 80-bit randomness -> 16 base32 chars.
        // Treat the 10 random bytes as an 80-bit big-endian integer and emit
        // 16 groups of 5 bits.
        var bits: UInt = 0
        var bitCount = 0
        var out = [Character]()
        out.reserveCapacity(16)
        for byte in random {
            bits = (bits << 8) | UInt(byte)
            bitCount += 8
            while bitCount >= 5 {
                bitCount -= 5
                let idx = Int((bits >> UInt(bitCount)) & 0x1F)
                out.append(alphabet[idx])
            }
        }
        // 80 bits / 5 = 16 chars exactly, no remainder.
        chars.append(contentsOf: out)
        return String(chars)
    }

    // MARK: - Randomness

    private static func randomBytes(_ count: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        // SecRandomCopyBytes is the CSPRNG on Apple platforms.
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        if status != errSecSuccess {
            // Extremely unlikely; fall back to arc4random so we never return
            // predictable zeros (which would break dedup uniqueness).
            for i in 0..<count { bytes[i] = UInt8.random(in: 0...255) }
        }
        return bytes
    }

    /// Increments an 80-bit big-endian byte array by 1 (with carry) for monotonic
    /// ULIDs within the same millisecond.
    private static func increment(_ bytes: [UInt8]) -> [UInt8] {
        var out = bytes
        var i = out.count - 1
        while i >= 0 {
            if out[i] == 0xFF {
                out[i] = 0
                i -= 1
            } else {
                out[i] += 1
                return out
            }
        }
        // Overflowed the full 80 bits within one ms (practically impossible):
        // reseed with fresh randomness rather than wrap to all-zeros.
        return randomBytes(bytes.count)
    }
}

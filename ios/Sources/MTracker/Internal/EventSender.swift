import Foundation

/// Drives delivery of queued events to ingest: debounced/batched flush, exponential
/// backoff on transient failures, and `Retry-After` honouring on 429
/// (docs/sdk-contract §4). A single serial actor guarantees at most one in-flight
/// flush so batches never overlap or double-send.
///
/// The queue is the durable source of truth; the sender only removes events after a
/// 2xx (`ack`). On 401 (bad HMAC/key) it stops retrying — a config error won't fix
/// itself by hammering — but keeps the events so a corrected key can deliver them.
actor EventSender {

    private let queue: EventQueue
    private let http: HTTPClient
    private let logger: MTLogger

    private let batchSize: Int
    private let baseDelay: TimeInterval
    private let maxDelay: TimeInterval

    private var flushing = false
    private var pendingFlush = false
    private var attempt = 0
    /// If set, no flush runs until this time (from a 429 Retry-After or backoff).
    private var suspendedUntil: Date?
    private var authBlocked = false

    init(
        queue: EventQueue,
        http: HTTPClient,
        logger: MTLogger,
        batchSize: Int = 50,
        baseDelay: TimeInterval = 2,
        maxDelay: TimeInterval = 300
    ) {
        self.queue = queue
        self.http = http
        self.logger = logger
        self.batchSize = batchSize
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
    }

    /// Request a flush. `nonisolated` so the synchronous facade can fire-and-forget it;
    /// debounced inside `drain()` so overlapping requests coalesce into one drain loop.
    nonisolated func flush() {
        Task { await self.drain() }
    }

    /// Clears an auth block after the host corrects the SDK key/secret at runtime.
    nonisolated func resetAuthBlock() {
        Task { await self.setAuthBlocked(false) }
    }

    private func setAuthBlocked(_ blocked: Bool) {
        authBlocked = blocked
    }

    private func drain() async {
        if flushing {
            pendingFlush = true
            return
        }
        flushing = true
        defer { flushing = false }

        repeat {
            pendingFlush = false

            if authBlocked {
                logger.warn("delivery blocked (auth failure); skipping flush")
                return
            }
            if let until = suspendedUntil, until > Date() {
                let wait = until.timeIntervalSinceNow
                logger.debug("flush suspended for \(String(format: "%.1f", wait))s")
                try? await Task.sleep(nanoseconds: UInt64(max(0, wait) * 1_000_000_000))
            }
            suspendedUntil = nil

            let batch = queue.peekBatch(max: batchSize)
            if batch.isEmpty { return }

            let result = await http.postEvents(batch)
            switch result {
            case .success:
                queue.ack(eventIds: batch.map { $0.eventId })
                attempt = 0
                // Loop again immediately to drain any remaining events.
                pendingFlush = queue.count > 0

            case .authFailure:
                // Stop retrying; keep events for a corrected key.
                authBlocked = true
                return

            case .rateLimited(let retryAfter):
                suspendedUntil = Date().addingTimeInterval(retryAfter)
                pendingFlush = true

            case .transientFailure:
                attempt += 1
                let delay = backoffDelay(attempt)
                suspendedUntil = Date().addingTimeInterval(delay)
                logger.debug("transient failure; backoff \(String(format: "%.1f", delay))s (attempt \(attempt))")
                pendingFlush = true
            }
        } while pendingFlush
    }

    /// Full-jitter exponential backoff, capped at `maxDelay`.
    private func backoffDelay(_ attempt: Int) -> TimeInterval {
        let exp = min(maxDelay, baseDelay * pow(2, Double(max(0, attempt - 1))))
        return TimeInterval.random(in: 0...exp)
    }
}

import Foundation

/// A single tracked event, enqueued for batch delivery to ingest.
///
/// Field names / optionality mirror the wire contract exactly (docs/sdk-contract §3);
/// `HTTPClient` serialises these into the per-event JSON object. `eventId` is a ULID
/// used by the server as an idempotent dedup key.
struct QueuedEvent: Codable, Sendable {
    let eventId: String
    let appId: String
    let installId: String
    let name: String
    /// Client unix *seconds* (contract: `ts` is integer seconds).
    let ts: Int64
    let sessionId: String?
    let revenue: Double?
    let currency: String?
    /// Free-form params. Stored as pre-encoded JSON so `[String: Any]` values survive
    /// `Codable` round-tripping through the persistent queue without lossy bridging.
    let paramsJSON: Data?
    /// iOS-only: clipboard / Universal Link match token (install event only).
    let matchToken: String?
    /// Fingerprint JSON blob (install event only, ATT + consent gated). Maps to the
    /// server's `device_fp` string field.
    let deviceFP: String?

    init(
        eventId: String,
        appId: String,
        installId: String,
        name: String,
        ts: Int64,
        sessionId: String? = nil,
        revenue: Double? = nil,
        currency: String? = nil,
        paramsJSON: Data? = nil,
        matchToken: String? = nil,
        deviceFP: String? = nil
    ) {
        self.eventId = eventId
        self.appId = appId
        self.installId = installId
        self.name = name
        self.ts = ts
        self.sessionId = sessionId
        self.revenue = revenue
        self.currency = currency
        self.paramsJSON = paramsJSON
        self.matchToken = matchToken
        self.deviceFP = deviceFP
    }
}

/// Offline-durable event queue contract. Events survive app restarts and flush to
/// ingest in batches with exponential-backoff retry (docs/sdk-contract §4).
protocol EventQueue: Sendable {
    func enqueue(_ event: QueuedEvent)
    /// Peek up to `max` events for a batch flush without removing them (FIFO).
    func peekBatch(max: Int) -> [QueuedEvent]
    /// Remove events that were successfully delivered (or permanently dropped).
    func ack(eventIds: [String])
    var count: Int { get }
}

/// Persistent, file-backed event queue that survives process death (docs/sdk-contract
/// §4: "로컬 영속(파일), 배치 전송, 앱 재시작에도 유실 없음").
///
/// Storage model: an append-friendly JSON snapshot in Application Support
/// (`…/mtracker/queue.json`). Application Support is excluded from the "user
/// documents" backup semantics we don't want, and we additionally mark the directory
/// with `isExcludedFromBackup` so queued analytics never bloat iCloud/iTunes backups.
///
/// Concurrency: a single `NSLock` guards all access; writes are atomic (write to a
/// temp file + `replaceItemAt`) so a crash mid-flush can never corrupt the queue.
/// A soft cap (`maxStored`) drops the oldest events to bound disk usage if the device
/// is offline for a very long time.
final class FileEventQueue: EventQueue, @unchecked Sendable {

    private let lock = NSLock()
    private let fileURL: URL
    private let maxStored: Int
    private let logger: MTLogger

    private var backing: [QueuedEvent] = []

    init(sdkKeyScope: String, maxStored: Int = 5000, logger: MTLogger) {
        self.maxStored = maxStored
        self.logger = logger

        let fm = FileManager.default
        let base = (try? fm.url(for: .applicationSupportDirectory,
                                in: .userDomainMask,
                                appropriateFor: nil,
                                create: true))
            ?? fm.temporaryDirectory

        // Namespace by SDK key hash so multiple embedded tenants don't share a queue.
        var dir = base.appendingPathComponent("mtracker", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        // Exclude the whole queue directory from device backups.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)

        let safeScope = sdkKeyScope
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ".", with: "_")
        self.fileURL = dir.appendingPathComponent("queue_\(safeScope).json", isDirectory: false)

        load()
    }

    // MARK: - EventQueue

    func enqueue(_ event: QueuedEvent) {
        lock.lock(); defer { lock.unlock() }
        backing.append(event)
        if backing.count > maxStored {
            // Drop oldest to stay within budget (retention/analytics events are the
            // most droppable; lifecycle events are enqueued first so survive longest).
            let overflow = backing.count - maxStored
            backing.removeFirst(overflow)
            logger.warn("event queue overflow, dropped \(overflow) oldest events")
        }
        persist()
    }

    func peekBatch(max: Int) -> [QueuedEvent] {
        lock.lock(); defer { lock.unlock() }
        return Array(backing.prefix(max))
    }

    func ack(eventIds: [String]) {
        lock.lock(); defer { lock.unlock() }
        let ids = Set(eventIds)
        backing.removeAll { ids.contains($0.eventId) }
        persist()
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return backing.count
    }

    // MARK: - Persistence (caller holds lock)

    private func load() {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? Data(contentsOf: fileURL), !data.isEmpty else { return }
        do {
            backing = try JSONDecoder().decode([QueuedEvent].self, from: data)
        } catch {
            // Corrupt file (e.g. partial write from an older format): start clean
            // rather than crash. We prefer losing a stale queue over never sending.
            logger.error("failed to load persisted queue: \(error.localizedDescription)")
            backing = []
        }
    }

    private func persist() {
        do {
            let data = try JSONEncoder().encode(backing)
            // `.atomic` writes to a temp file and renames it into place, so a crash
            // mid-write can never leave a half-written / corrupt queue file.
            try data.write(to: fileURL, options: .atomic)
        } catch {
            logger.error("failed to persist queue: \(error.localizedDescription)")
        }
    }
}

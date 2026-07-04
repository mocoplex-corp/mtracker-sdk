import Foundation
import os

/// Minimal leveled logger. Wraps `os.Logger` (unified logging) when available so SDK
/// diagnostics land in Console/log streams without a third-party dependency, and never
/// prints anything above the configured `LogLevel`.
struct MTLogger: Sendable {
    let level: LogLevel

    private let osLog = os.Logger(subsystem: "com.mocoplex.mtracker", category: "sdk")

    private func enabled(_ threshold: LogLevel) -> Bool {
        order(level) >= order(threshold)
    }

    private func order(_ l: LogLevel) -> Int {
        switch l {
        case .none: return 0
        case .error: return 1
        case .warn: return 2
        case .info: return 3
        case .debug: return 4
        }
    }

    func error(_ msg: @autoclosure () -> String) {
        guard enabled(.error) else { return }
        let m = msg()
        osLog.error("[mtracker] \(m, privacy: .public)")
    }

    func warn(_ msg: @autoclosure () -> String) {
        guard enabled(.warn) else { return }
        let m = msg()
        osLog.warning("[mtracker] \(m, privacy: .public)")
    }

    func info(_ msg: @autoclosure () -> String) {
        guard enabled(.info) else { return }
        let m = msg()
        osLog.info("[mtracker] \(m, privacy: .public)")
    }

    func debug(_ msg: @autoclosure () -> String) {
        guard enabled(.debug) else { return }
        let m = msg()
        osLog.debug("[mtracker] \(m, privacy: .public)")
    }
}

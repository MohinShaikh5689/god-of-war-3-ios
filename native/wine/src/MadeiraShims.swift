// The three Madeira app types that Madeira's StikJITHelper.swift (compiled unchanged into the
// framework) uses, without the rest of its SwiftUI app: the log, madeira.cfg and the signing flags.
// Each keeps the part of the original's interface and behaviour the JIT pool code relies on.
import Foundation
import os

/// Madeira's LogStore, reduced to `shared.log`: each line goes to stderr, which the Wine bridges point
/// at Documents/madeira-log.txt once a session starts, and to the system log (idevicesyslog).
final class LogStore: @unchecked Sendable {
    struct LogEntry {
        enum Level: String { case info = "INFO", success = "OK", error = "ERR", debug = "DBG" }
    }
    static let shared = LogStore()
    private let logger = Logger(subsystem: "WineCore", category: "engine")

    func log(_ message: String, level: LogEntry.Level = .info) {
        let line = "[\(level.rawValue)] \(message)"
        fputs(line + "\n", stderr)
        logger.log("\(line, privacy: .public)")
    }
}

/// Madeira's MadeiraConfig (app/Madeira/MadeiraConfig.swift): Documents/madeira.cfg, "key = value" lines,
/// '#' comments, the last line winning; a running game's own lines from the file MADEIRA_CFG_GAME names.
/// Without madeira.cfg, the legacy one-value-per-file Documents/madeira-<key>.txt is read.
enum MadeiraConfig {
    static var documents: URL? { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first }
    static var url: URL? { documents?.appendingPathComponent("madeira.cfg") }
    static var present: Bool { url.map { FileManager.default.fileExists(atPath: $0.path) } ?? false }

    static func parse(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for raw in text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" }) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let k = line[..<eq].trimmingCharacters(in: .whitespaces)
            let v = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if !k.isEmpty { out[k] = v }
        }
        return out
    }

    static func all() -> [String: String] {
        guard let u = url, let text = try? String(contentsOf: u, encoding: .utf8) else { return [:] }
        return parse(text)
    }

    static func get(_ key: String) -> String? {
        if present { return all()[key] }
        guard let d = documents,
              let txt = try? String(contentsOf: d.appendingPathComponent("madeira-\(key).txt"), encoding: .utf8)
        else { return nil }
        return txt.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func gameValue(_ key: String) -> String? {
        guard let p = getenv("MADEIRA_CFG_GAME"), case let path = String(cString: p), !path.isEmpty,
              let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        return parse(text)[key].flatMap { $0.isEmpty ? nil : $0 }
    }

    /// `env.NAME = value` in madeira.cfg, else the environment, else `fallback`; anything but "0" is on.
    static func flag(_ name: String, fallback: Bool = true) -> Bool {
        if present, let v = all()["env." + name] { return v != "0" }
        return getenv(name).map { String(cString: $0) != "0" } ?? fallback
    }
}

/// Madeira's SigningStatus (EntitlementChecker.swift), reduced to the CS_DEBUGGED flag.
struct SigningStatus {
    let known: Bool
    let flags: UInt32
    var debugged: Bool { known && flags & 0x1000_0000 != 0 }

    static var current: SigningStatus {
        var flags: UInt32 = 0
        let known = jit_cs_status(&flags)
        return SigningStatus(known: known, flags: flags)
    }
}

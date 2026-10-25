import Foundation

/// Append-only record of every clear-codes attempt, so the erased codes aren't lost.
/// Stored next to the CSV logs as `clear-history.log`.
public enum ClearHistory {
    public static func defaultURL() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MustangOBD Logs", isDirectory: true)
            .appendingPathComponent("clear-history.log")
    }

    public static func line(_ r: ClearReport, adapter: String?) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        func codes(_ d: DTCReport?) -> String {
            guard let d else { return "not read" }
            func sec(_ s: DTCReport.Section) -> String {
                switch s {
                case .codes(let c): return "[" + c.map(\.code).joined(separator: ",") + "]"
                case .notSupported: return "n/a"
                case .failed: return "unreadable"
                }
            }
            return "MIL=\(d.milOn.map { $0 ? "ON" : "OFF" } ?? "?") stored=\(sec(d.stored)) pending=\(sec(d.pending)) permanent=\(sec(d.permanent))"
        }
        let outcome: String
        switch r.outcome {
        case .cleared: outcome = "CLEARED (ECU confirmed)"
        case .refused(let w): outcome = "REFUSED by app, nothing sent: \(w)"
        case .ecuRejected(let w): outcome = "REJECTED by ECU: \(w)"
        case .failed(let w): outcome = "UNCONFIRMED: \(w)"
        }
        let rpm = r.rpm.map { String(format: "%.0f", $0) } ?? "?"
        let spd = r.speedKmh.map { String(format: "%.0f", $0) } ?? "?"
        return "\(f.string(from: r.at)) | \(r.simulated ? "SIMULATED" : "LIVE") | \(outcome) | rpm=\(rpm) speed_kmh=\(spd) | before: \(codes(r.codesBefore)) | after: \(codes(r.codesAfter)) | adapter=\(adapter ?? "unknown")"
    }

    public static func append(_ r: ClearReport, adapter: String?, to url: URL = defaultURL()) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = Data((line(r, adapter: adapter) + "\n").utf8)
        if FileManager.default.fileExists(atPath: url.path) {
            let h = try FileHandle(forWritingTo: url)
            defer { try? h.close() }
            try h.seekToEnd()
            try h.write(contentsOf: data)
        } else {
            try data.write(to: url)
        }
    }
}

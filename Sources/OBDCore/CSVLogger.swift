import Foundation

/// Writes one row per polling cycle to a local CSV file. Nothing is uploaded anywhere.
public final class CSVLogger {
    public let url: URL
    public private(set) var rowCount = 0
    private let handle: FileHandle
    private let columns: [PIDDefinition]
    private let units: UnitSystem
    private let started = Date()
    private let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    public init(url: URL, columns: [PIDDefinition], units: UnitSystem, simulated: Bool, adapter: String?) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw TransportError("Could not create \(url.path)")
        }
        self.url = url
        self.handle = try FileHandle(forWritingTo: url)
        self.columns = columns
        self.units = units
        var header = ["timestamp", "elapsed_s", "data_source"]
        for c in columns {
            let unit = units.convert(0, c.quantity).unit
            header.append("\(c.key) (\(unit))")
        }
        let note = "# MustangOBD log. data_source=\(simulated ? "SIMULATED (not from a vehicle)" : "LIVE vehicle data") adapter=\(adapter ?? "unknown")"
        try write(line: Self.escape(note))
        try write(line: header.map(Self.escape).joined(separator: ","))
    }

    /// Appends a row. Missing/unsupported values are left blank.
    public func log(_ values: [UInt8: Double], at date: Date = Date(), simulated: Bool) throws {
        var row = [iso.string(from: date), String(format: "%.3f", date.timeIntervalSince(started)), simulated ? "SIMULATED" : "LIVE"]
        for c in columns {
            if let v = values[c.pid] {
                row.append(units.format(v, c))
            } else {
                row.append("")
            }
        }
        try write(line: row.map(Self.escape).joined(separator: ","))
        rowCount += 1
    }

    public func close() { try? handle.close() }

    private func write(line: String) throws {
        try handle.write(contentsOf: Data((line + "\n").utf8))
    }

    static func escape(_ s: String) -> String {
        if s.contains(where: { ",\"\n\r".contains($0) }) {
            return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return s
    }

    public static func defaultURL(simulated: Bool, in dir: URL? = nil) -> URL {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HHmmss"
        let base = dir ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MustangOBD Logs", isDirectory: true)
        return base.appendingPathComponent("obd_\(f.string(from: Date()))\(simulated ? "_SIMULATED" : "").csv")
    }
}

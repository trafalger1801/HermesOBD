import Foundation

// Integration with a local Hermes Agent install (Nous Research) through its
// OpenAI-compatible API server (default http://127.0.0.1:8642, bearer key required).
//
// Requests do not set `model` or `provider`, so Hermes answers with whatever model it is
// configured to use. If that is a cloud model, the summaries sent here leave this Mac.

/// Collects readings between analyses and summarizes them.
public struct ReadingWindow: Sendable {
    public struct Stat: Sendable, Equatable {
        public var min: Double, max: Double, sum: Double, count: Int, latest: Double
        public var avg: Double { sum / Double(count) }
    }
    public private(set) var stats: [UInt8: Stat] = [:]
    public private(set) var start: Date?
    public private(set) var end: Date?
    public private(set) var cycles = 0

    public init() {}

    public var isEmpty: Bool { stats.isEmpty }

    public mutating func add(_ readings: [PIDReading]) {
        guard !readings.isEmpty else { return }
        cycles += 1
        for r in readings {
            if start == nil || r.at < start! { start = r.at }
            if end == nil || r.at > end! { end = r.at }
            if var s = stats[r.pid] {
                s.min = Swift.min(s.min, r.value); s.max = Swift.max(s.max, r.value)
                s.sum += r.value; s.count += 1; s.latest = r.value
                stats[r.pid] = s
            } else {
                stats[r.pid] = Stat(min: r.value, max: r.value, sum: r.value, count: 1, latest: r.value)
            }
        }
    }

    public mutating func reset() { self = ReadingWindow() }
}

/// Everything that goes into one analysis request. Built from data the app already shows;
/// no VIN, location, or personal data is included.
public struct HermesSnapshot: Sendable {
    public var window: ReadingWindow
    public var simulated: Bool
    public var units: UnitSystem
    public var adapter: AdapterInfo
    public var pidStatus: [UInt8: PIDStatus]
    public var dtc: DTCReport?
    public var vehicle: String

    public init(window: ReadingWindow, simulated: Bool, units: UnitSystem, adapter: AdapterInfo,
                pidStatus: [UInt8: PIDStatus], dtc: DTCReport?, vehicle: String = "2005 Ford Mustang convertible") {
        self.window = window; self.simulated = simulated; self.units = units; self.adapter = adapter
        self.pidStatus = pidStatus; self.dtc = dtc; self.vehicle = vehicle
    }

    /// The exact text sent to Hermes (also shown to the user under "What was sent").
    public func render() -> String {
        let t = DateFormatter(); t.dateFormat = "HH:mm:ss"
        var out: [String] = []
        let span = (window.start.flatMap { s in window.end.map { $0.timeIntervalSince(s) } }) ?? 0
        out.append("OBD-II data window from a \(vehicle).")
        out.append("data_source: \(simulated ? "SIMULATED (built-in simulator, NOT from the car)" : "LIVE (read from the car)")")
        if let s = window.start, let e = window.end {
            out.append("window: \(t.string(from: s))–\(t.string(from: e)) local time, \(String(format: "%.0f", span)) s, \(window.cycles) polling cycles")
        }
        out.append("protocol: \(adapter.protocolName ?? "unknown"); adapter battery voltage: \(adapter.voltage ?? "unknown")")
        out.append("")
        out.append("value | latest | min | avg | max | unit | samples")
        for def in PIDCatalog.all {
            guard let s = window.stats[def.pid] else { continue }
            let unit = units.convert(0, def.quantity).unit
            out.append("\(def.name) | \(units.format(s.latest, def)) | \(units.format(s.min, def)) | \(units.format(s.avg, def)) | \(units.format(s.max, def)) | \(unit) | \(s.count)")
        }
        let unsupported = PIDCatalog.all.filter { [.notAdvertised, .noResponse].contains(pidStatus[$0.pid]) }.map(\.name)
        if !unsupported.isEmpty { out.append("not supported by this vehicle: \(unsupported.joined(separator: ", "))") }
        out.append("")
        if let d = dtc {
            out.append("trouble codes (read \(t.string(from: d.readAt))\(d.simulated ? ", SIMULATED" : "")):")
            out.append("  check-engine light: \(d.milOn.map { $0 ? "ON" : "OFF" } ?? "unknown"); ECU-reported count: \(d.reportedCount.map(String.init) ?? "unknown")")
            func line(_ name: String, _ s: DTCReport.Section) -> String {
                switch s {
                case .codes(let c): return "  \(name): " + (c.isEmpty ? "none" : c.map { $0.code + ($0.genericDescription.map { " (\($0))" } ?? "") }.joined(separator: ", "))
                case .notSupported(let w): return "  \(name): \(w)"
                case .failed(let w): return "  \(name): could not read (\(w))"
                }
            }
            out.append(line("stored", d.stored)); out.append(line("pending", d.pending)); out.append(line("permanent", d.permanent))
        } else {
            out.append("trouble codes: not read yet in this session")
        }
        return out.joined(separator: "\n")
    }
}

public enum HermesPrompt {
    /// Layered on top of Hermes's own system prompt via the Responses API `instructions` field.
    public static func instructions(intervalSeconds: Int) -> String {
        """
        You are receiving OBD-II data from a read-only Mac monitoring app connected to the user's car. \
        A new data window arrives about every \(intervalSeconds) seconds in this same conversation, so compare with earlier windows when useful.
        Reply with plain text only. Do not run terminal commands, edit files, or save memories for these messages.
        Keep each reply short: at most 5 bullet points. Lead with anything abnormal or worth attention \
        (temperatures, fuel trims beyond roughly ±10%, misfire or lean/rich codes, low or high voltage, implausible readings). \
        If nothing stands out, say so in one line.
        If data_source is SIMULATED, say once that the data is simulated and not from the car.
        Say when the data is not enough to judge something. Never suggest clearing codes to hide a problem or to pass an inspection; the app can clear codes only when the user explicitly asks, and it cannot tune or modify the ECU.
        The person may be driving: never ask them to look at a screen or interact while driving.
        """
    }
}

public struct HermesReply: Sendable, Equatable {
    public let responseID: String?
    public let text: String
}

public struct HermesError: Error, CustomStringConvertible, Equatable {
    public let message: String
    public init(_ m: String) { message = m }
    public var description: String { message }
}

/// Minimal client for the Hermes API server.
public final class HermesClient: @unchecked Sendable {
    public let baseURL: URL
    private let apiKey: String
    private let session: URLSession
    public var requestTimeout: TimeInterval = 180

    public init(baseURL: URL, apiKey: String, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.session = session
    }

    /// True when the URL points at this Mac (127.0.0.1 / ::1 / localhost).
    public static func isLoopback(_ url: URL) -> Bool {
        ["127.0.0.1", "localhost", "::1", "[::1]"].contains(url.host?.lowercased() ?? "")
    }

    /// GET /health — confirms the API server is up. Also checks the key against /v1/models.
    public func checkConnection() async throws -> String {
        var health = URLRequest(url: baseURL.appendingPathComponent("health"), timeoutInterval: 5)
        health.httpMethod = "GET"
        _ = try await perform(health)
        var models = URLRequest(url: baseURL.appendingPathComponent("v1/models"), timeoutInterval: 10)
        models.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let data = try await perform(models)
        let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let name = ((obj?["data"] as? [[String: Any]])?.first?["id"] as? String) ?? "hermes-agent"
        return name
    }

    /// POST /v1/responses. Chains to `previousResponseID` so Hermes keeps the session's context.
    public func analyze(input: String, instructions: String, previousResponseID: String?) async throws -> HermesReply {
        var body: [String: Any] = ["input": input, "instructions": instructions, "store": true]
        if let previousResponseID { body["previous_response_id"] = previousResponseID }
        var req = URLRequest(url: baseURL.appendingPathComponent("v1/responses"), timeoutInterval: requestTimeout)
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data = try await perform(req)
        return try Self.parseResponse(data)
    }

    /// Extracts the final assistant text from a Responses API object.
    static func parseResponse(_ data: Data) throws -> HermesReply {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HermesError("Hermes returned something that isn't JSON")
        }
        if let status = obj["status"] as? String, status == "failed" {
            let msg = ((obj["error"] as? [String: Any])?["message"] as? String) ?? "unknown error"
            throw HermesError("Hermes reported a failure: \(msg)")
        }
        var texts: [String] = []
        for item in (obj["output"] as? [[String: Any]]) ?? [] where item["type"] as? String == "message" {
            if item["phase"] as? String == "commentary" { continue }   // progress notes, not the answer
            for part in (item["content"] as? [[String: Any]]) ?? [] {
                if let t = part["text"] as? String, ["output_text", "text"].contains(part["type"] as? String ?? "") { texts.append(t) }
            }
        }
        if texts.isEmpty, let t = obj["output_text"] as? String { texts.append(t) }
        guard !texts.isEmpty else { throw HermesError("Hermes reply had no text") }
        return HermesReply(responseID: obj["id"] as? String, text: texts.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func perform(_ req: URLRequest) async throws -> Data {
        let data: Data, resp: URLResponse
        do {
            (data, resp) = try await session.data(for: req)
        } catch let e as URLError {
            switch e.code {
            case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost:
                throw HermesError("Can't reach Hermes at \(baseURL.absoluteString). Is the API server enabled and `hermes gateway` running?")
            case .timedOut:
                throw HermesError("Hermes didn't answer in time")
            default:
                throw HermesError("Network error talking to Hermes: \(e.localizedDescription)")
            }
        }
        guard let http = resp as? HTTPURLResponse else { throw HermesError("No HTTP response from Hermes") }
        switch http.statusCode {
        case 200..<300: return data
        case 401, 403: throw HermesError("Hermes rejected the API key (HTTP \(http.statusCode)). Check API_SERVER_KEY in ~/.hermes/.env")
        default:
            let snippet = String(decoding: data.prefix(300), as: UTF8.self)
            throw HermesError("Hermes returned HTTP \(http.statusCode): \(snippet)")
        }
    }
}

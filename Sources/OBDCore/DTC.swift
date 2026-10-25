import Foundation

public struct DTC: Hashable, Sendable, Identifiable, Comparable {
    public let code: String
    public var id: String { code }
    public static func < (a: DTC, b: DTC) -> Bool { a.code < b.code }

    /// Generic SAE description if it's in the small built-in table; nil otherwise.
    public var genericDescription: String? { DTC.descriptions[code] }

    /// Decodes the two-byte SAE J2012 representation. Returns nil for 00 00 (padding).
    public init?(_ a: UInt8, _ b: UInt8) {
        if a == 0 && b == 0 { return nil }
        let letter = ["P", "C", "B", "U"][Int(a >> 6)]
        code = letter + String(format: "%X%X%X%X", (a >> 4) & 0x3, a & 0xF, b >> 4, b & 0xF)
    }

    public init(code: String) { self.code = code }

    /// Small table of common generic (P0xxx) codes. Ford-specific (P1xxx) codes are not
    /// included; look those up in a service manual.
    static let descriptions: [String: String] = [
        "P0101": "Mass air flow sensor range/performance",
        "P0102": "Mass air flow sensor circuit low",
        "P0103": "Mass air flow sensor circuit high",
        "P0113": "Intake air temperature sensor circuit high",
        "P0117": "Engine coolant temperature sensor circuit low",
        "P0118": "Engine coolant temperature sensor circuit high",
        "P0125": "Insufficient coolant temperature for closed-loop fuel control",
        "P0128": "Coolant thermostat (coolant temp below regulating temperature)",
        "P0131": "O2 sensor circuit low voltage (bank 1 sensor 1)",
        "P0133": "O2 sensor circuit slow response (bank 1 sensor 1)",
        "P0135": "O2 sensor heater circuit (bank 1 sensor 1)",
        "P0141": "O2 sensor heater circuit (bank 1 sensor 2)",
        "P0155": "O2 sensor heater circuit (bank 2 sensor 1)",
        "P0161": "O2 sensor heater circuit (bank 2 sensor 2)",
        "P0171": "System too lean (bank 1)",
        "P0172": "System too rich (bank 1)",
        "P0174": "System too lean (bank 2)",
        "P0175": "System too rich (bank 2)",
        "P0300": "Random/multiple cylinder misfire detected",
        "P0301": "Cylinder 1 misfire detected",
        "P0302": "Cylinder 2 misfire detected",
        "P0303": "Cylinder 3 misfire detected",
        "P0304": "Cylinder 4 misfire detected",
        "P0305": "Cylinder 5 misfire detected",
        "P0306": "Cylinder 6 misfire detected",
        "P0307": "Cylinder 7 misfire detected",
        "P0308": "Cylinder 8 misfire detected",
        "P0316": "Misfire detected on startup (first 1000 revolutions)",
        "P0340": "Camshaft position sensor circuit",
        "P0401": "EGR flow insufficient",
        "P0411": "Secondary air injection incorrect flow",
        "P0420": "Catalyst efficiency below threshold (bank 1)",
        "P0430": "Catalyst efficiency below threshold (bank 2)",
        "P0440": "Evaporative emission system malfunction",
        "P0442": "Evaporative emission system small leak",
        "P0446": "Evaporative emission vent control circuit",
        "P0455": "Evaporative emission system large leak",
        "P0456": "Evaporative emission system very small leak",
        "P0457": "Evaporative emission leak (fuel cap loose/off)",
        "P0500": "Vehicle speed sensor malfunction",
        "P0505": "Idle air control system",
        "P0562": "System voltage low",
        "P0563": "System voltage high",
    ]
}

public enum DTCParser {
    /// True for ISO 15765 (CAN) protocols 6–9 (and A–C). From ATDPN, which may be prefixed with "A" (auto).
    public static func isCAN(protocolNumber: String?) -> Bool? {
        guard var p = protocolNumber?.uppercased().trimmingCharacters(in: .whitespaces), !p.isEmpty else { return nil }
        if p.count == 2, p.hasPrefix("A") { p.removeFirst() }
        guard let n = Int(p, radix: 16) else { return nil }
        return n >= 6
    }

    /// Parses responses to services 03 / 07 / 0A.
    /// CAN:     [43, count, A, B, A, B, ...]  (one message per ECU, may be multi-frame)
    /// Non-CAN: [43, A, B, A, B, A, B]       (3 codes per frame, zero-padded)
    public static func parse(messages: [[UInt8]], service: UInt8, isCAN: Bool?) -> [DTC] {
        let positive = service + 0x40
        var codes = Set<DTC>()
        for m in messages where m.first == positive {
            var body = Array(m.dropFirst())
            let can: Bool
            if let isCAN { can = isCAN } else {
                // Heuristic when protocol is unknown: CAN message has a count byte matching its length.
                can = !body.isEmpty && body.count % 2 == 1 && Int(body[0]) * 2 <= body.count - 1
            }
            if can {
                guard let count = body.first else { continue }
                body = Array(body.dropFirst().prefix(Int(count) * 2))
            }
            var i = 0
            while i + 1 < body.count {
                if let d = DTC(body[i], body[i + 1]) { codes.insert(d) }
                i += 2
            }
        }
        return codes.sorted()
    }
}

/// Result of a full trouble-code read.
public struct DTCReport: Sendable, Equatable {
    public enum Section: Sendable, Equatable {
        case codes([DTC])
        case notSupported(String)   // vehicle didn't answer this service
        case failed(String)
    }
    public var milOn: Bool?
    public var reportedCount: Int?
    public var stored: Section
    public var pending: Section
    public var permanent: Section
    public var readAt: Date
    public var simulated: Bool
}

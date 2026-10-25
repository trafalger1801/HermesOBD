import Foundation

public enum Quantity: String, Sendable, Codable {
    case rpm, speed, temperature, percent, pressure, airflow, angle, voltage, duration
}

public enum UnitSystem: String, Sendable, CaseIterable, Codable, Identifiable {
    case imperial, metric
    public var id: String { rawValue }

    /// Converts a metric value (as decoded from OBD-II, which is always metric) for display.
    public func convert(_ metric: Double, _ q: Quantity) -> (value: Double, unit: String) {
        switch (q, self) {
        case (.rpm, _): return (metric, "rpm")
        case (.speed, .metric): return (metric, "km/h")
        case (.speed, .imperial): return (metric * 0.621371, "mph")
        case (.temperature, .metric): return (metric, "°C")
        case (.temperature, .imperial): return (metric * 9 / 5 + 32, "°F")
        case (.percent, _): return (metric, "%")
        case (.pressure, .metric): return (metric, "kPa")
        case (.pressure, .imperial): return (metric * 0.145038, "psi")
        case (.airflow, _): return (metric, "g/s")   // g/s is the usual unit in US tools too
        case (.angle, _): return (metric, "° BTDC")
        case (.voltage, _): return (metric, "V")
        case (.duration, _): return (metric, "s")
        }
    }

    /// Formats a metric value for display/CSV in this unit system.
    public func format(_ metric: Double, _ def: PIDDefinition) -> String {
        let c = convert(metric, def.quantity)
        let decimals = c.unit == "psi" ? max(def.decimals, 1) : def.decimals
        return String(format: "%.\(decimals)f", c.value)
    }
}

/// A standard SAE J1979 service 01 parameter.
public struct PIDDefinition: Sendable, Identifiable, Hashable {
    public let pid: UInt8
    public let key: String         // CSV column / stable identifier
    public let name: String
    public let quantity: Quantity
    public let byteCount: Int
    public let decimals: Int
    /// Fast-changing values are polled every cycle; others every few cycles.
    public let fast: Bool
    let formula: @Sendable ([UInt8]) -> Double

    public var id: UInt8 { pid }
    public init(pid: UInt8, key: String, name: String, quantity: Quantity, byteCount: Int, decimals: Int, fast: Bool = false,
                formula: @escaping @Sendable ([UInt8]) -> Double) {
        self.pid = pid; self.key = key; self.name = name; self.quantity = quantity
        self.byteCount = byteCount; self.decimals = decimals; self.fast = fast; self.formula = formula
    }

    public var command: String { String(format: "01%02X", pid) }

    public func decode(_ data: [UInt8]) -> Double? {
        guard data.count >= byteCount else { return nil }
        return formula(Array(data.prefix(byteCount)))
    }

    public static func == (a: PIDDefinition, b: PIDDefinition) -> Bool { a.pid == b.pid }
    public func hash(into h: inout Hasher) { h.combine(pid) }
}

public enum PIDCatalog {
    private static func ab(_ d: [UInt8]) -> Double { Double(Int(d[0]) * 256 + Int(d[1])) }
    private static func trim(_ d: [UInt8]) -> Double { (Double(d[0]) - 128) * 100 / 128 }

    public static let all: [PIDDefinition] = [
        .init(pid: 0x0C, key: "engine_rpm", name: "Engine RPM", quantity: .rpm, byteCount: 2, decimals: 0, fast: true) { ab($0) / 4 },
        .init(pid: 0x0D, key: "vehicle_speed", name: "Vehicle Speed", quantity: .speed, byteCount: 1, decimals: 0, fast: true) { Double($0[0]) },
        .init(pid: 0x05, key: "coolant_temp", name: "Coolant Temp", quantity: .temperature, byteCount: 1, decimals: 0) { Double($0[0]) - 40 },
        .init(pid: 0x0F, key: "intake_air_temp", name: "Intake Air Temp", quantity: .temperature, byteCount: 1, decimals: 0) { Double($0[0]) - 40 },
        .init(pid: 0x11, key: "throttle_position", name: "Throttle Position", quantity: .percent, byteCount: 1, decimals: 1, fast: true) { Double($0[0]) * 100 / 255 },
        .init(pid: 0x04, key: "engine_load", name: "Calculated Load", quantity: .percent, byteCount: 1, decimals: 1, fast: true) { Double($0[0]) * 100 / 255 },
        .init(pid: 0x06, key: "stft_bank1", name: "Short Fuel Trim B1", quantity: .percent, byteCount: 1, decimals: 1, fast: true) { trim($0) },
        .init(pid: 0x07, key: "ltft_bank1", name: "Long Fuel Trim B1", quantity: .percent, byteCount: 1, decimals: 1) { trim($0) },
        .init(pid: 0x08, key: "stft_bank2", name: "Short Fuel Trim B2", quantity: .percent, byteCount: 1, decimals: 1, fast: true) { trim($0) },
        .init(pid: 0x09, key: "ltft_bank2", name: "Long Fuel Trim B2", quantity: .percent, byteCount: 1, decimals: 1) { trim($0) },
        .init(pid: 0x10, key: "maf_rate", name: "Mass Air Flow", quantity: .airflow, byteCount: 2, decimals: 2, fast: true) { ab($0) / 100 },
        .init(pid: 0x0B, key: "intake_map", name: "Intake Manifold Pressure", quantity: .pressure, byteCount: 1, decimals: 0) { Double($0[0]) },
        .init(pid: 0x0E, key: "timing_advance", name: "Timing Advance", quantity: .angle, byteCount: 1, decimals: 1, fast: true) { Double($0[0]) / 2 - 64 },
        .init(pid: 0x2F, key: "fuel_level", name: "Fuel Level", quantity: .percent, byteCount: 1, decimals: 0) { Double($0[0]) * 100 / 255 },
        .init(pid: 0x42, key: "module_voltage", name: "Control Module Voltage", quantity: .voltage, byteCount: 2, decimals: 2) { ab($0) / 1000 },
        .init(pid: 0x46, key: "ambient_air_temp", name: "Ambient Air Temp", quantity: .temperature, byteCount: 1, decimals: 0) { Double($0[0]) - 40 },
        .init(pid: 0x33, key: "barometric_pressure", name: "Barometric Pressure", quantity: .pressure, byteCount: 1, decimals: 0) { Double($0[0]) },
        .init(pid: 0x1F, key: "run_time", name: "Run Time Since Start", quantity: .duration, byteCount: 2, decimals: 0) { ab($0) },
    ]

    public static func definition(for pid: UInt8) -> PIDDefinition? { all.first { $0.pid == pid } }

    /// Decodes a "PIDs supported" bitmap (response to 0100/0120/0140...).
    /// `base` is the request PID (0x00, 0x20, 0x40...). Bit 7 of byte A is PID base+1.
    public static func supportedPIDs(base: UInt8, bitmap: [UInt8]) -> Set<UInt8> {
        var out = Set<UInt8>()
        for (byteIndex, byte) in bitmap.prefix(4).enumerated() {
            for bit in 0..<8 where byte & (0x80 >> UInt8(bit)) != 0 {
                out.insert(base &+ UInt8(byteIndex * 8 + bit + 1))
            }
        }
        return out
    }
}

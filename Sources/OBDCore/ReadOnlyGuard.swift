import Foundation

/// Every command sent to the adapter passes through this allowlist.
///
/// Anything not explicitly listed is refused before it reaches the transport, so the
/// app cannot run actuator tests, write to or reflash the ECU, or change the adapter's
/// saved (EEPROM) settings — even by accident or through a bug elsewhere.
///
/// The single exception is service 04 (clear trouble codes). It passes only with a
/// `ClearCodesPermit`, which only `OBDEngine`'s clear flow can create after its safety
/// checks pass. Each permit is used for exactly one "04" command.
public enum ReadOnlyGuard {
    /// Proof that the engine's clear-codes safety checks passed. Cannot be created outside OBDCore.
    public struct ClearCodesPermit: Sendable {
        init() {}
    }

    public struct Refusal: Error, CustomStringConvertible, Equatable {
        public let command: String
        public let reason: String
        public var description: String { "Refused \"\(command)\": \(reason)" }
    }

    /// OBD-II services (modes) this app may send. All are read-only.
    /// 01 = current data, 03 = stored DTCs, 07 = pending DTCs, 09 = vehicle info, 0A = permanent DTCs.
    public static let allowedServices: Set<String> = ["01", "03", "07", "09", "0A"]

    /// Services that change vehicle state, named here only to give a clear error.
    static let knownWriteServices: [String: String] = [
        "04": "service 04 clears trouble codes and resets emissions monitors",
        "08": "service 08 requests control of an on-board system (actuator test)",
        "10": "diagnostic session control",
        "11": "ECU reset",
        "14": "clear diagnostic information",
        "27": "security access",
        "2E": "write data by identifier",
        "2F": "input/output control",
        "31": "routine control",
        "34": "request download (reflash)",
        "36": "transfer data (reflash)",
        "3B": "write data by local identifier",
        "3D": "write memory by address",
    ]

    /// Adapter (AT) commands allowed. These only affect the adapter's volatile state
    /// (formatting, echo) or read information. Commands that save to adapter memory
    /// (e.g. ATSP, ATPP, ATSD, AT@3) or put it in bus-monitoring/transmit modes are not allowed.
    public static let allowedATCommands: Set<String> = [
        "Z",     // reset adapter
        "WS",    // warm start
        "D",     // restore defaults (volatile)
        "E0", "E1", // echo off/on
        "L0", "L1", // linefeeds off/on
        "H0", "H1", // headers off/on
        "S0", "S1", // spaces off/on
        "I",     // identify
        "@1",    // device description
        "@2",    // device identifier (read)
        "DP", "DPN", // describe protocol
        "RV",    // read input voltage
        "AT0", "AT1", "AT2", // adaptive timing
    ]

    /// Validates and normalizes a command (uppercase, no spaces). Throws `Refusal` if not allowed.
    @discardableResult
    public static func validate(_ raw: String, permit: ClearCodesPermit? = nil) throws -> String {
        // A CR/LF would split one string into several adapter commands, so refuse it outright.
        if raw.contains(where: { $0.isNewline }) {
            throw Refusal(command: raw, reason: "contains a line break (would send more than one command)")
        }
        let cmd = raw.uppercased().filter { !$0.isWhitespace }
        guard !cmd.isEmpty else { throw Refusal(command: raw, reason: "empty command") }
        guard cmd.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "@") }) else {
            throw Refusal(command: raw, reason: "contains characters that are not allowed")
        }

        if cmd.hasPrefix("AT") {
            let body = String(cmd.dropFirst(2))
            if allowedATCommands.contains(body) { return cmd }
            // ATST xx (response timeout, volatile) is allowed with a 2-digit hex argument.
            if body.hasPrefix("ST"), body.count == 4, isHex(body.dropFirst(2)) { return cmd }
            throw Refusal(command: raw, reason: "adapter command AT\(body) is not on the read-only allowlist")
        }

        guard isHex(cmd), cmd.count >= 2, cmd.count % 2 == 0, cmd.count <= 8 else {
            throw Refusal(command: raw, reason: "not a recognised read-only OBD request")
        }
        let service = String(cmd.prefix(2))
        if cmd == "04", permit != nil { return cmd }   // the one permitted write: clear codes
        if let why = knownWriteServices[service] {
            throw Refusal(command: raw, reason: "\(why). This app is read-only.")
        }
        guard allowedServices.contains(service) else {
            throw Refusal(command: raw, reason: "OBD service \(service) is not on the read-only allowlist")
        }
        // Services 03, 07 and 0A take no parameters.
        if ["03", "07", "0A"].contains(service), cmd.count != 2 {
            throw Refusal(command: raw, reason: "service \(service) takes no parameters")
        }
        if ["01", "09"].contains(service), cmd.count != 4 {
            throw Refusal(command: raw, reason: "service \(service) requires exactly one PID byte")
        }
        return cmd
    }

    private static func isHex<S: StringProtocol>(_ s: S) -> Bool {
        !s.isEmpty && s.allSatisfy { $0.isHexDigit }
    }
}

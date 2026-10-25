import Foundation

/// Errors reported by an ELM327-compatible adapter (or detected while talking to one).
public enum OBDError: Error, Equatable, CustomStringConvertible {
    case noData                 // vehicle did not answer this request (often: PID unsupported)
    case unableToConnect        // adapter could not reach the vehicle bus (ignition off? wrong protocol?)
    case busError(String)       // BUS INIT/CAN ERROR/BUS BUSY etc.
    case adapterRejected        // "?" — adapter didn't understand the command
    case bufferFull
    case stopped
    case negativeResponse(service: UInt8, code: UInt8)
    case unexpected(String)
    case timeout
    case disconnected(String)

    public var description: String {
        switch self {
        case .noData: return "NO DATA (vehicle did not answer)"
        case .unableToConnect: return "Adapter is unable to connect to the vehicle bus. Is the ignition ON?"
        case .busError(let s): return "Bus error: \(s)"
        case .adapterRejected: return "Adapter rejected the command (?)"
        case .bufferFull: return "Adapter buffer full"
        case .stopped: return "Adapter stopped the request"
        case .negativeResponse(let s, let c): return String(format: "ECU negative response to service %02X (code %02X)", s, c)
        case .unexpected(let s): return "Unexpected response: \(s)"
        case .timeout: return "Timed out waiting for adapter"
        case .disconnected(let s): return "Disconnected: \(s)"
        }
    }

    /// True for errors that mean the link itself is unhealthy (vs. one request failing).
    public var isLinkFailure: Bool {
        switch self {
        case .timeout, .disconnected: return true
        default: return false
        }
    }
}

public enum ELMResponse {
    /// Turns raw adapter text (prompt already removed) into OBD messages (byte arrays).
    /// Handles spaces on/off, "SEARCHING...", "BUS INIT: ...OK" and ISO 15765 multi-frame
    /// output ("00A" byte-count line followed by "0:", "1:" ... lines).
    public static func parse(_ text: String) throws -> [[UInt8]] {
        var lines = text
            .replacingOccurrences(of: "\0", with: "")
            .components(separatedBy: CharacterSet(charactersIn: "\r\n"))
            .map { $0.trimmingCharacters(in: .whitespaces).uppercased() }
            .filter { !$0.isEmpty }

        lines = lines.compactMap { line -> String? in
            var l = line
            if l.hasPrefix("SEARCHING...") { l = String(l.dropFirst("SEARCHING...".count)) }
            if l.hasPrefix("BUS INIT:"), l.hasSuffix("OK") { return nil }
            if l.hasPrefix("BUS INIT:") && l.contains("...") && !l.contains("ERROR") { return nil }
            l = l.trimmingCharacters(in: .whitespaces)
            return l.isEmpty ? nil : l
        }

        for l in lines { try throwIfError(l) }

        // Some adapters (e.g. the Innova 3210RS, an ELM327 v1.3a) send CAN headers by default.
        if let headered = parseWithCANHeaders(lines) {
            if headered.isEmpty { throw OBDError.noData }
            return headered
        }

        var messages: [[UInt8]] = []
        var multi: (expected: Int, bytes: [UInt8])? = nil

        func flushMulti() {
            if let m = multi { messages.append(Array(m.bytes.prefix(m.expected))) }
            multi = nil
        }

        for line in lines {
            let compact = line.replacingOccurrences(of: " ", with: "")
            // Multi-frame byte count, e.g. "00A" or "014" (odd length => can't be a frame).
            if compact.count == 3, compact.allSatisfy(\.isHexDigit), let n = Int(compact, radix: 16) {
                flushMulti()
                multi = (n, [])
                continue
            }
            // Multi-frame continuation, e.g. "0:430401330420" or "0: 43 04 ..."
            if let colon = compact.firstIndex(of: ":") {
                let idx = compact[..<colon]
                let payload = String(compact[compact.index(after: colon)...])
                guard idx.count == 1, idx.allSatisfy(\.isHexDigit), let bytes = hexBytes(payload) else {
                    throw OBDError.unexpected(line)
                }
                if multi == nil { multi = (Int.max, []) }
                multi!.bytes += bytes
                continue
            }
            flushMulti()
            guard let bytes = hexBytes(compact) else { throw OBDError.unexpected(line) }
            messages.append(bytes)
        }
        flushMulti()
        if messages.isEmpty { throw OBDError.noData }
        return messages
    }

    /// Splits a reply line into (CAN header, frame bytes) if it carries an ECU response header:
    /// 11-bit "7E8".."7EF" or 29-bit "18DAF1xx". Returns nil for header-less lines.
    static func splitCANHeader(_ compact: String) -> (header: String, frame: [UInt8])? {
        if compact.count % 2 == 1, compact.count >= 5 {
            let h = String(compact.prefix(3))
            if h.hasPrefix("7E"), let last = h.last, "89ABCDEF".contains(last),
               let frame = hexBytes(String(compact.dropFirst(3))) { return (h, frame) }
        }
        if compact.count >= 10, compact.hasPrefix("18DAF1"), let frame = hexBytes(String(compact.dropFirst(8))) {
            return (String(compact.prefix(8)), frame)
        }
        return nil
    }

    /// Reassembles ISO 15765-2 frames from header-bearing lines (one message per ECU header).
    /// Returns nil when the lines don't carry headers.
    static func parseWithCANHeaders(_ lines: [String]) -> [[UInt8]]? {
        let split = lines.map { splitCANHeader($0.replacingOccurrences(of: " ", with: "")) }
        guard !split.isEmpty, split.allSatisfy({ $0 != nil }) else { return nil }
        var order: [String] = []
        var partial: [String: (expected: Int, bytes: [UInt8])] = [:]
        var done: [String: [[UInt8]]] = [:]
        for case let (header, frame)? in split {
            guard let pci = frame.first else { continue }
            if !order.contains(header) { order.append(header) }
            switch pci >> 4 {
            case 0x0:   // single frame
                let n = Int(pci & 0x0F)
                done[header, default: []].append(Array(frame.dropFirst().prefix(n)))
            case 0x1:   // first frame
                guard frame.count >= 2 else { continue }
                let n = Int(pci & 0x0F) << 8 | Int(frame[1])
                partial[header] = (n, Array(frame.dropFirst(2)))
            case 0x2:   // consecutive frame
                guard var p = partial[header] else { continue }
                p.bytes += frame.dropFirst()
                if p.bytes.count >= p.expected {
                    done[header, default: []].append(Array(p.bytes.prefix(p.expected)))
                    partial[header] = nil
                } else { partial[header] = p }
            default: continue   // flow control etc.
            }
        }
        for (h, p) in partial { done[h, default: []].append(p.bytes) }   // incomplete: keep what arrived
        return order.flatMap { done[$0] ?? [] }
    }

    static func throwIfError(_ l: String) throws {
        if l.contains("NO DATA") { throw OBDError.noData }
        if l.contains("UNABLE TO CONNECT") { throw OBDError.unableToConnect }
        if l == "?" { throw OBDError.adapterRejected }
        if l.contains("BUFFER FULL") { throw OBDError.bufferFull }
        if l.contains("STOPPED") { throw OBDError.stopped }
        for marker in ["CAN ERROR", "BUS ERROR", "BUS BUSY", "FB ERROR", "DATA ERROR", "BUS INIT", "ERR", "LV RESET", "ACT ALERT", "LP ALERT"]
        where l.contains(marker) {
            throw OBDError.busError(l)
        }
    }

    static func hexBytes(_ s: String) -> [UInt8]? {
        guard s.count % 2 == 0, !s.isEmpty, s.allSatisfy(\.isHexDigit) else { return nil }
        var out: [UInt8] = []
        var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            out.append(UInt8(s[i..<j], radix: 16)!)
            i = j
        }
        return out
    }

    /// Extracts the data bytes for a service 01 PID from parsed messages
    /// (first message that starts with 41 <pid>). Throws on negative response.
    public static func pidData(_ messages: [[UInt8]], pid: UInt8, service: UInt8 = 0x01) throws -> [UInt8] {
        let positive = service + 0x40
        for m in messages where m.count >= 2 && m[0] == positive && m[1] == pid {
            return Array(m.dropFirst(2))
        }
        if let neg = messages.first(where: { $0.count >= 3 && $0[0] == 0x7F && $0[1] == service }) {
            throw OBDError.negativeResponse(service: service, code: neg[2])
        }
        throw OBDError.unexpected(messages.map { $0.map { String(format: "%02X", $0) }.joined(separator: " ") }.joined(separator: " | "))
    }
}

/// ELM327 protocol numbers (as returned by ATDPN; an "A" prefix means auto-detected).
public enum ELMProtocol {
    static let names: [Character: String] = [
        "1": "SAE J1850 PWM (41.6 kbaud)", "2": "SAE J1850 VPW (10.4 kbaud)",
        "3": "ISO 9141-2", "4": "ISO 14230-4 KWP (5 baud init)", "5": "ISO 14230-4 KWP (fast init)",
        "6": "ISO 15765-4 CAN (11 bit, 500 kbaud)", "7": "ISO 15765-4 CAN (29 bit, 500 kbaud)",
        "8": "ISO 15765-4 CAN (11 bit, 250 kbaud)", "9": "ISO 15765-4 CAN (29 bit, 250 kbaud)",
        "A": "SAE J1939 CAN", "B": "User1 CAN", "C": "User2 CAN",
    ]

    public static func name(for dpn: String) -> String? {
        var p = dpn.uppercased().trimmingCharacters(in: .whitespaces)
        var auto = false
        if p.count == 2, p.hasPrefix("A") { p.removeFirst(); auto = true }
        guard p.count == 1, let c = p.first, let n = names[c] else { return nil }
        return (auto ? "Auto: " : "") + n
    }
}

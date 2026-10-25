import Foundation

/// Settings for the built-in simulated adapter + vehicle. Nothing here comes from a real car.
public struct SimulatorOptions: Sendable {
    /// false = "ignition off": adapter answers AT commands but the vehicle never responds.
    public var vehicleResponds = true
    /// ELM327 protocol number reported by ATDPN. 6 = ISO 15765-4 CAN 11-bit/500k; 1 = SAE J1850 PWM.
    public var protocolNumber = 6
    public var storedDTCs = ["P0171", "P0174", "P0455"]
    public var pendingDTCs = ["P0300"]
    /// Service 0A (permanent DTCs) answered with NO DATA when false (typical for older vehicles).
    public var supportsPermanentDTCs = false
    /// false = engine off with ignition ON (RPM 0, speed 0). Can also be changed live via `setEngineRunning`.
    public var engineRunning = true
    /// true = the simulated ECU answers a clear request with a negative response (7F 04 22).
    public var rejectsClear = false
    public var responseDelay: TimeInterval = 0.02
    public init() {}
}

/// Text-level ELM327 emulator. Produces the same kind of output a real adapter does,
/// so the parser and engine are exercised exactly as they would be with hardware.
public final class ELM327Emulator: @unchecked Sendable {
    public let options: SimulatorOptions
    private let lock = NSLock()
    private var echo = true, linefeeds = false, spaces = true
    private let start = Date()
    private var stft1 = 0.0, stft2 = 0.0
    /// Every command received, for tests (e.g. to prove no write command was ever sent).
    public private(set) var receivedCommands: [String] = []
    private var stored: [String]
    private var pending: [String]
    private var engineRunning: Bool

    /// Simulates turning the engine off/on while the ignition stays ON.
    public func setEngineRunning(_ on: Bool) { lock.withLock { engineRunning = on } }
    public var isEngineRunning: Bool { lock.withLock { engineRunning } }

    // PID 0x0B (MAP) is deliberately advertised but answered with NO DATA to exercise
    // unsupported-PID handling. 0x46 (ambient) is not advertised at all.
    static let advertised: Set<UInt8> = [0x01, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0B, 0x0C, 0x0D,
                                         0x0E, 0x0F, 0x10, 0x11, 0x13, 0x15, 0x1C, 0x1F, 0x20,
                                         0x21, 0x2F, 0x33, 0x40, 0x42]
    static let answersNoData: Set<UInt8> = [0x0B]

    public init(options: SimulatorOptions = .init()) {
        self.options = options
        stored = options.storedDTCs; pending = options.pendingDTCs; engineRunning = options.engineRunning
    }

    /// Handles one command line (without CR) and returns the full reply including the '>' prompt.
    public func handle(_ rawLine: String) -> String {
        lock.lock(); defer { lock.unlock() }
        let cmd = rawLine.uppercased().filter { !$0.isWhitespace }
        receivedCommands.append(cmd)
        let eol = linefeeds ? "\r\n" : "\r"
        var lines: [String]
        let echoed = echo ? rawLine + eol : ""

        if cmd.hasPrefix("AT") {
            lines = handleAT(String(cmd.dropFirst(2)))
        } else {
            lines = handleOBD(cmd)
        }
        return echoed + lines.map { $0 + eol }.joined() + eol + ">"
    }

    private func handleAT(_ body: String) -> [String] {
        switch body {
        case "Z", "WS", "D":
            echo = true; linefeeds = false; spaces = true
            return ["", "ELM327 v1.5 (SIMULATOR)"]
        case "E0": echo = false; return ["OK"]
        case "E1": echo = true; return ["OK"]
        case "L0": linefeeds = false; return ["OK"]
        case "L1": linefeeds = true; return ["OK"]
        case "S0": spaces = false; return ["OK"]
        case "S1": spaces = true; return ["OK"]
        case "H0", "H1", "AT0", "AT1", "AT2": return ["OK"]
        case "I": return ["ELM327 v1.5 (SIMULATOR)"]
        case "@1": return ["MustangOBD built-in simulator"]
        case "@2": return ["?"]
        case "RV": return [options.vehicleResponds ? "14.1V" : "12.5V"]
        case "DPN": return ["A\(options.protocolNumber)"]
        case "DP": return [options.protocolNumber >= 6 ? "AUTO, ISO 15765-4 (CAN 11/500)" : "AUTO, SAE J1850 PWM"]
        default:
            if body.hasPrefix("ST") { return ["OK"] }
            return ["?"]
        }
    }

    private func fmt(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02X", $0) }.joined(separator: spaces ? " " : "")
    }

    private func handleOBD(_ cmd: String) -> [String] {
        guard cmd.count >= 2, cmd.count % 2 == 0, let bytes = ELMResponse.hexBytes(cmd) else { return ["?"] }
        guard options.vehicleResponds else { return ["SEARCHING...", "UNABLE TO CONNECT"] }
        let service = bytes[0]
        switch service {
        case 0x01:
            guard bytes.count == 2 else { return ["NO DATA"] }
            guard let data = pidData(bytes[1]) else { return ["NO DATA"] }
            return [fmt([0x41, bytes[1]] + data)]
        case 0x03: return dtcLines(service: 0x03, codes: stored)
        case 0x07: return dtcLines(service: 0x07, codes: pending)
        case 0x04:
            guard bytes.count == 1 else { return ["NO DATA"] }
            if options.rejectsClear || engineRunning { return [fmt([0x7F, 0x04, 0x22])] }
            stored = []; pending = []
            return [fmt([0x44])]
        case 0x0A: return options.supportsPermanentDTCs ? dtcLines(service: 0x0A, codes: []) : [fmt([0x7F, 0x0A, 0x11])]   // as the 2005 Mustang answers
        default:
            // A real ECU may reject unknown services; the app never sends them anyway.
            return ["NO DATA"]
        }
    }

    private func bitmap(base: UInt8) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 4)
        for pid in Self.advertised where pid > base && pid <= base &+ 32 {
            let n = Int(pid - base - 1)
            out[n / 8] |= 0x80 >> UInt8(n % 8)
        }
        return out
    }

    private func pidData(_ pid: UInt8) -> [UInt8]? {
        if [0x00, 0x20, 0x40].contains(pid) {
            guard pid == 0 || Self.advertised.contains(pid) else { return nil }
            return bitmap(base: pid)
        }
        guard Self.advertised.contains(pid), !Self.answersNoData.contains(pid) else { return nil }
        let s = state()
        func u8(_ v: Double) -> UInt8 { UInt8(max(0, min(255, v.rounded()))) }
        func u16(_ v: Double) -> [UInt8] { let i = Int(max(0, min(65535, v.rounded()))); return [UInt8(i >> 8), UInt8(i & 0xFF)] }
        func trim(_ pct: Double) -> UInt8 { u8(pct * 128 / 100 + 128) }
        switch pid {
        case 0x01:
            let n = stored.count
            return [UInt8(n > 0 ? 0x80 : 0) | UInt8(min(n, 127)), 0x07, 0xE5, 0x00]
        case 0x03: return [0x02, 0x00]
        case 0x04: return [u8(s.load * 255 / 100)]
        case 0x05: return [u8(s.coolant + 40)]
        case 0x06: return [trim(stft1)]
        case 0x07: return [trim(3.1)]
        case 0x08: return [trim(stft2)]
        case 0x09: return [trim(1.6)]
        case 0x0C: return u16(s.rpm * 4)
        case 0x0D: return [u8(s.speedKmh)]
        case 0x0E: return [u8((s.timing + 64) * 2)]
        case 0x0F: return [u8(s.iat + 40)]
        case 0x10: return u16(s.maf * 100)
        case 0x11: return [u8(s.throttle * 255 / 100)]
        case 0x13: return [0x33]
        case 0x15: return [0x5A, 0x80]
        case 0x1C: return [0x01]
        case 0x1F: return u16(s.t)
        case 0x21: return [0x00, 0x00]
        case 0x2F: return [u8(62 * 255 / 100)]
        case 0x33: return [101]
        case 0x42: return u16(14.1 * 1000 + sin(s.t) * 60)
        default: return nil
        }
    }

    private func dtcLines(service: UInt8, codes: [String]) -> [String] {
        let pairs: [[UInt8]] = codes.compactMap(Self.encode)
        if options.protocolNumber >= 6 {
            // CAN: [4x, count, A, B, ...]; more than 7 bytes => ISO-TP multi-frame layout.
            let msg = [service + 0x40, UInt8(pairs.count)] + pairs.flatMap { $0 }
            if msg.count <= 7 { return [fmt(msg)] }
            var out = [String(format: "%03X", msg.count)]
            var rest = msg, idx = 0
            var chunk = Array(rest.prefix(6)); rest = Array(rest.dropFirst(6))
            out.append("\(idx): " + fmt(chunk))
            while !rest.isEmpty {
                idx = (idx + 1) % 16
                chunk = Array(rest.prefix(7)); rest = Array(rest.dropFirst(7))
                chunk += [UInt8](repeating: 0x00, count: 7 - chunk.count)
                out.append("\(String(idx, radix: 16).uppercased()): " + fmt(chunk))
            }
            return out
        } else {
            // Non-CAN: 3 codes per frame, zero padded; at least one frame.
            var out: [String] = []
            var flat = pairs.flatMap { $0 }
            repeat {
                var chunk = Array(flat.prefix(6)); flat = Array(flat.dropFirst(6))
                chunk += [UInt8](repeating: 0, count: 6 - chunk.count)
                out.append(fmt([service + 0x40] + chunk))
            } while !flat.isEmpty
            return out
        }
    }

    static func encode(_ code: String) -> [UInt8]? {
        let c = Array(code.uppercased())
        guard c.count == 5, let li = ["P", "C", "B", "U"].firstIndex(of: String(c[0])),
              let d1 = Int(String(c[1]), radix: 16), d1 < 4,
              let rest = Int(String(c[2...]), radix: 16) else { return nil }
        let a = UInt8(li << 6) | UInt8(d1 << 4) | UInt8(rest >> 8)
        return [a, UInt8(rest & 0xFF)]
    }

    // MARK: - Vehicle model (made-up but plausible values)

    struct State { var t, speedKmh, rpm, throttle, load, coolant, iat, maf, timing: Double }

    private func state() -> State {
        let t = Date().timeIntervalSince(start)
        let c = t.truncatingRemainder(dividingBy: 120)
        let mph: Double
        var throttle: Double, load: Double
        switch c {
        case ..<20: mph = 0; throttle = 14.5; load = 21
        case ..<35: mph = (c - 20) / 15 * 45; throttle = 38; load = 62
        case ..<70: mph = 45 + 2.5 * sin(c / 4); throttle = 21; load = 33
        case ..<80: mph = 45 + (c - 70) / 10 * 20; throttle = 44; load = 68
        case ..<100: mph = 65 + 1.5 * sin(c / 3); throttle = 24; load = 37
        case ..<115: mph = 65 - (c - 100) / 15 * 65; throttle = 12; load = 14
        default: mph = 0; throttle = 14.5; load = 21
        }
        let kmh = mph / 0.621371
        let jitter = Double.random(in: -1...1)
        var rpm = mph < 1 ? 700 + 25 * jitter : 900 + kmh * 15 + (throttle > 30 ? 600 : 0) + 20 * jitter
        if !engineRunning { rpm = 0 }
        throttle += 0.4 * jitter
        stft1 = max(-8, min(8, stft1 + Double.random(in: -0.8...0.8)))
        stft2 = max(-8, min(8, stft2 + Double.random(in: -0.8...0.8)))
        let coolant = 25 + (91 - 25) * (1 - exp(-t / 240))
        let iat = 24 + 6 * (1 - exp(-t / 400)) + (mph < 1 ? 4 : 0)
        let maf = rpm * load / 100 * 0.035
        let timing = mph < 1 ? 14 + jitter : 22 + (1 - load / 100) * 14
        if !engineRunning {   // key on, engine off: parked, nothing flowing
            return State(t: t, speedKmh: 0, rpm: 0, throttle: 14.5, load: 0, coolant: 25 + (91 - 25) * (1 - exp(-t / 240)),
                         iat: 24, maf: 0, timing: 0)
        }
        return State(t: t, speedKmh: kmh, rpm: rpm, throttle: throttle, load: load,
                     coolant: coolant, iat: iat, maf: maf, timing: timing)
    }
}

/// Transport that talks to the in-process emulator. Always labeled simulated.
public final class SimulatedTransport: OBDTransport, @unchecked Sendable {
    public let emulator: ELM327Emulator
    public var displayName: String { "Simulator (no hardware)" }
    public var isSimulated: Bool { true }
    private let queue = DispatchQueue(label: "obd.simulator")
    private var onData: ((Data) -> Void)?
    private var onClose: ((String) -> Void)?
    private var pending = ""
    private var dead = false

    public init(options: SimulatorOptions = .init()) { emulator = ELM327Emulator(options: options) }

    public func open(onData: @escaping (Data) -> Void, onClose: @escaping (String) -> Void) async throws {
        queue.sync { self.onData = onData; self.onClose = onClose; self.dead = false }
    }

    public func write(_ data: Data) async throws {
        let delay = emulator.options.responseDelay
        queue.async {
            guard !self.dead else { return }
            self.pending += String(decoding: data, as: UTF8.self)
            while let r = self.pending.firstIndex(of: "\r") {
                let line = String(self.pending[..<r])
                self.pending = String(self.pending[self.pending.index(after: r)...])
                let reply = self.emulator.handle(line)
                self.queue.asyncAfter(deadline: .now() + delay) {
                    guard !self.dead else { return }
                    self.onData?(Data(reply.utf8))
                }
            }
        }
    }

    /// Test/demo hook: behave like the adapter suddenly vanished (e.g. unplugged).
    public func simulateDropout() {
        queue.async {
            guard !self.dead else { return }
            self.dead = true
            self.onClose?("simulated dropout")
        }
    }

    public func close() { queue.async { self.dead = true; self.onData = nil } }
}

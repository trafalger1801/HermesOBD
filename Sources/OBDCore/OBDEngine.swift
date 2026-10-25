import Foundation

public enum ConnectionPhase: Equatable, Sendable {
    case idle
    case connecting(String)                 // opening the transport
    case initializingAdapter                // transport open, waiting for ELM327 reply
    case waitingForVehicle(adapter: String) // adapter answered; vehicle has not (yet)
    case live(simulated: Bool)              // vehicle data has actually been decoded
    case reconnecting(attempt: Int, reason: String)
    case stopped

    public var isLive: Bool { if case .live = self { return true }; return false }
}

public struct PIDReading: Sendable, Equatable {
    public let pid: UInt8
    public let value: Double   // metric, as defined by SAE J1979
    public let at: Date
}

public struct AdapterInfo: Sendable, Equatable {
    public var identity: String?
    public var description: String?
    public var protocolName: String?
    public var protocolNumber: String?
    public var voltage: String?
    public init() {}
}

public enum PIDStatus: Sendable, Equatable {
    case unknown
    case supported
    case notAdvertised          // ECU's supported-PID bitmap says no
    case noResponse             // advertised but repeatedly answered NO DATA
}

public enum EngineEvent: Sendable {
    case phase(ConnectionPhase)
    case adapterInfo(AdapterInfo)
    case pidStatus([UInt8: PIDStatus])
    case readings([PIDReading])          // one polling cycle
    case dtcReport(DTCReport)
    case clearResult(ClearReport)        // outcome of a clear-codes request
    case message(String)                 // user-facing status/error note
    case traffic(String)                 // raw adapter traffic
}

/// Drives the whole conversation: connect, init, verify vehicle, poll, reconnect.
/// All adapter I/O happens on one task, so commands never interleave.
public final class OBDEngine: @unchecked Sendable {
    public struct Config: Sendable {
        public var pids: [PIDDefinition] = PIDCatalog.all
        public var pidTimeout: TimeInterval = 2.0
        public var vehicleSearchTimeout: TimeInterval = 15.0
        public var slowPollEvery = 5          // poll non-fast PIDs every Nth cycle
        public var noDataLimit = 3            // NO DATA answers before a PID is marked unsupported
        public var linkFailureLimit = 3       // consecutive timeouts before reconnecting
        public var maxBackoff: TimeInterval = 15
        public var cyclePause: TimeInterval = 0.05
        public var autoReconnect = true
        public init() {}
    }

    private let makeTransport: () -> OBDTransport
    private let config: Config
    private let emit: @Sendable (EngineEvent) -> Void
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var session: ELM327Session?
    private var dtcRequested = false

    public init(config: Config = .init(), makeTransport: @escaping () -> OBDTransport, onEvent: @escaping @Sendable (EngineEvent) -> Void) {
        self.config = config
        self.makeTransport = makeTransport
        self.emit = onEvent
    }

    public func start() {
        lock.lock(); defer { lock.unlock() }
        guard task == nil else { return }
        task = Task.detached { [weak self] in await self?.run() }
    }

    public func stop() {
        lock.lock()
        let t = task; task = nil
        let s = session; session = nil
        lock.unlock()
        t?.cancel()
        s?.close()
        emit(.phase(.stopped))
    }

    /// Queues a trouble-code read; serviced between polling cycles.
    public func requestDTCRead() { lock.lock(); dtcRequested = true; lock.unlock() }

    private func takeDTCRequest() -> Bool { lock.lock(); defer { lock.unlock() }; let r = dtcRequested; dtcRequested = false; return r }

    private var clearRequested = false

    /// Queues one clear-codes attempt. The engine re-checks its safety conditions right
    /// before sending, and refuses (without sending anything) if they aren't met.
    public func requestClearCodes() { lock.withLock { clearRequested = true } }

    private func takeClearRequest() -> Bool { lock.withLock { let r = clearRequested; clearRequested = false; return r } }

    /// Engine speed below this counts as "engine off".
    public static let engineOffRPM: Double = 100

    // MARK: - Main loop

    private func run() async {
        var attempt = 0
        while !Task.isCancelled {
            let transport = makeTransport()
            let s = ELM327Session(transport: transport)
            s.trafficLog = { [emit] line in emit(.traffic(line)) }
            lock.withLock { session = s }
            var reason = "unknown error"
            var gotLiveData = false
            do {
                try await connectAndPoll(s, onLive: { gotLiveData = true })
                reason = "link closed"
            } catch is CancellationError {
                break
            } catch {
                reason = "\(error)"
            }
            s.close()
            if Task.isCancelled { break }
            emit(.message("Connection problem: \(reason)"))
            guard config.autoReconnect else { emit(.phase(.stopped)); break }
            attempt = gotLiveData ? 1 : attempt + 1
            emit(.phase(.reconnecting(attempt: attempt, reason: reason)))
            let delay = min(config.maxBackoff, pow(2, Double(min(attempt, 4))))
            do { try await Task.sleep(nanoseconds: UInt64(delay * 1e9)) } catch { break }
        }
    }

    private func connectAndPoll(_ s: ELM327Session, onLive: () -> Void) async throws {
        var simulated = s.transport.isSimulated
        emit(.phase(.connecting(s.transport.displayName)))
        try await s.open()
        emit(.phase(.initializingAdapter))

        // Adapter setup. These only touch the adapter's volatile settings.
        var info = AdapterInfo()
        let reset = try await s.send("ATZ", timeout: 5)
        info.identity = reset.split(separator: "\n").last.map(String.init)
        for cmd in ["ATE0", "ATL0", "ATS1", "ATH0"] {
            _ = try await s.send(cmd, timeout: 2)
        }
        if let id = try? await s.send("ATI"), !id.isEmpty, id != "?" { info.identity = id }
        if let d = try? await s.send("AT@1"), !d.isEmpty, d != "?" { info.description = d }
        if let v = try? await s.send("ATRV"), !v.isEmpty, v != "?" { info.voltage = v }
        // The built-in emulator can also be served over TCP/serial (obd-cli emulate). It identifies
        // itself, so its data is still labeled simulated even though the transport is real.
        if [info.identity, info.description].contains(where: { $0?.uppercased().contains("SIMULATOR") == true }) {
            if !simulated { emit(.message("Adapter identifies itself as the HermesOBD simulator — data will be labeled SIMULATED.")) }
            simulated = true
        }
        emit(.adapterInfo(info))
        emit(.phase(.waitingForVehicle(adapter: info.identity ?? "unknown adapter")))

        // Ask the vehicle which PIDs it supports. This is the first vehicle data we accept.
        var supported = Set<UInt8>()
        var base: UInt8 = 0x00
        while true {
            let cmd = String(format: "01%02X", base)
            let messages: [[UInt8]]
            do {
                messages = try await s.request(cmd, timeout: base == 0 ? config.vehicleSearchTimeout : config.pidTimeout)
            } catch let e as OBDError where base == 0 {
                if e == .unableToConnect || e == .noData {
                    throw TransportError("adapter answered, but the vehicle did not respond (\(e)). Turn the ignition to ON / start the engine.")
                }
                throw e
            } catch {
                break // a later bitmap failing just means no more ranges
            }
            let bitmap = try ELMResponse.pidData(messages, pid: base)
            supported.formUnion(PIDCatalog.supportedPIDs(base: base, bitmap: bitmap))
            let next = base &+ 0x20
            guard base < 0xC0, supported.contains(next) else { break }
            base = next
        }

        // ATDPN only. Some ELM327 clones (e.g. the Innova 3210RS, v1.3a) treat ATDP like ATD
        // ("restore defaults"), which silently turns headers back on.
        if let dpn = try? await s.send("ATDPN") {
            info.protocolNumber = dpn
            info.protocolName = ELMProtocol.name(for: dpn)
        }
        emit(.adapterInfo(info))

        var status: [UInt8: PIDStatus] = [:]
        for p in config.pids { status[p.pid] = supported.contains(p.pid) ? .supported : .notAdvertised }
        emit(.pidStatus(status))
        emit(.message("Vehicle responded. \(supported.count) PIDs advertised; protocol: \(info.protocolName ?? "?")."))

        var noData: [UInt8: Int] = [:]
        var linkFailures = 0
        var announcedLive = false
        var cycle = 0

        while true {
            try Task.checkCancellation()
            if s.isClosed { throw OBDError.disconnected("link closed") }

            if takeDTCRequest() {
                emit(.dtcReport(try await readDTCs(s, isCAN: DTCParser.isCAN(protocolNumber: info.protocolNumber), simulated: simulated)))
            }
            if takeClearRequest() {
                let r = try await clearCodes(s, isCAN: DTCParser.isCAN(protocolNumber: info.protocolNumber), simulated: simulated)
                if let after = r.codesAfter { emit(.dtcReport(after)) }
                emit(.clearResult(r))
            }

            var readings: [PIDReading] = []
            let includeSlow = cycle % max(1, config.slowPollEvery) == 0
            for p in config.pids where status[p.pid] == .supported && (p.fast || includeSlow) {
                do {
                    let msgs = try await s.request(p.command, timeout: config.pidTimeout)
                    let data = try ELMResponse.pidData(msgs, pid: p.pid)
                    guard let v = p.decode(data) else { throw OBDError.unexpected("short reply for \(p.command)") }
                    readings.append(PIDReading(pid: p.pid, value: v, at: Date()))
                    noData[p.pid] = 0
                    linkFailures = 0
                } catch let e as OBDError {
                    if e.isLinkFailure {
                        linkFailures += 1
                        if linkFailures >= config.linkFailureLimit || s.isClosed { throw e }
                    } else if e == .noData || { if case .negativeResponse = e { return true }; return false }() {
                        noData[p.pid, default: 0] += 1
                        if noData[p.pid]! >= config.noDataLimit {
                            status[p.pid] = .noResponse
                            emit(.pidStatus(status))
                            emit(.message("\(p.name) (PID \(String(format: "%02X", p.pid))) gave no data \(config.noDataLimit)× — marked unsupported."))
                        }
                    } else if e == .unableToConnect {
                        throw TransportError("vehicle stopped responding (\(e))")
                    } else {
                        emit(.message("\(p.name): \(e)"))
                    }
                }
            }

            if !readings.isEmpty {
                if !announcedLive { announcedLive = true; onLive(); emit(.phase(.live(simulated: simulated))) }
                emit(.readings(readings))
            } else if status.values.contains(.supported) == false {
                throw TransportError("vehicle answers but none of the dashboard PIDs are supported")
            }

            cycle += 1
            if cycle % 20 == 0, let v = try? await s.send("ATRV"), !v.isEmpty {
                info.voltage = v
                emit(.adapterInfo(info))
            }
            try await Task.sleep(nanoseconds: UInt64(config.cyclePause * 1e9))
        }
    }

    private func readDTCs(_ s: ELM327Session, isCAN: Bool?, simulated: Bool) async throws -> DTCReport {
        var report = DTCReport(milOn: nil, reportedCount: nil, stored: .failed("not read"), pending: .failed("not read"),
                               permanent: .failed("not read"), readAt: Date(), simulated: simulated)
        if let m = try? await s.request("0101"), let d = try? ELMResponse.pidData(m, pid: 0x01), let a = d.first {
            report.milOn = a & 0x80 != 0
            report.reportedCount = Int(a & 0x7F)
        }
        func section(_ service: UInt8, noDataMeansEmpty: Bool) async throws -> DTCReport.Section {
            do {
                let msgs = try await s.request(String(format: "%02X", service), timeout: 5)
                let answered = msgs.contains { $0.first == service + 0x40 }
                if !answered, let neg = msgs.first(where: { $0.count >= 3 && $0[0] == 0x7F && $0[1] == service }) {
                    throw OBDError.negativeResponse(service: service, code: neg[2])
                }
                return .codes(DTCParser.parse(messages: msgs, service: service, isCAN: isCAN))
            } catch let e as OBDError {
                if e.isLinkFailure { throw e }
                if e == .noData { return noDataMeansEmpty ? .codes([]) : .notSupported("no response — not supported by this vehicle, or none stored") }
                if case .negativeResponse(_, let code) = e, code == 0x11 || code == 0x12 { return .notSupported("not supported by this vehicle") }
                return .failed(e.description)
            }
        }
        // Many ECUs answer NO DATA to 03/07 when nothing is stored.
        report.stored = try await section(0x03, noDataMeansEmpty: true)
        report.pending = try await section(0x07, noDataMeansEmpty: true)
        report.permanent = try await section(0x0A, noDataMeansEmpty: false)
        report.readAt = Date()
        return report
    }

    // MARK: - Clear codes (the one write the app can do)

    private func clearCodes(_ s: ELM327Session, isCAN: Bool?, simulated: Bool) async throws -> ClearReport {
        var report = ClearReport(outcome: .refused("not attempted"), at: Date(), simulated: simulated)

        // 1. Record what is about to be erased.
        report.codesBefore = try await readDTCs(s, isCAN: isCAN, simulated: simulated)

        // 2. Safety check, read fresh right now: vehicle stopped and engine off.
        func readValue(_ pid: UInt8) async -> Double? {
            guard let def = PIDCatalog.definition(for: pid),
                  let m = try? await s.request(def.command),
                  let d = try? ELMResponse.pidData(m, pid: pid) else { return nil }
            return def.decode(d)
        }
        let speed = await readValue(0x0D)
        let rpm = await readValue(0x0C)
        report.speedKmh = speed; report.rpm = rpm
        guard let speed, let rpm else {
            report.outcome = .refused("Couldn't confirm the car is stopped with the engine off (speed or RPM unreadable). Nothing was sent.")
            return report
        }
        guard speed == 0 else {
            report.outcome = .refused("The vehicle is moving. Nothing was sent.")
            return report
        }
        guard rpm < Self.engineOffRPM else {
            report.outcome = .refused(String(format: "The engine is running (%.0f rpm). Turn the engine off, leave the ignition ON, and try again. Nothing was sent.", rpm))
            return report
        }

        // 3. Send the single permitted write.
        emit(.message("Clearing trouble codes (service 04)…"))
        let reply: [[UInt8]]
        do {
            reply = try await ELMResponse.parse(s.send("04", timeout: 10, permit: ReadOnlyGuard.ClearCodesPermit()))
        } catch let e as OBDError {
            if e.isLinkFailure { throw e }
            reply = []
            report.outcome = .failed("No confirmation from the ECU (\(e)).")
        }
        if reply.contains(where: { $0.first == 0x44 }) {
            report.outcome = .cleared
        } else if let neg = reply.first(where: { $0.count >= 3 && $0[0] == 0x7F && $0[1] == 0x04 }) {
            let why = neg[2] == 0x22 ? "conditions not correct — usually means the engine is running" : String(format: "code %02X", neg[2])
            report.outcome = .ecuRejected("The ECU refused to clear codes (\(why)).")
        } else if case .refused = report.outcome {
            report.outcome = .failed("Unexpected reply to the clear request.")
        }

        // 4. Re-read to show what actually happened.
        try await Task.sleep(nanoseconds: 1_500_000_000)
        report.codesAfter = try await readDTCs(s, isCAN: isCAN, simulated: simulated)
        report.at = Date()
        return report
    }
}

public struct ClearReport: Sendable, Equatable {
    public enum Outcome: Sendable, Equatable {
        case cleared                 // ECU confirmed (positive response 44)
        case refused(String)         // app's safety check failed; nothing was sent
        case ecuRejected(String)     // ECU answered with a negative response
        case failed(String)          // sent, but no clear confirmation
    }
    public var outcome: Outcome
    public var at: Date
    public var simulated: Bool
    public var codesBefore: DTCReport?
    public var codesAfter: DTCReport?
    public var speedKmh: Double?
    public var rpm: Double?

    /// Whether the "04" command was actually sent to the vehicle.
    public var commandSent: Bool {
        switch outcome { case .refused: return false; default: return true }
    }
}

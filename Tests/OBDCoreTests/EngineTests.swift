import Testing
import Foundation
@testable import OBDCore

/// Collects engine events for assertions.
final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [EngineEvent] = []
    var events: [EngineEvent] { lock.withLock { _events } }
    func add(_ e: EngineEvent) { lock.withLock { _events.append(e) } }
    var phases: [ConnectionPhase] { events.compactMap { if case .phase(let p) = $0 { return p }; return nil } }
    var readings: [[PIDReading]] { events.compactMap { if case .readings(let r) = $0 { return r }; return nil } }
    var lastStatus: [UInt8: PIDStatus]? { events.compactMap { if case .pidStatus(let s) = $0 { return s }; return nil }.last }
    var dtc: DTCReport? { events.compactMap { if case .dtcReport(let d) = $0 { return d }; return nil }.last }

    func wait(timeout: TimeInterval = 10, until cond: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end { if cond() { return true }; try? await Task.sleep(nanoseconds: 20_000_000) }
        return cond()
    }
}

func fastConfig() -> OBDEngine.Config {
    var c = OBDEngine.Config()
    c.cyclePause = 0.01
    c.maxBackoff = 0.2
    c.vehicleSearchTimeout = 2
    return c
}

func fastSim(_ tweak: (inout SimulatorOptions) -> Void = { _ in }) -> SimulatorOptions {
    var o = SimulatorOptions(); o.responseDelay = 0.001; tweak(&o); return o
}

@Suite("Engine with simulator", .serialized)
struct EngineTests {
    @Test func reachesLiveAndDecodes() async {
        let rec = Recorder()
        let engine = OBDEngine(config: fastConfig(), makeTransport: { SimulatedTransport(options: fastSim()) }, onEvent: rec.add)
        engine.start()
        #expect(await rec.wait { rec.readings.count >= 3 })
        engine.stop()
        #expect(rec.phases.contains(.live(simulated: true)))
        // Live is only announced after adapter init + vehicle check.
        let idxLive = rec.phases.firstIndex(of: .live(simulated: true))!
        #expect(rec.phases[..<idxLive].contains(.initializingAdapter))
        let rpm = rec.readings.last!.first { $0.pid == 0x0C }
        #expect(rpm != nil && rpm!.value > 500 && rpm!.value < 4000)
    }

    @Test func unsupportedPIDsAreMarked() async {
        let rec = Recorder()
        let engine = OBDEngine(config: fastConfig(), makeTransport: { SimulatedTransport(options: fastSim()) }, onEvent: rec.add)
        engine.start()
        #expect(await rec.wait { rec.lastStatus?[0x0B] == .noResponse })
        engine.stop()
        #expect(rec.lastStatus?[0x46] == .notAdvertised)   // not in bitmap
        #expect(rec.lastStatus?[0x0B] == .noResponse)      // advertised, but NO DATA
        #expect(rec.lastStatus?[0x0C] == .supported)
    }

    @Test func neverLiveWhenVehicleSilent() async {
        let rec = Recorder()
        let engine = OBDEngine(config: fastConfig(), makeTransport: { SimulatedTransport(options: fastSim { $0.vehicleResponds = false }) }, onEvent: rec.add)
        engine.start()
        #expect(await rec.wait { rec.phases.contains { if case .reconnecting = $0 { return true }; return false } })
        engine.stop()
        #expect(!rec.phases.contains { $0.isLive })
        #expect(rec.readings.isEmpty)
        #expect(rec.phases.contains { if case .waitingForVehicle = $0 { return true }; return false })
    }

    @Test func readsDTCsCAN() async {
        let rec = Recorder()
        let engine = OBDEngine(config: fastConfig(), makeTransport: { SimulatedTransport(options: fastSim()) }, onEvent: rec.add)
        engine.start()
        _ = await rec.wait { !rec.readings.isEmpty }
        engine.requestDTCRead()
        #expect(await rec.wait { rec.dtc != nil })
        engine.stop()
        let d = rec.dtc!
        #expect(d.milOn == true && d.reportedCount == 3)
        #expect(d.stored == .codes([DTC(code: "P0171"), DTC(code: "P0174"), DTC(code: "P0455")]))
        #expect(d.pending == .codes([DTC(code: "P0300")]))
        if case .notSupported = d.permanent {} else { Issue.record("permanent should be notSupported, got \(d.permanent)") }
        #expect(d.simulated)
    }

    @Test func readsDTCsNonCAN() async {
        let rec = Recorder()
        let engine = OBDEngine(config: fastConfig(), makeTransport: { SimulatedTransport(options: fastSim { $0.protocolNumber = 1; $0.storedDTCs = ["P0171", "P0174", "P0455", "P0420"] }) }, onEvent: rec.add)
        engine.start()
        _ = await rec.wait { !rec.readings.isEmpty }
        engine.requestDTCRead()
        #expect(await rec.wait { rec.dtc != nil })
        engine.stop()
        #expect(rec.dtc?.stored == .codes(["P0171", "P0174", "P0420", "P0455"].map { DTC(code: $0) }))
    }

    @Test func recoversFromDropout() async {
        let rec = Recorder()
        final class Box: @unchecked Sendable { var sims: [SimulatedTransport] = [] }
        let box = Box()
        let engine = OBDEngine(config: fastConfig(), makeTransport: {
            let t = SimulatedTransport(options: fastSim()); box.sims.append(t); return t
        }, onEvent: rec.add)
        engine.start()
        #expect(await rec.wait { !rec.readings.isEmpty })
        box.sims.last!.simulateDropout()
        #expect(await rec.wait { rec.phases.contains { if case .reconnecting = $0 { return true }; return false } })
        let before = rec.readings.count
        #expect(await rec.wait { rec.readings.count > before + 2 && rec.phases.last?.isLive == true })
        engine.stop()
        #expect(box.sims.count >= 2)
    }

    @Test func noWriteCommandsEverReachAdapter() async {
        let rec = Recorder()
        final class Box: @unchecked Sendable { var sim: SimulatedTransport? }
        let box = Box()
        let engine = OBDEngine(config: fastConfig(), makeTransport: { let t = SimulatedTransport(options: fastSim()); box.sim = t; return t }, onEvent: rec.add)
        engine.start()
        _ = await rec.wait { rec.readings.count > 5 }
        engine.requestDTCRead()
        _ = await rec.wait { rec.dtc != nil }
        engine.stop()
        let cmds = box.sim!.emulator.receivedCommands
        #expect(!cmds.isEmpty)
        for c in cmds { #expect(throws: Never.self) { try ReadOnlyGuard.validate(c) } }
        #expect(!cmds.contains("04"))
    }
}

/// Emulator behind a transport that claims to be real hardware (like `obd-cli emulate --tcp`).
final class DisguisedEmulatorTransport: OBDTransport, @unchecked Sendable {
    let inner = SimulatedTransport(options: fastSim())
    var displayName: String { "TCP (test)" }
    var isSimulated: Bool { false }
    func open(onData: @escaping (Data) -> Void, onClose: @escaping (String) -> Void) async throws { try await inner.open(onData: onData, onClose: onClose) }
    func write(_ data: Data) async throws { try await inner.write(data) }
    func close() { inner.close() }
}

@Suite("Simulator labeling")
struct LabelingTests {
    @Test func selfIdentifiedSimulatorIsLabeledSimulated() async {
        let rec = Recorder()
        let engine = OBDEngine(config: fastConfig(), makeTransport: { DisguisedEmulatorTransport() }, onEvent: rec.add)
        engine.start()
        #expect(await rec.wait { rec.phases.contains { $0.isLive } })
        engine.stop()
        #expect(rec.phases.contains(.live(simulated: true)))
        #expect(!rec.phases.contains(.live(simulated: false)))
    }
}

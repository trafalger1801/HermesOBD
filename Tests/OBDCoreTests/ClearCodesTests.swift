import Testing
import Foundation
@testable import OBDCore

extension Recorder {
    var clear: ClearReport? { events.compactMap { if case .clearResult(let c) = $0 { return c }; return nil }.last }
}

@Suite("Guard: clear-codes permit")
struct ClearGuardTests {
    @Test func clearRefusedWithoutPermit() {
        #expect(throws: ReadOnlyGuard.Refusal.self) { try ReadOnlyGuard.validate("04") }
    }
    @Test func clearAllowedWithPermit() throws {
        #expect(try ReadOnlyGuard.validate("04", permit: .init()) == "04")
        #expect(try ReadOnlyGuard.validate(" 0 4 ", permit: .init()) == "04")
    }
    @Test(arguments: ["0400", "08", "0801", "2E", "2EF190AA", "2F", "31", "34", "36", "3B", "3D", "10", "11", "14", "27", "ATSP0", "ATPP0CSV00", "04\r04"])
    func otherWritesStillRefusedEvenWithPermit(_ cmd: String) {
        #expect(throws: ReadOnlyGuard.Refusal.self) { try ReadOnlyGuard.validate(cmd, permit: .init()) }
    }
}

@Suite("Engine: clear codes", .serialized)
struct ClearEngineTests {
    final class Box: @unchecked Sendable { var sim: SimulatedTransport? }

    func run(_ tweak: @escaping (inout SimulatorOptions) -> Void) async -> (Recorder, ELM327Emulator) {
        let rec = Recorder(); let box = Box()
        let engine = OBDEngine(config: fastConfig(), makeTransport: {
            let t = SimulatedTransport(options: fastSim(tweak)); box.sim = t; return t
        }, onEvent: rec.add)
        engine.start()
        _ = await rec.wait { !rec.readings.isEmpty }
        engine.requestClearCodes()
        _ = await rec.wait(timeout: 15) { rec.clear != nil }
        engine.stop()
        return (rec, box.sim!.emulator)
    }

    @Test func refusedWhileEngineRunningAndNothingSent() async {
        let (rec, emu) = await run { $0.engineRunning = true }
        guard case .refused(let why)? = rec.clear?.outcome else { Issue.record("expected refusal, got \(String(describing: rec.clear))"); return }
        #expect(why.contains("engine is running"))
        #expect(rec.clear?.commandSent == false)
        #expect(!emu.receivedCommands.contains("04"))
        #expect(rec.clear?.codesBefore?.stored == .codes([DTC(code: "P0171"), DTC(code: "P0174"), DTC(code: "P0455")]))
    }

    @Test func clearsWhenEngineOff() async {
        let (rec, emu) = await run { $0.engineRunning = false }
        #expect(rec.clear?.outcome == .cleared)
        #expect(emu.receivedCommands.filter { $0 == "04" }.count == 1)
        #expect(rec.clear?.codesBefore?.stored == .codes([DTC(code: "P0171"), DTC(code: "P0174"), DTC(code: "P0455")]))
        #expect(rec.clear?.codesAfter?.stored == .codes([]))
        #expect(rec.clear?.codesAfter?.pending == .codes([]))
        #expect(rec.clear?.codesAfter?.milOn == false)
        #expect(rec.dtc?.stored == .codes([]))   // UI's trouble-code view gets the fresh read too
        #expect(rec.clear?.simulated == true)
    }

    @Test func ecuRejectionIsReported() async {
        let (rec, emu) = await run { $0.engineRunning = false; $0.rejectsClear = true }
        guard case .ecuRejected(let why)? = rec.clear?.outcome else { Issue.record("expected ECU rejection, got \(String(describing: rec.clear))"); return }
        #expect(why.contains("conditions not correct"))
        #expect(emu.receivedCommands.contains("04"))
        #expect(rec.clear?.codesAfter?.stored != .codes([]))   // codes are still there
    }

    @Test func noClearWithoutRequest() async {
        let rec = Recorder(); let box = Box()
        let engine = OBDEngine(config: fastConfig(), makeTransport: {
            let t = SimulatedTransport(options: fastSim { $0.engineRunning = false }); box.sim = t; return t
        }, onEvent: rec.add)
        engine.start()
        _ = await rec.wait { rec.readings.count > 5 }
        engine.requestDTCRead()
        _ = await rec.wait { rec.dtc != nil }
        engine.stop()
        #expect(!box.sim!.emulator.receivedCommands.contains("04"))
    }
}

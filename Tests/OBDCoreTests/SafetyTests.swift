import Testing
import Foundation
@testable import OBDCore

@Suite("Read-only guard")
struct ReadOnlyGuardTests {
    @Test(arguments: ["010C", "01 0d", "0100", "03", "07", "0A", "0902", "ATZ", "at e0", "ATRV", "ATDPN", "ATST32", "AT@1"])
    func allowed(_ cmd: String) throws {
        #expect(throws: Never.self) { try ReadOnlyGuard.validate(cmd) }
    }

    @Test(arguments: [
        "04", "0 4", "04 00", "08", "0801", "2E", "2EF190AA", "2F", "31", "3B", "14FFFFFF", "11", "27", "10",
        "02", "05", "06", "22F190",       // not on allowlist (even if read-only on some cars)
        "ATSP0", "ATSP6", "ATPP0CSV00", "ATSD", "AT@3ABC", "ATMA", "ATBRD23", "ATCS",
        "", "01", "010C0D0E0F", "0300", "XYZ", "010C;04", "01\r04",
    ])
    func refused(_ cmd: String) {
        #expect(throws: ReadOnlyGuard.Refusal.self) { try ReadOnlyGuard.validate(cmd) }
    }

    @Test func clearCodesReasonIsExplicit() {
        do { try ReadOnlyGuard.validate("04"); Issue.record("should refuse") } catch let r as ReadOnlyGuard.Refusal {
            #expect(r.reason.contains("clears trouble codes"))
        } catch { Issue.record("wrong error") }
    }

    @Test func sessionRefusesBeforeWriting() async throws {
        let sim = SimulatedTransport()
        let s = ELM327Session(transport: sim)
        try await s.open()
        await #expect(throws: ReadOnlyGuard.Refusal.self) { _ = try await s.send("04") }
        await #expect(throws: ReadOnlyGuard.Refusal.self) { _ = try await s.send("ATSP0") }
        _ = try await s.send("ATI")
        #expect(sim.emulator.receivedCommands == ["ATI"])
    }
}

@Suite("CSV logger")
struct CSVTests {
    @Test func writesHeaderRowsAndBlanks() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = dir.appendingPathComponent("t.csv")
        let cols = [PIDCatalog.definition(for: 0x0C)!, PIDCatalog.definition(for: 0x05)!, PIDCatalog.definition(for: 0x0D)!]
        let log = try CSVLogger(url: url, columns: cols, units: .imperial, simulated: true, adapter: "ELM327, \"sim\"")
        try log.log([0x0C: 1726, 0x05: 100], simulated: true)
        log.close()
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(lines.count == 3)
        #expect(lines[0].hasPrefix("\"# MustangOBD log. data_source=SIMULATED"))
        #expect(lines[1] == "timestamp,elapsed_s,data_source,engine_rpm (rpm),coolant_temp (°F),vehicle_speed (mph)")
        #expect(lines[2].hasSuffix(",SIMULATED,1726,212,"))
        #expect(log.rowCount == 1)
        try? FileManager.default.removeItem(at: dir)
    }
}

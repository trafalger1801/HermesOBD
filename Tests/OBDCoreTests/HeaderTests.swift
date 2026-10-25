import Testing
import Foundation
@testable import OBDCore

@Suite("CAN headers in replies")
struct HeaderTests {
    @Test func realReplyFrom3210RS() throws {
        // Captured from the Innova 3210RS on the 2005 Mustang: 0100 with headers on, spaces off.
        let msgs = try ELMResponse.parse("7E8064100BFBFB993")
        #expect(msgs == [[0x41, 0x00, 0xBF, 0xBF, 0xB9, 0x93]])
        let bitmap = try ELMResponse.pidData(msgs, pid: 0x00)
        let supported = PIDCatalog.supportedPIDs(base: 0, bitmap: bitmap)
        #expect(supported.contains(0x0C) && supported.contains(0x0D) && supported.contains(0x05))
    }
    @Test func withSpacesAndTwoECUs() throws {
        let msgs = try ELMResponse.parse("7E8 03 41 0D 00\n7E9 03 41 0D 00")
        #expect(msgs == [[0x41, 0x0D, 0x00], [0x41, 0x0D, 0x00]])
    }
    @Test func multiFrameDTCsWithHeaders() throws {
        let msgs = try ELMResponse.parse("7E8 10 0A 43 04 01 71 01 74\n7E8 21 04 55 03 00 00 00 00")
        #expect(msgs == [[0x43, 0x04, 0x01, 0x71, 0x01, 0x74, 0x04, 0x55, 0x03, 0x00]])
        #expect(DTCParser.parse(messages: msgs, service: 0x03, isCAN: true).map(\.code) == ["P0171", "P0174", "P0300", "P0455"])
    }
    @Test func twentyNineBitHeader() throws {
        #expect(try ELMResponse.parse("18DAF110 03 41 0D 00") == [[0x41, 0x0D, 0x00]])
    }
    @Test func headerlessStillWorks() throws {
        #expect(try ELMResponse.parse("41 0C 1A F8") == [[0x41, 0x0C, 0x1A, 0xF8]])
        #expect(try ELMResponse.parse("00A\n0:430401710174\n1:04550300000000").count == 1)
    }

    @Test func protocolNames() {
        #expect(ELMProtocol.name(for: "A6") == "Auto: ISO 15765-4 CAN (11 bit, 500 kbaud)")
        #expect(ELMProtocol.name(for: "1") == "SAE J1850 PWM (41.6 kbaud)")
        #expect(ELMProtocol.name(for: "OK") == nil)
    }
    @Test func permanentNotSupportedReplyFromMustang() throws {
        // Captured: 0A → "7E8037F0A11" (service not supported).
        let msgs = try ELMResponse.parse("7E8037F0A11")
        #expect(throws: OBDError.negativeResponse(service: 0x0A, code: 0x11)) {
            _ = try ELMResponse.pidData(msgs, pid: 0x00, service: 0x0A)
        }
        #expect(msgs == [[0x7F, 0x0A, 0x11]])
    }
    @Test func engineNeverSendsATDP() async {
        let rec = Recorder()
        final class Box: @unchecked Sendable { var sim: SimulatedTransport? }
        let box = Box()
        let engine = OBDEngine(config: fastConfig(), makeTransport: { let t = SimulatedTransport(options: fastSim()); box.sim = t; return t }, onEvent: rec.add)
        engine.start()
        _ = await rec.wait { rec.readings.count > 2 }
        engine.requestDTCRead()
        _ = await rec.wait { rec.dtc != nil }
        engine.stop()
        #expect(!box.sim!.emulator.receivedCommands.contains("ATDP"))
        if case .notSupported = rec.dtc?.permanent {} else { Issue.record("permanent should be notSupported, got \(String(describing: rec.dtc?.permanent))") }
    }
}

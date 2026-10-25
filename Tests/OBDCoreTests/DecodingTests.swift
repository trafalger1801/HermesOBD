import Testing
import Foundation
@testable import OBDCore

@Suite("PID decoding")
struct PIDDecodingTests {
    func def(_ pid: UInt8) -> PIDDefinition { PIDCatalog.definition(for: pid)! }

    @Test func rpm() { #expect(def(0x0C).decode([0x1A, 0xF8]) == 1726) }
    @Test func speed() { #expect(def(0x0D).decode([0x64]) == 100) }
    @Test func coolantAndIAT() {
        #expect(def(0x05).decode([0x7B]) == 83)
        #expect(def(0x0F).decode([0x28]) == 0)
    }
    @Test func throttle() { #expect(def(0x11).decode([0xFF]) == 100) }
    @Test func fuelTrims() {
        #expect(def(0x06).decode([0x80]) == 0)
        #expect(def(0x07).decode([0x00]) == -100)
        #expect(abs(def(0x08).decode([0x84])! - 3.125) < 0.0001)
    }
    @Test func maf() { #expect(def(0x10).decode([0x01, 0x90]) == 4.0) }
    @Test func shortReplyRejected() { #expect(def(0x0C).decode([0x1A]) == nil) }

    @Test func supportedBitmap() {
        // Example from SAE J1979: 41 00 BE 1F A8 13
        let s = PIDCatalog.supportedPIDs(base: 0, bitmap: [0xBE, 0x1F, 0xA8, 0x13])
        #expect(s == [0x01, 0x03, 0x04, 0x05, 0x06, 0x07, 0x0C, 0x0D, 0x0E, 0x0F, 0x10, 0x11, 0x13, 0x15, 0x1C, 0x1F, 0x20])
        #expect(PIDCatalog.supportedPIDs(base: 0x40, bitmap: [0x40, 0, 0, 0]) == [0x42])
    }

    @Test func unitConversion() {
        #expect(UnitSystem.imperial.convert(100, .temperature).value == 212)
        #expect(UnitSystem.imperial.convert(100, .temperature).unit == "°F")
        #expect(abs(UnitSystem.imperial.convert(100, .speed).value - 62.1371) < 0.001)
        #expect(UnitSystem.metric.convert(100, .speed).unit == "km/h")
    }
}

@Suite("ELM327 response parsing")
struct ResponseTests {
    @Test func spacesAndNoSpaces() throws {
        #expect(try ELMResponse.parse("41 0C 1A F8") == [[0x41, 0x0C, 0x1A, 0xF8]])
        #expect(try ELMResponse.parse("410C1AF8") == [[0x41, 0x0C, 0x1A, 0xF8]])
    }
    @Test func searchingPrefix() throws {
        #expect(try ELMResponse.parse("SEARCHING...\n41 00 BE 1F A8 13") == [[0x41, 0x00, 0xBE, 0x1F, 0xA8, 0x13]])
        #expect(try ELMResponse.parse("SEARCHING...41 00 BE 1F A8 13").count == 1)
        #expect(try ELMResponse.parse("BUS INIT: ...OK\n41 0D 00") == [[0x41, 0x0D, 0x00]])
    }
    @Test func errors() {
        #expect(throws: OBDError.noData) { try ELMResponse.parse("NO DATA") }
        #expect(throws: OBDError.unableToConnect) { try ELMResponse.parse("SEARCHING...\nUNABLE TO CONNECT") }
        #expect(throws: OBDError.adapterRejected) { try ELMResponse.parse("?") }
        #expect(throws: OBDError.stopped) { try ELMResponse.parse("STOPPED") }
        #expect(throws: OBDError.busError("CAN ERROR")) { try ELMResponse.parse("CAN ERROR") }
        #expect(throws: OBDError.busError("BUS INIT: ...ERROR")) { try ELMResponse.parse("BUS INIT: ...ERROR") }
        #expect(throws: OBDError.noData) { try ELMResponse.parse("") }
        #expect(throws: OBDError.unexpected("GARBAGE!")) { try ELMResponse.parse("GARBAGE!") }
    }
    @Test func multiFrame() throws {
        let text = "00A\n0: 43 04 01 71 01 74\n1: 04 55 03 00 00 00 00"
        #expect(try ELMResponse.parse(text) == [[0x43, 0x04, 0x01, 0x71, 0x01, 0x74, 0x04, 0x55, 0x03, 0x00]])
        let noSpaces = "00A\n0:430401710174\n1:04550300000000"
        #expect(try ELMResponse.parse(noSpaces) == ELMResponse.parse(text))
    }
    @Test func multipleECUs() throws {
        #expect(try ELMResponse.parse("41 0D 00\n41 0D 00").count == 2)
    }
    @Test func pidDataExtraction() throws {
        #expect(try ELMResponse.pidData([[0x41, 0x0C, 0x1A, 0xF8]], pid: 0x0C) == [0x1A, 0xF8])
        #expect(throws: OBDError.negativeResponse(service: 1, code: 0x12)) {
            try ELMResponse.pidData([[0x7F, 0x01, 0x12]], pid: 0x0C)
        }
    }
    @Test func echoStripping() {
        #expect(ELM327Session.clean("ATZ\r\r\rELM327 v1.5\r\r", command: "ATZ") == "ELM327 v1.5")
        #expect(ELM327Session.clean("010C\r41 0C 1A F8\r\r", command: "010C") == "41 0C 1A F8")
    }
}

@Suite("Trouble codes")
struct DTCTests {
    @Test func decodeLetters() {
        #expect(DTC(0x01, 0x71)?.code == "P0171")
        #expect(DTC(0x41, 0x23)?.code == "C0123")
        #expect(DTC(0x81, 0x00)?.code == "B0100")
        #expect(DTC(0xC1, 0x55)?.code == "U0155")
        #expect(DTC(0x11, 0x31)?.code == "P1131")
        #expect(DTC(0x00, 0x00) == nil)
    }
    @Test func canSingleAndMulti() throws {
        let one = try ELMResponse.parse("43 01 01 71")
        #expect(DTCParser.parse(messages: one, service: 0x03, isCAN: true).map(\.code) == ["P0171"])
        let none = try ELMResponse.parse("43 00")
        #expect(DTCParser.parse(messages: none, service: 0x03, isCAN: true).isEmpty)
        let multi = try ELMResponse.parse("00A\n0: 43 04 01 71 01 74\n1: 04 55 03 00 00 00 00")
        #expect(DTCParser.parse(messages: multi, service: 0x03, isCAN: true).map(\.code) == ["P0171", "P0174", "P0300", "P0455"])
    }
    @Test func nonCAN() throws {
        let msgs = try ELMResponse.parse("43 01 71 01 74 04 55\n43 03 00 00 00 00 00")
        #expect(DTCParser.parse(messages: msgs, service: 0x03, isCAN: false).map(\.code) == ["P0171", "P0174", "P0300", "P0455"])
    }
    @Test func pendingServiceOnly() throws {
        let msgs = try ELMResponse.parse("47 01 03 00")
        #expect(DTCParser.parse(messages: msgs, service: 0x07, isCAN: true).map(\.code) == ["P0300"])
        #expect(DTCParser.parse(messages: msgs, service: 0x03, isCAN: true).isEmpty)
    }
    @Test func protocolDetection() {
        #expect(DTCParser.isCAN(protocolNumber: "A6") == true)
        #expect(DTCParser.isCAN(protocolNumber: "6") == true)
        #expect(DTCParser.isCAN(protocolNumber: "A1") == false)
        #expect(DTCParser.isCAN(protocolNumber: "3") == false)
        #expect(DTCParser.isCAN(protocolNumber: nil) == nil)
    }
    @Test func emulatorEncodingRoundTrip() {
        for code in ["P0171", "C0123", "B0100", "U0155", "P1131"] {
            let b = ELM327Emulator.encode(code)!
            #expect(DTC(b[0], b[1])?.code == code)
        }
    }
}

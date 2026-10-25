import Testing
import Foundation
@testable import OBDCore

/// Intercepts URLSession requests so the client can be tested without a server.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, Data))?
    nonisolated(unsafe) static var lastBody: Data?
    nonisolated(unsafe) static var lastRequest: URLRequest?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        StubProtocol.lastRequest = request
        if let s = request.httpBodyStream {
            s.open(); var d = Data(); var buf = [UInt8](repeating: 0, count: 4096)
            while s.hasBytesAvailable { let n = s.read(&buf, maxLength: buf.count); if n <= 0 { break }; d.append(buf, count: n) }
            s.close(); StubProtocol.lastBody = d
        } else { StubProtocol.lastBody = request.httpBody }
        let (code, data) = StubProtocol.handler!(request)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

func stubClient() -> HermesClient {
    let cfg = URLSessionConfiguration.ephemeral
    cfg.protocolClasses = [StubProtocol.self]
    return HermesClient(baseURL: URL(string: "http://127.0.0.1:8642")!, apiKey: "test-key", session: URLSession(configuration: cfg))
}

let sampleResponse = """
{"id":"resp_123","object":"response","status":"completed","output":[
 {"type":"function_call","status":"completed","name":"terminal","arguments":"{}","call_id":"c1"},
 {"type":"message","phase":"commentary","role":"assistant","content":[{"type":"output_text","text":"Looking at it..."}]},
 {"type":"message","role":"assistant","content":[{"type":"output_text","text":"- Coolant normal.\\n- Trims fine."}]}]}
"""

@Suite("Hermes", .serialized)
struct HermesTests {
    @Test func parsesFinalTextAndSkipsCommentary() throws {
        let r = try HermesClient.parseResponse(Data(sampleResponse.utf8))
        #expect(r.responseID == "resp_123")
        #expect(r.text == "- Coolant normal.\n- Trims fine.")
    }

    @Test func failedStatusIsAnError() {
        #expect(throws: HermesError.self) {
            try HermesClient.parseResponse(Data(#"{"status":"failed","error":{"message":"boom"}}"#.utf8))
        }
    }

    @Test func requestShapeAndChaining() async throws {
        StubProtocol.handler = { _ in (200, Data(sampleResponse.utf8)) }
        let reply = try await stubClient().analyze(input: "data", instructions: "be brief", previousResponseID: "resp_prev")
        #expect(reply.responseID == "resp_123")
        let req = StubProtocol.lastRequest!
        #expect(req.url?.path == "/v1/responses")
        #expect(req.httpMethod == "POST")
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
        let body = try JSONSerialization.jsonObject(with: StubProtocol.lastBody!) as! [String: Any]
        #expect(body["input"] as? String == "data")
        #expect(body["instructions"] as? String == "be brief")
        #expect(body["previous_response_id"] as? String == "resp_prev")
        // Hermes must keep using its own configured model: no model/provider override.
        #expect(body["model"] == nil && body["provider"] == nil)
    }

    @Test func badKeyGivesClearError() async {
        StubProtocol.handler = { _ in (401, Data("{}".utf8)) }
        do { _ = try await stubClient().analyze(input: "x", instructions: "y", previousResponseID: nil); Issue.record("expected error") }
        catch { #expect("\(error)".contains("API key")) }
    }

    @Test func windowStats() {
        var w = ReadingWindow()
        let t = Date()
        w.add([PIDReading(pid: 0x0C, value: 700, at: t), PIDReading(pid: 0x05, value: 80, at: t)])
        w.add([PIDReading(pid: 0x0C, value: 900, at: t.addingTimeInterval(1))])
        #expect(w.cycles == 2)
        #expect(w.stats[0x0C]?.min == 700 && w.stats[0x0C]?.max == 900 && w.stats[0x0C]?.avg == 800 && w.stats[0x0C]?.latest == 900)
        #expect(w.stats[0x05]?.count == 1)
        w.reset(); #expect(w.isEmpty)
    }

    @Test func renderedSnapshotIsLabeledAndComplete() {
        var w = ReadingWindow()
        w.add([PIDReading(pid: 0x05, value: 100, at: Date())])
        let dtc = DTCReport(milOn: true, reportedCount: 1, stored: .codes([DTC(code: "P0171")]), pending: .codes([]),
                            permanent: .notSupported("no response"), readAt: Date(), simulated: true)
        let text = HermesSnapshot(window: w, simulated: true, units: .imperial, adapter: AdapterInfo(),
                                  pidStatus: [0x46: .notAdvertised], dtc: dtc).render()
        #expect(text.contains("data_source: SIMULATED"))
        #expect(text.contains("Coolant Temp | 212 | 212 | 212 | 212 | °F | 1"))
        #expect(text.contains("P0171 (System too lean (bank 1))"))
        #expect(text.contains("not supported by this vehicle: Ambient Air Temp"))
        let live = HermesSnapshot(window: w, simulated: false, units: .metric, adapter: AdapterInfo(), pidStatus: [:], dtc: nil).render()
        #expect(live.contains("data_source: LIVE"))
        #expect(live.contains("trouble codes: not read yet"))
    }

    @Test func loopbackDetection() {
        #expect(HermesClient.isLoopback(URL(string: "http://127.0.0.1:8642")!))
        #expect(HermesClient.isLoopback(URL(string: "http://localhost:8642")!))
        #expect(!HermesClient.isLoopback(URL(string: "http://192.168.1.5:8642")!))
    }
}

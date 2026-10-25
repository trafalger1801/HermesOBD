import Foundation
import Network
import Darwin
import OBDCore

let usage = """
obd-cli — headless, read-only OBD-II monitor (same engine as the app)

Connect and print data:
  obd-cli --sim [--seconds N] [--csv FILE] [--dtc] [--ignition-off] [--j1850]
  obd-cli --serial /dev/cu.NAME [--seconds N] [--csv FILE] [--dtc]
  obd-cli --tcp HOST:PORT [--seconds N] [--csv FILE] [--dtc]
  obd-cli --list-ports

Serve the simulator (for testing the serial/TCP code paths without hardware):
  obd-cli emulate --tcp PORT      ELM327 simulator on 127.0.0.1:PORT
  obd-cli emulate --pty           ELM327 simulator on a virtual serial port (prints its path)

Send live data to Hermes Agent for analysis (key read from the HERMES_API_KEY environment variable):
  obd-cli --sim --hermes http://127.0.0.1:8642 [--hermes-every 30] --seconds 120

Mock Hermes API server for testing (never contacts any model; replies are canned):
  obd-cli mock-hermes --port 8649 --key test-key

Bluetooth LE is only available in the app (it needs the app's Bluetooth permission).
"""

var args = Array(CommandLine.arguments.dropFirst())
func flag(_ f: String) -> Bool { if let i = args.firstIndex(of: f) { args.remove(at: i); return true }; return false }
func value(_ f: String) -> String? {
    guard let i = args.firstIndex(of: f), i + 1 < args.count else { return nil }
    let v = args[i + 1]; args.removeSubrange(i...i + 1); return v
}
func fail(_ s: String) -> Never { FileHandle.standardError.write(Data((s + "\n").utf8)); exit(2) }

if args.isEmpty || flag("--help") || flag("-h") { print(usage); exit(0) }
if flag("--list-ports") { SerialTransport.availablePorts().forEach { print($0) }; exit(0) }

// MARK: - Mock Hermes server (testing only)

if args.first == "mock-hermes" {
    args.removeFirst()
    guard let p = value("--port"), let port = NWEndpoint.Port(p) else { fail("mock-hermes needs --port") }
    let key = value("--key") ?? "test-key"
    var counter = 0
    let listener = try NWListener(using: .tcp, on: port)
    func reply(_ conn: NWConnection, _ code: Int, _ json: String) {
        let head = "HTTP/1.1 \(code) \(code == 200 ? "OK" : "Error")\r\nContent-Type: application/json\r\nContent-Length: \(json.utf8.count)\r\nConnection: close\r\n\r\n"
        conn.send(content: Data((head + json).utf8), completion: .contentProcessed { _ in conn.cancel() })
    }
    listener.newConnectionHandler = { conn in
        var buf = Data()
        func handle() {
            guard let sep = buf.range(of: Data("\r\n\r\n".utf8)) else { return read() }
            let head = String(decoding: buf[..<sep.lowerBound], as: UTF8.self)
            let lines = head.components(separatedBy: "\r\n")
            let reqLine = lines.first?.split(separator: " ") ?? []
            let method = reqLine.first.map(String.init) ?? "", path = reqLine.dropFirst().first.map(String.init) ?? ""
            var headers: [String: String] = [:]
            for l in lines.dropFirst() { if let c = l.firstIndex(of: ":") { headers[l[..<c].lowercased()] = l[l.index(after: c)...].trimmingCharacters(in: .whitespaces) } }
            let len = Int(headers["content-length"] ?? "0") ?? 0
            let bodyStart = sep.upperBound
            guard buf.count - bodyStart >= len else { return read() }
            let body = buf[bodyStart..<bodyStart + len]
            let authed = headers["authorization"] == "Bearer \(key)"
            print("MOCK-HERMES \(method) \(path) auth=\(authed ? "ok" : "BAD") bytes=\(len)"); fflush(stdout)
            switch (method, path) {
            case ("GET", "/health"): reply(conn, 200, #"{"status":"ok"}"#)
            case ("GET", "/v1/models"):
                authed ? reply(conn, 200, #"{"object":"list","data":[{"id":"mock-hermes"}]}"#) : reply(conn, 401, #"{"error":"unauthorized"}"#)
            case ("POST", "/v1/responses"):
                guard authed else { return reply(conn, 401, #"{"error":"unauthorized"}"#) }
                let obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
                let input = obj["input"] as? String ?? ""
                counter += 1
                let source = input.components(separatedBy: "\n").first { $0.hasPrefix("data_source:") } ?? "data_source: ?"
                let text = "MOCK HERMES reply #\(counter) (not a real analysis). Received \(input.components(separatedBy: "\n").count) lines; \(source); previous_response_id=\(obj["previous_response_id"] as? String ?? "none"); model override=\(obj["model"] as? String ?? "none")."
                let resp: [String: Any] = ["id": "resp_mock_\(counter)", "object": "response", "status": "completed",
                    "output": [["type": "message", "role": "assistant", "content": [["type": "output_text", "text": text]]]]]
                reply(conn, 200, String(decoding: try! JSONSerialization.data(withJSONObject: resp), as: UTF8.self))
            default: reply(conn, 404, #"{"error":"not found"}"#)
            }
        }
        func read() {
            conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { d, _, done, err in
                if let d { buf.append(d) }
                if err != nil || (done && d == nil) { conn.cancel(); return }
                handle()
            }
        }
        conn.start(queue: .main); read()
    }
    listener.stateUpdateHandler = { s in if case .ready = s { print("MOCK HERMES listening on 127.0.0.1:\(p) (key: \(key))"); fflush(stdout) } }
    listener.start(queue: .main)
    dispatchMain()
}

// MARK: - Emulator server

if args.first == "emulate" {
    args.removeFirst()
    let emulator = ELM327Emulator()
    if let p = value("--tcp"), let port = NWEndpoint.Port(p) {
        let listener = try NWListener(using: .tcp, on: port)
        listener.newConnectionHandler = { conn in
            var pending = ""
            func loop() {
                conn.receive(minimumIncompleteLength: 1, maximumLength: 1024) { data, _, done, err in
                    if let data { pending += String(decoding: data, as: UTF8.self) }
                    while let r = pending.firstIndex(of: "\r") {
                        let line = String(pending[..<r]); pending = String(pending[pending.index(after: r)...])
                        conn.send(content: Data(emulator.handle(line).utf8), completion: .idempotent)
                    }
                    if done || err != nil { conn.cancel() } else { loop() }
                }
            }
            conn.start(queue: .main); loop()
        }
        listener.stateUpdateHandler = { s in if case .ready = s { print("SIMULATOR listening on 127.0.0.1:\(p)"); fflush(stdout) } }
        listener.start(queue: .main)
        dispatchMain()
    } else if flag("--pty") {
        var master: Int32 = 0, slave: Int32 = 0
        var name = [CChar](repeating: 0, count: 128)
        guard openpty(&master, &slave, &name, nil, nil) == 0 else { fail("openpty failed") }
        var t = termios(); tcgetattr(slave, &t); cfmakeraw(&t); tcsetattr(slave, TCSANOW, &t)
        print("SIMULATOR on virtual serial port: \(String(cString: name))"); fflush(stdout)
        var pending = ""
        var buf = [UInt8](repeating: 0, count: 1024)
        while true {
            let n = read(master, &buf, buf.count)
            if n <= 0 { usleep(10_000); continue }
            pending += String(decoding: buf[0..<n], as: UTF8.self)
            while let r = pending.firstIndex(of: "\r") {
                let line = String(pending[..<r]); pending = String(pending[pending.index(after: r)...])
                let reply = Array(emulator.handle(line).utf8)
                _ = reply.withUnsafeBufferPointer { write(master, $0.baseAddress, $0.count) }
            }
        }
    } else { fail(usage) }
}

// MARK: - Monitor

let seconds = Double(value("--seconds") ?? "10") ?? 10
let csvPath = value("--csv")
let wantDTC = flag("--dtc")
var simOpts = SimulatorOptions()
if flag("--ignition-off") { simOpts.vehicleResponds = false }
if flag("--j1850") { simOpts.protocolNumber = 1 }

let makeTransport: () -> OBDTransport
var simulated = false
if flag("--sim") {
    simulated = true
    makeTransport = { SimulatedTransport(options: simOpts) }
} else if let p = value("--serial") {
    makeTransport = { SerialTransport(path: p) }
} else if let hp = value("--tcp") {
    let parts = hp.split(separator: ":")
    guard parts.count == 2, let port = UInt16(parts[1]) else { fail("--tcp needs HOST:PORT") }
    makeTransport = { TCPTransport(host: String(parts[0]), port: port) }
} else { fail(usage) }

let units = UnitSystem.imperial
let hermesURL = value("--hermes")
let hermesEvery = Double(value("--hermes-every") ?? "30") ?? 30
var hermesClient: HermesClient?
if let hermesURL {
    guard let u = URL(string: hermesURL), let k = ProcessInfo.processInfo.environment["HERMES_API_KEY"], !k.isEmpty else {
        fail("--hermes needs a URL and the HERMES_API_KEY environment variable")
    }
    hermesClient = HermesClient(baseURL: u, apiKey: k)
}
var hermesWindow = ReadingWindow()
var hermesPrev: String?
var hermesBusy = false
var hermesLast = Date()
var lastAdapter = AdapterInfo()
var lastStatus: [UInt8: PIDStatus] = [:]
var lastDTC: DTCReport?
func maybeSendToHermes() {
    guard let c = hermesClient, !hermesBusy, !hermesWindow.isEmpty, Date().timeIntervalSince(hermesLast) >= hermesEvery else { return }
    let input = HermesSnapshot(window: hermesWindow, simulated: simulated, units: units, adapter: lastAdapter,
                               pidStatus: lastStatus, dtc: lastDTC).render()
    hermesWindow.reset(); hermesBusy = true; hermesLast = Date()
    let prev = hermesPrev
    Task {
        do {
            let r = try await c.analyze(input: input, instructions: HermesPrompt.instructions(intervalSeconds: Int(hermesEvery)), previousResponseID: prev)
            DispatchQueue.main.async { hermesPrev = r.responseID ?? hermesPrev; hermesBusy = false; print("HERMES: \(r.text)"); fflush(stdout) }
        } catch {
            DispatchQueue.main.async { hermesBusy = false; print("HERMES ERROR: \(error)"); fflush(stdout) }
        }
    }
}
var logger: CSVLogger?
let verbose = flag("--verbose")

var tag: String { simulated ? "[SIMULATED] " : "" }
var dtcRequested = false
var gotLive = false
var engine: OBDEngine!

engine = OBDEngine(makeTransport: makeTransport) { event in
    DispatchQueue.main.async {
        switch event {
        case .phase(let p):
            print("\(tag)phase: \(p)")
            if case .live(let sim) = p {
                gotLive = true
                if sim { simulated = true }
                // Create the CSV only now, so its header states the correct data source.
                if let csvPath, logger == nil {
                    logger = try? CSVLogger(url: URL(fileURLWithPath: csvPath), columns: PIDCatalog.all, units: units, simulated: simulated, adapter: nil)
                }
            }
        case .adapterInfo(let i): lastAdapter = i; print("\(tag)adapter: \(i.identity ?? "?") | protocol: \(i.protocolName ?? "?") | voltage: \(i.voltage ?? "?")")
        case .pidStatus(let s):
            lastStatus = s
            let unsupported = s.filter { $0.value != .supported }.keys.sorted().compactMap { PIDCatalog.definition(for: $0)?.name }
            print("\(tag)unsupported: \(unsupported.joined(separator: ", "))")
        case .readings(let r):
            let line = r.compactMap { x -> String? in
                guard let d = PIDCatalog.definition(for: x.pid) else { return nil }
                return "\(d.key)=\(units.format(x.value, d))\(units.convert(0, d.quantity).unit)"
            }.joined(separator: " ")
            print("\(tag)\(line)")
            try? logger?.log(Dictionary(uniqueKeysWithValues: r.map { ($0.pid, $0.value) }), at: Date(), simulated: simulated)
            if wantDTC && !dtcRequested { dtcRequested = true; engine.requestDTCRead() }
            hermesWindow.add(r)
            maybeSendToHermes()
        case .dtcReport(let d):
            lastDTC = d
            func fmt(_ s: DTCReport.Section) -> String {
                switch s {
                case .codes(let c): return c.isEmpty ? "none" : c.map { "\($0.code) (\($0.genericDescription ?? "no description"))" }.joined(separator: ", ")
                case .notSupported(let w): return w
                case .failed(let w): return "FAILED: \(w)"
                }
            }
            print("\(tag)MIL: \(d.milOn.map { $0 ? "ON" : "OFF" } ?? "?")  count: \(d.reportedCount.map(String.init) ?? "?")")
            print("\(tag)stored: \(fmt(d.stored))")
            print("\(tag)pending: \(fmt(d.pending))")
            print("\(tag)permanent: \(fmt(d.permanent))")
        case .clearResult(let c): print("\(tag)clear codes: \(c.outcome)")
        case .message(let m): print("\(tag)note: \(m)")
        case .traffic(let t): if verbose { print("    \(t)") }
        }
        fflush(stdout)
    }
}
engine.start()
DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
    engine.stop()
    logger?.close()
    if let l = logger { print("CSV: \(l.rowCount) rows → \(l.url.path)") }
    print(gotLive ? "RESULT: received vehicle data" : "RESULT: no vehicle data received")
    exit(gotLive ? 0 : 1)
}
dispatchMain()

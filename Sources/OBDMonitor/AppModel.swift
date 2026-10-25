import Foundation
import SwiftUI
import AppKit
import OBDCore

enum SourceKind: String, CaseIterable, Identifiable {
    case simulator = "Simulator"
    case ble = "Bluetooth LE"
    case serial = "Bluetooth Classic / Serial"
    case wifi = "Wi-Fi"
    var id: String { rawValue }
}

struct HermesAnalysis: Identifiable {
    let id = UUID()
    let at: Date
    let question: String?
    let sent: String
    let reply: String
    let simulated: Bool
}

struct LogLine: Identifiable {
    let id = UUID()
    let at: Date
    let text: String
    let isTraffic: Bool
}

@MainActor
final class AppModel: ObservableObject {
    // Connection settings
    @Published var source: SourceKind = .simulator
    @Published var selectedBLE: BLEDevice?
    @Published var serialPath = ""
    @Published var serialPorts: [String] = []
    @Published var wifiHost = "192.168.0.10"
    @Published var wifiPort = "35000"
    @Published var simVehicleResponds = true
    @Published var simUseJ1850 = false
    @Published var showTraffic = true
    @Published var simEngineRunning = true {
        didSet { currentSim?.emulator.setEngineRunning(simEngineRunning) }
    }

    // Clearing trouble codes (opt-in; off at every launch, never saved)
    @Published var clearingEnabled = false
    @Published private(set) var clearPending = false
    @Published private(set) var lastClear: ClearReport?
    @Published private(set) var clearHistoryError: String?
    @Published var selectedTab = 0
    @Published var units: UnitSystem = UnitSystem(rawValue: UserDefaults.standard.string(forKey: "units") ?? "") ?? .imperial {
        didSet { UserDefaults.standard.set(units.rawValue, forKey: "units") }
    }

    // Session state
    @Published private(set) var phase: ConnectionPhase = .idle
    @Published private(set) var sessionIsSimulated = false
    @Published private(set) var adapterInfo = AdapterInfo()
    @Published private(set) var latest: [UInt8: PIDReading] = [:]
    @Published private(set) var pidStatus: [UInt8: PIDStatus] = [:]
    @Published private(set) var lastDataAt: Date?
    @Published private(set) var dtcReport: DTCReport?
    @Published private(set) var dtcPending = false
    @Published private(set) var lastMessage: String?
    @Published private(set) var log: [LogLine] = []
    @Published private(set) var now = Date()

    // Logging
    @Published private(set) var logger: CSVLogger?
    @Published private(set) var logRows = 0
    @Published private(set) var lastLogURL: URL?
    @Published var logError: String?

    private var engine: OBDEngine?
    private var currentSim: SimulatedTransport?
    private var ticker: Timer?

    // Hermes analysis (opt-in; off at every launch)
    @Published var hermesEnabled = false {
        didSet { if hermesEnabled != oldValue { hermesToggled() } }
    }
    @Published var hermesURL = UserDefaults.standard.string(forKey: "hermesURL") ?? "http://127.0.0.1:8642" {
        didSet { if Self.persistSettings { UserDefaults.standard.set(hermesURL, forKey: "hermesURL") } }
    }
    @Published var hermesKey = Keychain.read() ?? ""
    @Published var hermesInterval = max(15, UserDefaults.standard.integer(forKey: "hermesInterval") == 0 ? 30 : UserDefaults.standard.integer(forKey: "hermesInterval")) {
        didSet { if Self.persistSettings { UserDefaults.standard.set(hermesInterval, forKey: "hermesInterval") } }
    }
    @Published private(set) var hermesStatus = "Off"
    @Published private(set) var hermesBusy = false
    @Published private(set) var hermesError: String?
    @Published private(set) var hermesAnalyses: [HermesAnalysis] = []
    @Published var hermesQuestion = ""
    private var hermesWindow = ReadingWindow()
    private var hermesPreviousID: String?
    private var hermesLastSent: Date?

    static let staleAfter: TimeInterval = 3
    /// Off during the developer self-check so test values never overwrite the user's settings.
    static var persistSettings = true

    init() {
        refreshSerialPorts()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.now = Date(); self?.hermesTick() } }
        }
    }

    var isRunning: Bool { engine != nil }

    /// True only when the vehicle (or simulator) has delivered data recently.
    var dataIsFresh: Bool {
        guard phase.isLive, let t = lastDataAt else { return false }
        return now.timeIntervalSince(t) < Self.staleAfter
    }

    // MARK: Actions

    func refreshSerialPorts() {
        serialPorts = SerialTransport.availablePorts()
        if !serialPorts.contains(serialPath) {
            serialPath = serialPorts.first { $0.localizedCaseInsensitiveContains("obd") || $0.localizedCaseInsensitiveContains("innova") }
                ?? serialPorts.first { !$0.contains("Bluetooth-Incoming-Port") && !$0.contains("debug-console") } ?? ""
        }
    }

    func connect() {
        guard engine == nil else { return }
        let factory: () -> OBDTransport
        switch source {
        case .simulator:
            var o = SimulatorOptions()
            o.vehicleResponds = simVehicleResponds
            o.protocolNumber = simUseJ1850 ? 1 : 6
            o.engineRunning = simEngineRunning
            factory = { [weak self] in
                let t = SimulatedTransport(options: o)
                DispatchQueue.main.async { self?.currentSim = t }
                return t
            }
        case .ble:
            guard let d = selectedBLE else { note("Select a Bluetooth LE device first."); return }
            factory = { [weak self] in
                let t = BLETransport(deviceID: d.id, name: d.name)
                t.log = { line in DispatchQueue.main.async { self?.append(line, traffic: true) } }
                return t
            }
        case .serial:
            guard !serialPath.isEmpty else { note("Choose a serial port first."); return }
            let path = serialPath
            factory = { SerialTransport(path: path) }
        case .wifi:
            guard let port = UInt16(wifiPort), !wifiHost.isEmpty else { note("Enter a valid host and port."); return }
            let host = wifiHost
            factory = { TCPTransport(host: host, port: port) }
        }
        latest = [:]; pidStatus = [:]; dtcReport = nil; lastDataAt = nil; adapterInfo = AdapterInfo()
        hermesWindow.reset(); hermesPreviousID = nil   // new session = new Hermes conversation
        sessionIsSimulated = source == .simulator
        let e = OBDEngine(makeTransport: factory) { [weak self] event in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.handle(event) } }
        }
        engine = e
        append("Starting \(source.rawValue) session", traffic: false)
        e.start()
    }

    func disconnect() {
        stopLogging()
        engine?.stop()
        engine = nil
        currentSim = nil
        phase = .stopped
        dtcPending = false
        clearPending = false
        clearingEnabled = false
    }

    func readDTCs() {
        guard let engine, phase.isLive else { return }
        dtcPending = true
        engine.requestDTCRead()
    }

    /// Codes may only be cleared after they've been read in this session, so the user has seen them.
    var canClearCodes: Bool {
        clearingEnabled && phase.isLive && dtcReport != nil && !clearPending && !dtcPending
    }

    /// Call only after the user typed CLEAR in the confirmation dialog.
    func clearCodesConfirmed() {
        guard let engine, canClearCodes else { return }
        clearPending = true
        append("User confirmed clearing trouble codes", traffic: false)
        engine.requestClearCodes()
    }

    func simulateDropout() { currentSim?.simulateDropout() }

    func startLogging() {
        guard logger == nil else { return }
        do {
            let url = CSVLogger.defaultURL(simulated: sessionIsSimulated)
            logger = try CSVLogger(url: url, columns: PIDCatalog.all, units: units, simulated: sessionIsSimulated,
                                   adapter: adapterInfo.identity)
            lastLogURL = url
            logRows = 0
            logError = nil
            append("Logging to \(url.path)", traffic: false)
        } catch {
            logError = "Could not start log: \(error)"
        }
    }

    func stopLogging() {
        guard let l = logger else { return }
        l.close()
        append("Stopped logging (\(l.rowCount) rows) → \(l.url.path)", traffic: false)
        logger = nil
    }

    func revealLog() {
        if let u = lastLogURL { NSWorkspace.shared.activateFileViewerSelecting([u]) }
    }

    func clearLog() { log.removeAll() }

    // MARK: Engine events

    private func handle(_ e: EngineEvent) {
        guard engine != nil else { return }   // ignore stragglers after Disconnect
        switch e {
        case .phase(let p):
            phase = p
            if case .live(let sim) = p, sim { sessionIsSimulated = true }
            if case .reconnecting = p { dtcPending = false; clearPending = false }
        case .adapterInfo(let i): adapterInfo = i
        case .pidStatus(let s): pidStatus = s
        case .readings(let r):
            let at = r.map(\.at).max() ?? Date()
            for x in r { latest[x.pid] = x }
            lastDataAt = at
            if hermesEnabled { hermesWindow.add(r) }
            if let l = logger {
                do {
                    try l.log(Dictionary(uniqueKeysWithValues: r.map { ($0.pid, $0.value) }), at: at, simulated: sessionIsSimulated)
                    logRows = l.rowCount
                } catch {
                    logError = "Logging stopped: \(error)"
                    stopLogging()
                }
            }
        case .dtcReport(let d):
            dtcReport = d
            if hermesEnabled { hermesTick(force: true) }
            dtcPending = false
        case .clearResult(let c):
            lastClear = c
            clearPending = false
            clearingEnabled = false   // one clear per opt-in
            append("Clear codes: \(ClearHistory.line(c, adapter: adapterInfo.identity))", traffic: false)
            do { try ClearHistory.append(c, adapter: adapterInfo.identity); clearHistoryError = nil }
            catch { clearHistoryError = "Couldn't write clear-history.log: \(error)" }
        case .message(let m):
            lastMessage = m
            append(m, traffic: false)
        case .traffic(let t):
            append(t, traffic: true)
        }
    }

    // MARK: Hermes

    func saveHermesKey() {
        hermesKey = hermesKey.trimmingCharacters(in: .whitespacesAndNewlines)
        Keychain.save(hermesKey)
    }

    private func hermesClient() -> HermesClient? {
        guard let url = URL(string: hermesURL.trimmingCharacters(in: .whitespaces)), url.scheme?.hasPrefix("http") == true else {
            hermesError = "Enter a valid Hermes URL, e.g. http://127.0.0.1:8642"; return nil
        }
        guard !hermesKey.isEmpty else { hermesError = "Enter the Hermes API key (API_SERVER_KEY)"; return nil }
        return HermesClient(baseURL: url, apiKey: hermesKey)
    }

    func testHermes() {
        guard let c = hermesClient() else { return }
        hermesStatus = "Checking…"; hermesError = nil
        Task {
            do {
                let name = try await c.checkConnection()
                hermesStatus = "Connected to Hermes (\(name))"
            } catch {
                hermesStatus = "Not connected"; hermesError = "\(error)"
            }
        }
    }

    private func hermesToggled() {
        if hermesEnabled {
            hermesWindow.reset()
            hermesLastSent = Date()
            hermesError = nil
            hermesStatus = "On — first analysis in about \(hermesInterval) s of live data"
            append("Hermes analysis turned ON (sends data summaries to \(hermesURL))", traffic: false)
        } else {
            hermesStatus = "Off"
            append("Hermes analysis turned OFF", traffic: false)
        }
    }

    /// Called every ticker tick; sends a window when it's due.
    private func hermesTick(force: Bool = false) {
        guard hermesEnabled, !hermesBusy, phase.isLive, !hermesWindow.isEmpty else { return }
        if !force, let last = hermesLastSent, now.timeIntervalSince(last) < Double(hermesInterval) { return }
        sendToHermes(question: nil)
    }

    func askHermes() {
        let q = hermesQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !hermesBusy else { return }
        hermesQuestion = ""
        sendToHermes(question: q)
    }

    private func sendToHermes(question: String?) {
        guard let client = hermesClient() else { return }
        var window = hermesWindow
        if window.isEmpty {   // a question with no new window: use the latest values as a 1-sample window
            window.add(Array(latest.values))
        }
        let snapshot = HermesSnapshot(window: window, simulated: sessionIsSimulated, units: units, adapter: adapterInfo,
                                      pidStatus: pidStatus, dtc: dtcReport)
        var input = snapshot.render()
        if let question { input = "Question from the user: \(question)\n\nCurrent data:\n" + input }
        hermesWindow.reset()
        hermesLastSent = Date()
        hermesBusy = true
        hermesStatus = "Waiting for Hermes…"
        let instructions = HermesPrompt.instructions(intervalSeconds: hermesInterval)
        let previous = hermesPreviousID
        let simulated = sessionIsSimulated
        Task {
            defer { hermesBusy = false; hermesLastSent = Date() }
            do {
                let reply = try await client.analyze(input: input, instructions: instructions, previousResponseID: previous)
                if let id = reply.responseID { hermesPreviousID = id }
                hermesAnalyses.append(HermesAnalysis(at: Date(), question: question, sent: input, reply: reply.text, simulated: simulated))
                if hermesAnalyses.count > 200 { hermesAnalyses.removeFirst() }
                hermesError = nil
                hermesStatus = hermesEnabled ? "On — next analysis in about \(hermesInterval) s" : "Off"
            } catch {
                hermesError = "\(error)"
                hermesStatus = hermesEnabled ? "On — last request failed; will retry" : "Off"
                append("Hermes: \(error)", traffic: false)
            }
        }
    }

    private func note(_ s: String) { lastMessage = s; append(s, traffic: false) }

    private func append(_ s: String, traffic: Bool) {
        log.append(LogLine(at: Date(), text: s, isTraffic: traffic))
        if log.count > 2000 { log.removeFirst(log.count - 2000) }
    }

    // MARK: Display helpers

    func display(_ def: PIDDefinition) -> (value: String, unit: String) {
        let unit = units.convert(0, def.quantity).unit
        guard let r = latest[def.pid] else { return ("—", unit) }
        return (units.format(r.value, def), unit)
    }

    func statusNote(for def: PIDDefinition) -> String? {
        switch pidStatus[def.pid] {
        case .notAdvertised: return "Not supported by this vehicle"
        case .noResponse: return "Vehicle gave no data — treated as unsupported"
        default:
            if latest[def.pid] != nil, !dataIsFresh { return "Stale — last value shown" }
            return nil
        }
    }
}

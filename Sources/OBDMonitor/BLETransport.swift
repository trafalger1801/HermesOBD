import Foundation
import CoreBluetooth
import OBDCore

/// A BLE device seen during scanning.
struct BLEDevice: Identifiable, Hashable {
    let id: UUID
    var name: String
    var rssi: Int
    var advertisedServices: [String]

    /// Heuristic: advertises a service common on ELM327 BLE adapters, or has an OBD-ish name.
    /// The Innova 3210RS shows up as "Dongle" + digits and advertises FFF0.
    var looksLikeOBDAdapter: Bool {
        if advertisedServices.contains(where: { BLETransport.commonServiceUUIDs.contains($0) }) { return true }
        let n = name.lowercased()
        return ["obd", "elm", "dongle", "innova", "vlink", "vgate", "obdlink", "3210"].contains { n.contains($0) }
    }
}

/// Owns the single CBCentralManager (peripherals belong to the manager that found them).
/// Scanning is unfiltered because the adapter's service UUIDs are not documented.
final class BLECentral: NSObject, ObservableObject, CBCentralManagerDelegate, @unchecked Sendable {
    static let shared = BLECentral()

    @Published private(set) var state: CBManagerState = .unknown
    @Published private(set) var devices: [BLEDevice] = []
    @Published private(set) var isScanning = false

    let queue = DispatchQueue(label: "obd.ble")
    private(set) lazy var manager = CBCentralManager(delegate: self, queue: queue)
    private var peripherals: [UUID: CBPeripheral] = [:]
    weak var active: BLETransport?

    var stateDescription: String {
        switch state {
        case .poweredOn: return "Bluetooth on"
        case .poweredOff: return "Bluetooth is off — turn it on in Control Center"
        case .unauthorized: return "Bluetooth permission denied — allow it in System Settings › Privacy & Security › Bluetooth"
        case .unsupported: return "This Mac does not support Bluetooth LE"
        case .resetting: return "Bluetooth is resetting…"
        default: return "Bluetooth state unknown (permission prompt may be pending)"
        }
    }

    private var wantScan = false   // only touched on `queue`

    /// Starts scanning now, or as soon as Bluetooth is powered on.
    func startScan() {
        queue.async {
            self.wantScan = true
            guard self.manager.state == .poweredOn else { return }
            self.manager.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
            DispatchQueue.main.async { self.isScanning = true }
        }
    }

    func stopScan() {
        queue.async {
            self.wantScan = false
            self.manager.stopScan()
            DispatchQueue.main.async { self.isScanning = false }
        }
    }

    func peripheral(_ id: UUID) -> CBPeripheral? {
        if let p = peripherals[id] { return p }
        let p = manager.retrievePeripherals(withIdentifiers: [id]).first
        if let p { peripherals[id] = p }
        return p
    }

    // MARK: CBCentralManagerDelegate (called on `queue`)

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let s = central.state
        DispatchQueue.main.async { self.state = s }
        if s == .poweredOn, wantScan {
            central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
            DispatchQueue.main.async { self.isScanning = true }
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover p: CBPeripheral, advertisementData: [String: Any], rssi: NSNumber) {
        peripherals[p.identifier] = p
        let name = p.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? "(no name)"
        let services = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID])?.map(\.uuidString) ?? []
        let dev = BLEDevice(id: p.identifier, name: name, rssi: rssi.intValue, advertisedServices: services)
        DispatchQueue.main.async {
            if let i = self.devices.firstIndex(where: { $0.id == dev.id }) { self.devices[i] = dev } else { self.devices.append(dev) }
            func rank(_ d: BLEDevice) -> Int { d.looksLikeOBDAdapter ? 0 : (d.name == "(no name)" ? 2 : 1) }
            self.devices.sort { (rank($0), -$0.rssi) < (rank($1), -$1.rssi) }
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect p: CBPeripheral) { active?.didConnect(p) }
    func centralManager(_ central: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        active?.didFail("failed to connect: \(error?.localizedDescription ?? "unknown")")
    }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        active?.didFail("BLE disconnected\(error.map { ": \($0.localizedDescription)" } ?? "")")
    }
}

/// ELM327-style serial-over-BLE transport.
///
/// There is no single standard for this. Many ELM327 BLE adapters expose a vendor service with
/// one notify characteristic (replies) and one write characteristic (commands). The app tries
/// some commonly seen service UUIDs first, then falls back to any non-standard service that has
/// both. This is a heuristic: whatever it picks is written to the traffic log, and it is NOT a
/// claim about what the RepairSolutions2 adapter uses.
final class BLETransport: NSObject, OBDTransport, CBPeripheralDelegate, @unchecked Sendable {
    /// Seen on various generic ELM327 BLE clones. Not verified for any Innova product.
    static let commonServiceUUIDs = ["FFF0", "FFE0", "18F0", "E7810A71-73AE-499D-8C15-FAA9AEF0C3F2"]
    /// Standard GATT services that never carry the serial link.
    static let ignoredServices: Set<String> = ["1800", "1801", "180A", "180F", "FE59"]

    let deviceID: UUID
    let deviceName: String
    var displayName: String { "Bluetooth LE: \(deviceName)" }
    var isSimulated: Bool { false }
    /// Log callback for diagnostics (service/characteristic discovery).
    var log: ((String) -> Void)?

    private let central = BLECentral.shared
    private var peripheral: CBPeripheral?
    private var writeChar: CBCharacteristic?
    private var notifyChar: CBCharacteristic?
    private var onData: ((Data) -> Void)?
    private var onClose: ((String) -> Void)?
    private var openCont: CheckedContinuation<Void, Error>?
    private var pendingServices = 0
    private var closed = false

    init(deviceID: UUID, name: String) {
        self.deviceID = deviceID
        self.deviceName = name
    }

    func open(onData: @escaping (Data) -> Void, onClose: @escaping (String) -> Void) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            central.queue.async {
                self.onData = onData
                self.onClose = onClose
                self.openCont = cont
                guard self.central.manager.state == .poweredOn else {
                    self.finishOpen(.failure(TransportError(self.central.stateDescription))); return
                }
                guard let p = self.central.peripheral(self.deviceID) else {
                    self.finishOpen(.failure(TransportError("BLE device not found — scan again"))); return
                }
                self.central.active = self
                self.peripheral = p
                p.delegate = self
                self.log?("BLE: connecting to \(self.deviceName) [\(self.deviceID)]")
                self.central.manager.connect(p)
                self.central.queue.asyncAfter(deadline: .now() + 15) {
                    if self.openCont != nil {
                        self.finishOpen(.failure(TransportError("timed out connecting/discovering BLE services")))
                        self.central.manager.cancelPeripheralConnection(p)
                    }
                }
            }
        }
    }

    private func finishOpen(_ r: Result<Void, Error>) {
        guard let c = openCont else { return }
        openCont = nil
        c.resume(with: r)
    }

    func didConnect(_ p: CBPeripheral) {
        log?("BLE: connected; discovering services")
        p.discoverServices(nil)
    }

    func didFail(_ reason: String) {
        if openCont != nil { finishOpen(.failure(TransportError(reason))); return }
        guard !closed else { return }
        closed = true
        onClose?(reason)
    }

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        let services = p.services ?? []
        log?("BLE: services: " + services.map(\.uuid.uuidString).joined(separator: ", "))
        pendingServices = services.count
        if services.isEmpty { finishOpen(.failure(TransportError("device exposes no BLE services"))) }
        for s in services { p.discoverCharacteristics(nil, for: s) }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for c in service.characteristics ?? [] {
            log?("BLE:   \(service.uuid.uuidString) / \(c.uuid.uuidString) [\(Self.describe(c.properties))]")
        }
        pendingServices -= 1
        if pendingServices == 0 { chooseCharacteristics(p) }
    }

    private func chooseCharacteristics(_ p: CBPeripheral) {
        let services = (p.services ?? []).filter { !Self.ignoredServices.contains($0.uuid.uuidString) }
        let ordered = services.sorted { a, b in
            let ia = Self.commonServiceUUIDs.firstIndex(of: a.uuid.uuidString) ?? Int.max
            let ib = Self.commonServiceUUIDs.firstIndex(of: b.uuid.uuidString) ?? Int.max
            return ia < ib
        }
        for s in ordered {
            let chars = s.characteristics ?? []
            let n = chars.first { $0.properties.contains(.notify) || $0.properties.contains(.indicate) }
            let w = chars.first { $0.properties.contains(.write) || $0.properties.contains(.writeWithoutResponse) }
            if let n, let w {
                notifyChar = n; writeChar = w
                log?("BLE: using service \(s.uuid.uuidString): notify \(n.uuid.uuidString), write \(w.uuid.uuidString) (heuristic choice)")
                p.setNotifyValue(true, for: n)
                return
            }
        }
        finishOpen(.failure(TransportError("no service with both notify and write characteristics — this adapter may not offer an ELM327-style BLE link (it may require its own phone app)")))
        central.manager.cancelPeripheralConnection(p)
    }

    func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor c: CBCharacteristic, error: Error?) {
        if let error { finishOpen(.failure(TransportError("could not enable notifications: \(error.localizedDescription)"))); return }
        log?("BLE: notifications enabled; link open (adapter has not answered yet)")
        finishOpen(.success(()))
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        guard c == notifyChar, let v = c.value else { return }
        onData?(v)
    }

    func write(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            central.queue.async {
                guard !self.closed, let p = self.peripheral, let w = self.writeChar else {
                    cont.resume(throwing: TransportError("BLE link not open")); return
                }
                let type: CBCharacteristicWriteType = w.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
                let maxLen = max(20, p.maximumWriteValueLength(for: type))
                var offset = 0
                while offset < data.count {
                    let end = min(offset + maxLen, data.count)
                    p.writeValue(data.subdata(in: offset..<end), for: w, type: type)
                    offset = end
                }
                cont.resume()
            }
        }
    }

    func close() {
        central.queue.async {
            self.closed = true
            if let n = self.notifyChar, let p = self.peripheral, p.state == .connected { p.setNotifyValue(false, for: n) }
            if let p = self.peripheral { self.central.manager.cancelPeripheralConnection(p) }
            if self.central.active === self { self.central.active = nil }
        }
    }

    static func describe(_ p: CBCharacteristicProperties) -> String {
        var out: [String] = []
        if p.contains(.read) { out.append("read") }
        if p.contains(.write) { out.append("write") }
        if p.contains(.writeWithoutResponse) { out.append("writeNoResp") }
        if p.contains(.notify) { out.append("notify") }
        if p.contains(.indicate) { out.append("indicate") }
        return out.joined(separator: ",")
    }
}

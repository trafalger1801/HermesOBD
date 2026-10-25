import AppKit
import OBDCore

/// Developer self-check: `OBD_SELFCHECK_DIR=/some/dir open -a ...` (or run the binary with that env var).
/// Connects to the built-in simulator, saves PNGs of the app's own window for each tab, then quits.
/// Captures only this app's window; no screen-recording permission is involved.
@MainActor
enum SelfCheck {
    static func runIfRequested(model: AppModel) {
        guard let dir = ProcessInfo.processInfo.environment["OBD_SELFCHECK_DIR"] else { return }
        let out = URL(fileURLWithPath: dir)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        if ProcessInfo.processInfo.environment["OBD_SELFCHECK_BLESCAN"] == "1" { bleScan(out); return }
        if let name = ProcessInfo.processInfo.environment["OBD_SELFCHECK_BLEPROBE"] { bleProbe(out, name: name); return }
        if let name = ProcessInfo.processInfo.environment["OBD_SELFCHECK_BLELIVE"] {
            // Full read-only session with a real BLE adapter: live data + trouble-code read. Never clears.
            let ble = BLECentral.shared
            _ = ble.manager
            model.source = .ble
            let steps: [(Double, () -> Void)] = [
                (2, { ble.startScan() }),
                (10, { ble.stopScan()
                       model.selectedBLE = ble.devices.first { $0.name == name }
                       if model.selectedBLE != nil { model.connect() } }),
                (30, { snap(out, "11-ble-live") ; model.selectedTab = 1; model.readDTCs() }),
                (38, { snap(out, "12-ble-dtc"); model.selectedTab = 2 }),
                (39, { snap(out, "13-ble-log")
                       let text = model.log.map { "\($0.at.formatted(date: .omitted, time: .standard))  \($0.text)" }.joined(separator: "\n")
                       try? text.write(to: out.appendingPathComponent("ble-live-log.txt"), atomically: true, encoding: .utf8)
                       model.disconnect() }),
                (40, { NSApp.terminate(nil) }),
            ]
            for (t, f) in steps { DispatchQueue.main.asyncAfter(deadline: .now() + t) { f() } }
            return
        }
        // Window background isn't captured by cacheDisplay, so use light mode for legible PNGs.
        NSApp.appearance = NSAppearance(named: .aqua)
        model.source = .simulator
        AppModel.persistSettings = false
        let env = ProcessInfo.processInfo.environment
        if let hURL = env["OBD_SELFCHECK_HERMES_URL"], let hKey = env["OBD_SELFCHECK_HERMES_KEY"] {
            // Hermes check against a mock server: key is kept in memory only (not saved to Keychain).
            model.hermesURL = hURL; model.hermesKey = hKey == "keychain" ? (Keychain.read() ?? "") : hKey; model.hermesInterval = 15
            model.connect()
            let steps: [(Double, () -> Void)] = [
                (4, { model.hermesEnabled = true }),
                (6, { model.readDTCs() }),                 // a DTC read triggers an immediate analysis
                (9, { model.hermesQuestion = "Are the fuel trims OK?"; model.askHermes() }),
                (28, { model.selectedTab = 3 }),
                (30, { snap(out, "7-hermes"); model.disconnect() }),
                (31, { NSApp.terminate(nil) }),
            ]
            for (t, f) in steps { DispatchQueue.main.asyncAfter(deadline: .now() + t) { f() } }
            return
        }
        if env["OBD_SELFCHECK_CLEAR"] == "1" {
            // Clear-codes check on the simulator: engine running (refused), then engine off (cleared).
            model.simEngineRunning = true
            model.connect()
            var sheetAlert: NSAlert?
            let steps: [(Double, () -> Void)] = [
                (4, { model.selectedTab = 1; model.readDTCs() }),
                (6, { model.clearingEnabled = true }),
                (7, {   // show the confirmation as a sheet so it can be captured, then cancel it
                    guard let win = NSApp.windows.first(where: { $0.isVisible }), let (a, f) = ClearConfirmation.makeAlert(model) else { return }
                    f.stringValue = "CLEAR"; sheetAlert = a
                    a.beginSheetModal(for: win) { _ in }
                }),
                (8, { if let w = sheetAlert?.window { snapWindow(w, out, "8-clear-confirm") }
                      if let a = sheetAlert, let parent = a.window.sheetParent { parent.endSheet(a.window) } }),
                (9, { model.clearCodesConfirmed() }),            // engine running → app must refuse
                (13, { snap(out, "9-clear-refused"); model.simEngineRunning = false }),
                (15, { model.clearingEnabled = true }),
                (16, { model.clearCodesConfirmed() }),           // engine off → cleared
                (21, { snap(out, "10-clear-done"); model.disconnect() }),
                (22, { NSApp.terminate(nil) }),
            ]
            for (t, f) in steps { DispatchQueue.main.asyncAfter(deadline: .now() + t) { f() } }
            return
        }
        model.connect()
        let steps: [(Double, () -> Void)] = [
            (5, { model.startLogging() }),
            (8, { snap(out, "1-live-data"); model.readDTCs() }),
            (10, { model.selectedTab = 1 }),
            (11, { snap(out, "2-trouble-codes"); model.selectedTab = 2 }),
            (12, { snap(out, "3-adapter-log"); model.simulateDropout() }),
            (12.6, { model.selectedTab = 0 }),
            (13.2, { snap(out, "4-during-dropout") }),
            (22, { snap(out, "5-after-reconnect"); model.stopLogging(); model.disconnect() }),
            (23, { snap(out, "6-disconnected"); NSApp.terminate(nil) }),
        ]
        for (t, f) in steps { DispatchQueue.main.asyncAfter(deadline: .now() + t) { f() } }
    }

    /// Scans for Bluetooth LE devices for 25 s and writes everything heard to ble-scan.txt. Read-only: no connections.
    static func bleScan(_ out: URL) {
        let ble = BLECentral.shared
        _ = ble.manager
        var lines: [String] = []
        func write() {
            try? (lines.joined(separator: "\n") + "\n").write(to: out.appendingPathComponent("ble-scan.txt"), atomically: true, encoding: .utf8)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            lines.append("bluetooth state: \(ble.stateDescription) (raw \(ble.state.rawValue))")
            write()
            guard ble.state == .poweredOn else { NSApp.terminate(nil); return }
            ble.startScan()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 28) {
            ble.stopScan()
            lines.append("devices heard: \(ble.devices.count)")
            for d in ble.devices.sorted(by: { $0.rssi > $1.rssi }) {
                lines.append("\(d.rssi) dBm | name=\(d.name) | id=\(d.id) | services=\(d.advertisedServices.joined(separator: ","))")
            }
            write()
            NSApp.terminate(nil)
        }
    }

    /// Connects to the named BLE device and sends identification + read-only requests only.
    static func bleProbe(_ out: URL, name: String) {
        let ble = BLECentral.shared
        _ = ble.manager
        var lines: [String] = []
        let lock = NSLock()
        func log(_ s: String) {
            lock.withLock { lines.append(s) }
            try? (lock.withLock { lines.joined(separator: "\n") } + "\n").write(to: out.appendingPathComponent("ble-probe.txt"), atomically: true, encoding: .utf8)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { ble.startScan() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
            ble.stopScan()
            guard let d = ble.devices.first(where: { $0.name == name }) else {
                log("device \(name) not found in scan"); NSApp.terminate(nil); return
            }
            log("found \(d.name) rssi=\(d.rssi) id=\(d.id)")
            let t = BLETransport(deviceID: d.id, name: d.name)
            t.log = { log($0) }
            let session = ELM327Session(transport: t)
            session.trafficLog = { log($0) }
            Task {
                do {
                    try await session.open()
                    for (cmd, timeout) in [("ATZ", 5.0), ("ATE0", 2.0), ("ATI", 2.0), ("AT@1", 2.0), ("ATRV", 2.0)] {
                        do { _ = try await session.send(cmd, timeout: timeout) } catch { log("  \(cmd) error: \(error)") }
                    }
                    do { _ = try await session.send("0100", timeout: 15) } catch { log("  0100 error: \(error)") }
                    do { _ = try await session.send("ATDPN", timeout: 2) } catch { log("  ATDPN error: \(error)") }
                } catch {
                    log("open failed: \(error)")
                }
                session.close()
                log("done")
                try? await Task.sleep(nanoseconds: 500_000_000)
                await MainActor.run { NSApp.terminate(nil) }
            }
        }
    }

    static func snapWindow(_ w: NSWindow, _ dir: URL, _ name: String) {
        guard let view = w.contentView?.superview ?? w.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent(name + ".png"))
    }

    static func snap(_ dir: URL, _ name: String) {
        guard let view = NSApp.windows.first(where: { $0.isVisible && $0.sheetParent == nil })?.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent(name + ".png"))
    }
}

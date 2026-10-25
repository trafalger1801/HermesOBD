import Foundation

/// A byte pipe to an ELM327-compatible adapter (BLE, serial, TCP, or the simulator).
public protocol OBDTransport: AnyObject {
    /// Human-readable description, e.g. "Bluetooth LE: OBDII" or "Simulator".
    var displayName: String { get }
    /// True only for the built-in simulator. Everything it produces is labeled SIMULATED.
    var isSimulated: Bool { get }
    /// Opens the link. `onData` receives raw bytes; `onClose` fires once if the link drops.
    func open(onData: @escaping (Data) -> Void, onClose: @escaping (String) -> Void) async throws
    func write(_ data: Data) async throws
    func close()
}

public struct TransportError: Error, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// Thread-safe accumulator for adapter output.
final class ResponseBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""

    func append(_ data: Data) {
        let s = String(decoding: data.filter { $0 != 0 && $0 < 0x80 }, as: UTF8.self)
        lock.lock(); text += s; lock.unlock()
    }

    func reset() { lock.lock(); text = ""; lock.unlock() }

    /// If a '>' prompt has arrived, removes and returns everything before it.
    func takeUntilPrompt() -> String? {
        lock.lock(); defer { lock.unlock() }
        guard let r = text.firstIndex(of: ">") else { return nil }
        let out = String(text[..<r])
        text = String(text[text.index(after: r)...])
        return out
    }
}

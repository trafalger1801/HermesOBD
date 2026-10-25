import Foundation

/// Request/response conversation with an ELM327-compatible adapter.
/// Not safe for concurrent `send` calls; `OBDEngine` drives it from a single task.
public final class ELM327Session: @unchecked Sendable {
    public let transport: OBDTransport
    private let buffer = ResponseBuffer()
    private let lock = NSLock()
    private var closeReason: String?
    /// Called with every command sent and raw reply (for the traffic log).
    public var trafficLog: ((String) -> Void)?

    public init(transport: OBDTransport) { self.transport = transport }

    public var isClosed: Bool { lock.lock(); defer { lock.unlock() }; return closeReason != nil }

    public func open() async throws {
        try await transport.open(
            onData: { [buffer] data in buffer.append(data) },
            onClose: { [weak self] reason in
                guard let self else { return }
                self.lock.lock()
                if self.closeReason == nil { self.closeReason = reason }
                self.lock.unlock()
            })
    }

    public func close() {
        lock.lock(); if closeReason == nil { closeReason = "closed by app" }; lock.unlock()
        transport.close()
    }

    /// Sends one command (after the read-only check) and returns the cleaned reply text.
    public func send(_ raw: String, timeout: TimeInterval = 2.0, permit: ReadOnlyGuard.ClearCodesPermit? = nil) async throws -> String {
        let cmd = try ReadOnlyGuard.validate(raw, permit: permit)
        if let r = currentCloseReason() { throw OBDError.disconnected(r) }
        buffer.reset()
        trafficLog?("> \(cmd)")
        do {
            try await transport.write(Data((cmd + "\r").utf8))
        } catch {
            throw OBDError.disconnected("write failed: \(error)")
        }
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let text = buffer.takeUntilPrompt() {
                let cleaned = Self.clean(text, command: cmd)
                trafficLog?("< \(cleaned.isEmpty ? "(empty)" : cleaned.replacingOccurrences(of: "\n", with: " | "))")
                return cleaned
            }
            if let r = currentCloseReason() { throw OBDError.disconnected(r) }
            if Date() > deadline {
                trafficLog?("< (timeout after \(timeout)s)")
                // Give a late reply a moment to arrive so it isn't mistaken for the next answer.
                try? await Task.sleep(nanoseconds: 300_000_000)
                buffer.reset()
                throw OBDError.timeout
            }
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    /// Sends a request and parses it into OBD messages.
    public func request(_ cmd: String, timeout: TimeInterval = 2.0) async throws -> [[UInt8]] {
        let text = try await send(cmd, timeout: timeout)
        return try ELMResponse.parse(text)
    }

    private func currentCloseReason() -> String? { lock.lock(); defer { lock.unlock() }; return closeReason }

    /// Removes NULs, echo of the command, and blank lines.
    static func clean(_ text: String, command: String) -> String {
        text.replacingOccurrences(of: "\0", with: "")
            .components(separatedBy: CharacterSet(charactersIn: "\r\n"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0.uppercased().replacingOccurrences(of: " ", with: "") != command }
            .joined(separator: "\n")
    }
}

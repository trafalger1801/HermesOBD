import Foundation
import Network

/// TCP transport for Wi-Fi ELM327 adapters (the Mac joins the adapter's Wi-Fi network).
/// Many Wi-Fi clones listen on 192.168.0.10:35000, but check your adapter's documentation.
public final class TCPTransport: OBDTransport, @unchecked Sendable {
    public let host: String
    public let port: UInt16
    public var displayName: String { "Wi-Fi/TCP: \(host):\(port)" }
    public var isSimulated: Bool { false }
    private var conn: NWConnection?
    private let queue = DispatchQueue(label: "obd.tcp")
    private var closed = false
    private var onClose: ((String) -> Void)?

    public init(host: String, port: UInt16) { self.host = host; self.port = port }

    public func open(onData: @escaping (Data) -> Void, onClose: @escaping (String) -> Void) async throws {
        guard let p = NWEndpoint.Port(rawValue: port) else { throw TransportError("invalid port") }
        let c = NWConnection(host: NWEndpoint.Host(host), port: p, using: .tcp)
        conn = c
        self.onClose = onClose
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            // All callbacks run on `queue`, so this flag is only touched from one thread.
            final class Once: @unchecked Sendable { var done = false }
            let once = Once()
            let finish: @Sendable (Result<Void, Error>) -> Void = { r in
                guard !once.done else { return }
                once.done = true
                cont.resume(with: r)
            }
            c.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready: finish(.success(()))
                case .waiting(let e): finish(.failure(TransportError("cannot reach \(self?.host ?? "")…: \(e)"))); c.cancel()
                case .failed(let e):
                    finish(.failure(TransportError("connection failed: \(e)")))
                    self?.fail("connection failed: \(e)")
                case .cancelled: finish(.failure(TransportError("cancelled"))); self?.fail("connection closed")
                default: break
                }
            }
            c.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 8) {
                if !once.done { finish(.failure(TransportError("timed out connecting to \(self.host):\(self.port)"))); c.cancel() }
            }
        }
        receive(c, onData)
    }

    private func receive(_ c: NWConnection, _ onData: @escaping (Data) -> Void) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, done, error in
            if let data, !data.isEmpty { onData(data) }
            if done || error != nil {
                self?.fail(error.map { "receive error: \($0)" } ?? "adapter closed the connection")
                return
            }
            self?.receive(c, onData)
        }
    }

    public func write(_ data: Data) async throws {
        guard let c = conn, !closed else { throw TransportError("not connected") }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            c.send(content: data, completion: .contentProcessed { e in
                if let e { cont.resume(throwing: TransportError("send failed: \(e)")) } else { cont.resume() }
            })
        }
    }

    private func fail(_ reason: String) {
        queue.async {
            guard !self.closed else { return }
            self.closed = true
            self.onClose?(reason)
            self.conn?.cancel()
        }
    }

    public func close() {
        queue.async {
            self.closed = true
            self.conn?.cancel()
        }
    }
}

import Foundation
import Darwin

/// Serial-port transport. Used for Bluetooth Classic (SPP) adapters, which macOS exposes as
/// /dev/cu.<name> after pairing, and for USB ELM327 cables.
public final class SerialTransport: OBDTransport, @unchecked Sendable {
    public let path: String
    public let baud: speed_t
    public var displayName: String { "Serial: \(path)" }
    public var isSimulated: Bool { false }
    private var fd: Int32 = -1
    private var source: DispatchSourceRead?
    private let queue = DispatchQueue(label: "obd.serial")
    private var onClose: ((String) -> Void)?
    private var closed = false

    public init(path: String, baud: speed_t = 38400) {
        self.path = path
        self.baud = baud
    }

    /// Lists /dev/cu.* devices (callout ports; the right choice for initiating connections).
    public static func availablePorts() -> [String] {
        let items = (try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []
        return items.filter { $0.hasPrefix("cu.") }.sorted().map { "/dev/" + $0 }
    }

    public func open(onData: @escaping (Data) -> Void, onClose: @escaping (String) -> Void) async throws {
        let fd = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else {
            throw TransportError("Could not open \(path): \(String(cString: strerror(errno))). " +
                                 "For Bluetooth Classic, pair the adapter in System Settings first.")
        }
        var t = termios()
        if tcgetattr(fd, &t) == 0 {
            cfmakeraw(&t)
            cfsetspeed(&t, baud)
            t.c_cflag |= tcflag_t(CLOCAL | CREAD)
            _ = tcsetattr(fd, TCSANOW, &t)
        }
        self.fd = fd
        self.onClose = onClose
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [weak self] in
            guard let self else { return }
            var buf = [UInt8](repeating: 0, count: 1024)
            let n = read(fd, &buf, buf.count)
            if n > 0 {
                onData(Data(buf[0..<n]))
            } else if n == 0 || (errno != EAGAIN && errno != EINTR) {
                self.fail("serial port closed (\(n == 0 ? "EOF" : String(cString: strerror(errno))))")
            }
        }
        src.setCancelHandler { Darwin.close(fd) }
        source = src
        src.resume()
    }

    public func write(_ data: Data) async throws {
        try queue.sync {
            guard !closed, fd >= 0 else { throw TransportError("serial port not open") }
            var offset = 0
            let bytes = [UInt8](data)
            var spins = 0
            while offset < bytes.count {
                let n = bytes[offset...].withUnsafeBufferPointer { Darwin.write(fd, $0.baseAddress, $0.count) }
                if n > 0 { offset += n; continue }
                if errno == EAGAIN, spins < 200 { spins += 1; usleep(1000); continue }
                let msg = "serial write failed: \(String(cString: strerror(errno)))"
                fail(msg)
                throw TransportError(msg)
            }
        }
    }

    private func fail(_ reason: String) {
        guard !closed else { return }
        closed = true
        source?.cancel()
        onClose?(reason)
    }

    public func close() {
        queue.async {
            guard !self.closed else { return }
            self.closed = true
            self.source?.cancel()
        }
    }
}

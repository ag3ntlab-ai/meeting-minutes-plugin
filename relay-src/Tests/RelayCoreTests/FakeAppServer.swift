import Foundation
import Darwin
@testable import RelayCore

/// Stands in for the app's socket server: admission frame, then one request frame, then one response frame.
final class FakeAppServer: @unchecked Sendable {
    let path: String
    private let dir: String
    private var listener: Int32 = -1
    private let lock = NSLock()
    private var _received: [AutomationRequest] = []
    private var _handler: (AutomationRequest) -> AutomationResponse
    var admit = true
    var received: [AutomationRequest] { lock.lock(); defer { lock.unlock() }; return _received }
    var handler: (AutomationRequest) -> AutomationResponse {
        get { lock.lock(); defer { lock.unlock() }; return _handler }
        set { lock.lock(); _handler = newValue; lock.unlock() }
    }

    init(handler: @escaping (AutomationRequest) -> AutomationResponse) {
        dir = "/tmp/mmrelay-" + String(UUID().uuidString.prefix(8))
        try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        path = dir + "/a.sock"
        _handler = handler
    }
    func start() {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX); addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(path.utf8) + [0]
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: bytes) }
        let bound = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        precondition(bound == 0 && listen(fd, 8) == 0, "fake server cannot listen")
        listener = fd
        Thread.detachNewThread { [self] in
            while true {
                var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                if poll(&p, 1, 50) <= 0 { if self.listener != fd { return }; continue }
                let client = accept(fd, nil, nil)
                if client >= 0 { self.serve(client) }
            }
        }
    }
    func stop() { let fd = listener; listener = -1; if fd >= 0 { close(fd) }; unlink(path); try? FileManager.default.removeItem(atPath: dir) }

    private func writeFrame(_ data: Data, _ fd: Int32) {
        let framed = try! Frame.encode(data)
        framed.withUnsafeBytes { _ = Darwin.send(fd, $0.baseAddress!, $0.count, 0) }
    }
    private func serve(_ client: Int32) {
        defer { close(client) }
        writeFrame(try! JSONEncoder().encode(PeerAdmission(allowed: admit)), client)
        guard admit else { return }
        var decoder = Frame.Decoder(); var buf = [UInt8](repeating: 0, count: 8192)
        var request: AutomationRequest?
        while request == nil {
            let n = recv(client, &buf, buf.count, 0)
            if n <= 0 { return }
            if let frame = try? decoder.append(Data(buf.prefix(n))).first { request = try? JSONDecoder().decode(AutomationRequest.self, from: frame) }
        }
        lock.lock(); _received.append(request!); lock.unlock()
        var response = handler(request!)
        response.id = request!.id
        writeFrame(try! JSONEncoder().encode(response), client)
    }
}

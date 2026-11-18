import Foundation
import Darwin

// Wire format of the Meeting Minutes automation socket (build 37): AutomationRequest v1,
// four-byte big-endian length frames, an admission frame sent first by the app.

public enum RelayError: Error, Equatable {
    case invalidFrame, correlation, version, timeout, unavailable, peerDenied, disabled, system(Int32)
}

public struct AutomationRequest: Codable, Sendable {
    public var version: Int
    public var id: String
    public var operation: String
    public var parameters: [String: String]
    public init(version: Int = 1, id: String = UUID().uuidString, operation: String, parameters: [String: String] = [:]) {
        self.version = version; self.id = id; self.operation = operation; self.parameters = parameters
    }
}
public struct AutomationFailure: Codable, Sendable {
    public let code: String
    public let message: String
    public init(code: String, message: String) { self.code = code; self.message = message }
}
public struct AutomationResponse: Codable, Sendable {
    public var version: Int
    public var id: String
    /// JSON bytes (base64 on the wire, as Codable does for Data).
    public var result: Data?
    public var error: AutomationFailure?
    public init(version: Int = 1, id: String, result: Data? = nil, error: AutomationFailure? = nil) {
        self.version = version; self.id = id; self.result = result; self.error = error
    }
}
struct PeerAdmission: Codable { let allowed: Bool }

/// Request plus the transport-only deadline the app uses to drop requests nobody waits for any more.
struct TimedRequest: Encodable {
    let request: AutomationRequest
    let deadlineUptime: TimeInterval
    private enum CodingKeys: String, CodingKey { case deadlineUptime = "_clientDeadlineUptime" }
    func encode(to encoder: Encoder) throws {
        try request.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(deadlineUptime, forKey: .deadlineUptime)
    }
}

public enum Frame {
    public static let maximumSize = 1_048_576
    public static func encode(_ payload: Data) throws -> Data {
        guard !payload.isEmpty, payload.count <= maximumSize else { throw RelayError.invalidFrame }
        let n = UInt32(payload.count)
        return Data([UInt8(n >> 24), UInt8((n >> 16) & 255), UInt8((n >> 8) & 255), UInt8(n & 255)]) + payload
    }
    public struct Decoder {
        private var buffer = Data()
        public init() {}
        public mutating func append(_ data: Data) throws -> [Data] {
            buffer.append(data)
            var frames: [Data] = []
            while buffer.count >= 4 {
                let size = buffer.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
                guard size > 0, size <= maximumSize else { throw RelayError.invalidFrame }
                guard buffer.count >= size + 4 else { break }
                frames.append(Data(buffer.dropFirst(4).prefix(size)))
                buffer = Data(buffer.dropFirst(size + 4))
            }
            return frames
        }
    }
}

private func uptime() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

private func wait(_ fd: Int32, _ events: Int16, until deadline: TimeInterval) throws {
    while true {
        let left = deadline - uptime()
        guard left > 0 else { throw RelayError.timeout }
        var p = pollfd(fd: fd, events: events, revents: 0)
        let result = poll(&p, 1, Int32(min(left * 1000 + 1, Double(Int32.max))))
        if result > 0 { return }
        if result == 0 { throw RelayError.timeout }
        if errno != EINTR { throw RelayError.system(errno) }
    }
}
private func send(_ data: Data, fd: Int32, until deadline: TimeInterval) throws {
    let framed = try Frame.encode(data)
    try framed.withUnsafeBytes { bytes in
        var offset = 0
        while offset < bytes.count {
            try wait(fd, Int16(POLLOUT), until: deadline)
            let n = Darwin.send(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, 0)
            if n < 0, errno == EINTR || errno == EAGAIN { continue }
            guard n > 0 else { throw RelayError.system(errno) }
            offset += n
        }
    }
}
private func receive(fd: Int32, until deadline: TimeInterval) throws -> Data {
    var decoder = Frame.Decoder()
    var bytes = [UInt8](repeating: 0, count: 8192)
    while true {
        try wait(fd, Int16(POLLIN), until: deadline)
        let n = recv(fd, &bytes, bytes.count, 0)
        if n < 0, errno == EINTR || errno == EAGAIN { continue }
        guard n > 0 else { throw RelayError.unavailable }
        if let frame = try decoder.append(Data(bytes.prefix(n))).first { return frame }
    }
}

public enum SocketClient {
    /// One attempt. yagni: no automatic retry on timeout (the app-side helper retries reads by operation name;
    /// this relay knows no operation names). Upgrade path: a read-only hint in the catalog.
    public static func exchange(_ request: AutomationRequest, path: String, timeout: TimeInterval) throws -> AutomationResponse {
        let deadline = uptime() + timeout
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw RelayError.system(errno) }
        defer { close(fd) }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout.size(ofValue: one)))
        guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { throw RelayError.system(errno) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else { throw RelayError.unavailable }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: bytes) }
        let connected = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        if connected != 0 {
            guard errno == EINPROGRESS else { throw RelayError.system(errno) }
            try wait(fd, Int16(POLLOUT), until: deadline)
            var error: Int32 = 0, length = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0 else { throw RelayError.system(errno) }
            guard error == 0 else { throw RelayError.system(error) }
        }
        // Only a listener run by the same user is trusted.
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else { throw RelayError.peerDenied }
        let admission = try JSONDecoder().decode(PeerAdmission.self, from: receive(fd: fd, until: deadline))
        guard admission.allowed else { throw RelayError.peerDenied }
        try send(JSONEncoder().encode(TimedRequest(request: request, deadlineUptime: deadline)), fd: fd, until: deadline)
        let response = try JSONDecoder().decode(AutomationResponse.self, from: receive(fd: fd, until: deadline))
        guard response.version == 1, request.version == 1 else { throw RelayError.version }
        guard response.id == request.id else { throw RelayError.correlation }
        if response.error?.code == "peerDenied" { throw RelayError.peerDenied }
        return response
    }
}

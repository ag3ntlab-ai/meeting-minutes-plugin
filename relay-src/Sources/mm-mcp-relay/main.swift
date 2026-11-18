import Foundation
import RelayCore

// MM_STORE_FIXTURE (UUID only) selects a disposable app instance, like the app's own helper.
// An invalid value stops the relay: it must never fall back to the real store.
let fixture: String? = {
    let value = ProcessInfo.processInfo.environment["MM_STORE_FIXTURE"]
    guard let id = try? Endpoint.fixtureID(value) else {
        FileHandle.standardError.write(Data("mm-mcp-relay: MM_STORE_FIXTURE is not a UUID\n".utf8)); exit(2)
    }
    return id
}()

let server = RelayServer { request, timeout in
    let transport = SocketTransport(path: try Endpoint.socketURL(fixture: fixture).path, launch: {
        guard let app = AppLocator.find() else { throw RelayError.unavailable }
        try AppLauncher.launch(app: app, fixture: fixture)
    })
    return try transport.exchange(request, timeout: timeout)
}

var buffer = Data()
while true {
    let chunk = FileHandle.standardInput.availableData
    if chunk.isEmpty { break }
    buffer.append(chunk)
    if buffer.count > Frame.maximumSize { FileHandle.standardError.write(Data("mm-mcp-relay: oversized stdio message\n".utf8)); exit(1) }
    while let newline = buffer.firstIndex(of: 10) {
        let line = Data(buffer[..<newline]); buffer.removeSubrange(...newline)
        if let out = server.handle(line: line) { FileHandle.standardOutput.write(out + Data([10])) }
    }
}

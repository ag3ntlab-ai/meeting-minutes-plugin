import Foundation
import Darwin

/// Talks to the app. `launch` is called once when nothing listens; then we wait up to `launchWindow`.
public struct SocketTransport {
    public var path: String
    public var launch: () throws -> Void
    public var launchWindow: TimeInterval = 15
    public init(path: String, launch: @escaping () throws -> Void, launchWindow: TimeInterval = 15) {
        self.path = path; self.launch = launch; self.launchWindow = launchWindow
    }
    func notListening(_ error: Error) -> Bool {
        if case RelayError.system(let code) = error { return code == ENOENT || code == ECONNREFUSED }
        return false
    }
    public func exchange(_ request: AutomationRequest, timeout: TimeInterval) throws -> AutomationResponse {
        do { return try SocketClient.exchange(request, path: path, timeout: timeout) }
        catch where notListening(error) {
            let deadline = Date().addingTimeInterval(launchWindow)
            try launch()
            while Date() < deadline {
                do { return try SocketClient.exchange(request, path: path, timeout: max(0.1, min(2, deadline.timeIntervalSinceNow))) }
                catch where notListening(error) { Thread.sleep(forTimeInterval: 0.05) }
            }
            throw RelayError.timeout
        }
    }
}

/// MCP over stdio, one JSON object per line. The tool list is never written here: it is the app's `discover` answer.
public final class RelayServer {
    public typealias Exchange = (AutomationRequest, TimeInterval) throws -> AutomationResponse
    private let exchange: Exchange
    public init(exchange: @escaping Exchange) { self.exchange = exchange }

    static let discoverOperation = "discover"

    public func handle(line: Data) -> Data? {
        guard let rpc = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
            return encode(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]])
        }
        guard let id = rpc["id"] else { return nil } // notifications, including initialized
        return encode(respond(to: rpc, id: id))
    }

    private func respond(to rpc: [String: Any], id: Any) -> [String: Any] {
        func reply(_ result: [String: Any]) -> [String: Any] { ["jsonrpc": "2.0", "id": id, "result": result] }
        func fail(_ code: Int, _ message: String) -> [String: Any] { ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]] }
        guard rpc["jsonrpc"] as? String == "2.0", let method = rpc["method"] as? String else { return fail(-32600, "Invalid request") }
        switch method {
        case "initialize":
            return reply(["protocolVersion": "2024-11-05", "capabilities": ["tools": [:]], "serverInfo": ["name": "Meeting Minutes", "version": "1.0"]])
        case "ping": return reply([:])
        case "tools/list":
            do { return reply(["tools": try catalog()]) } catch { return fail(-32000, Self.text(for: error)) }
        case "tools/call":
            guard let params = rpc["params"] as? [String: Any], let name = params["name"] as? String,
                  let args = (params["arguments"] ?? [String: Any]()) as? [String: Any], args.values.allSatisfy({ $0 is String })
            else { return fail(-32602, "Invalid parameters") }
            do {
                let response = try exchange(.init(operation: name, parameters: args.compactMapValues { $0 as? String }), 120)
                if let failure = response.error {
                    let object = ["code": failure.code, "message": failure.message]
                    let text = String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
                    return reply(["content": [["type": "text", "text": text]], "isError": true])
                }
                guard let result = response.result else { throw RelayError.invalidFrame }
                return reply(["content": [["type": "text", "text": String(decoding: result, as: UTF8.self)]], "isError": false])
            } catch { return fail(-32000, Self.text(for: error)) }
        default: return fail(-32601, "Method not found")
        }
    }

    /// `discover` answers either a full catalog (`tools`: name, description, inputSchema, annotations ...) or, as build 37
    /// does, only `{version, operations}`; then each name becomes a tool with no schema.
    func catalog() throws -> [[String: Any]] {
        let response = try exchange(.init(operation: Self.discoverOperation), 5)
        if let failure = response.error { throw NSError(domain: "discover", code: 1, userInfo: [NSLocalizedDescriptionKey: failure.message]) }
        guard let data = response.result, let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw RelayError.invalidFrame }
        if let tools = object["tools"] as? [[String: Any]] {
            return tools.compactMap { tool in
                guard tool["name"] is String else { return nil }
                var tool = tool
                if tool["inputSchema"] == nil { tool["inputSchema"] = ["type": "object"] }
                return tool
            }
        }
        guard let names = object["operations"] as? [String] else { throw RelayError.invalidFrame }
        return names.map { ["name": $0, "description": "", "inputSchema": ["type": "object"]] }
    }

    static func text(for error: Error) -> String {
        switch error as? RelayError {
        case .peerDenied: return "Meeting Minutes refused this connection. Check that agent access is turned on in the app."
        case .timeout: return "Meeting Minutes did not answer in time."
        default: return "Meeting Minutes is not available. Make sure the app is installed, then try again."
        }
    }
    private func encode(_ object: [String: Any]) -> Data? { try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) }
}

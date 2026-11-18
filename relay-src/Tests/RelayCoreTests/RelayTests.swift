import XCTest
@testable import RelayCore

final class RelayTests: XCTestCase {
    private func json(_ object: Any) -> Data { try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) }
    private func rpc(_ object: [String: Any]) -> Data { json(object) }
    private func call(_ server: RelayServer, _ object: [String: Any]) -> [String: Any] {
        guard let out = server.handle(line: rpc(object)),
              let reply = (try? JSONSerialization.jsonObject(with: out)) as? [String: Any] else { XCTFail("no usable reply"); return [:] }
        return reply
    }
    private func dict(_ value: Any?) -> [String: Any] { value as? [String: Any] ?? [:] }
    private func errorCode(_ reply: [String: Any]) -> Int? { dict(reply["error"])["code"] as? Int }
    private func errorMessage(_ reply: [String: Any]) -> String { dict(reply["error"])["message"] as? String ?? "" }
    private func tools(_ reply: [String: Any]) -> [[String: Any]] { dict(reply["result"])["tools"] as? [[String: Any]] ?? [] }
    private func relay(against fake: FakeAppServer, launch: @escaping () throws -> Void = { throw RelayError.unavailable }) -> RelayServer {
        let transport = SocketTransport(path: fake.path, launch: launch, launchWindow: 1)
        return RelayServer { try transport.exchange($0, timeout: $1) }
    }
    private func toolNames(_ reply: [String: Any]) -> [String] { tools(reply).map { $0["name"] as? String ?? "?" } }
    private let b37 = ["version": 1, "operations": ["discover", "status", "export"]] as [String: Any]
    private func catalog(_ names: [String]) -> [String: Any] {
        ["version": 1, "tools": names.map { ["name": $0, "description": "d-\($0)", "inputSchema": ["type": "object", "properties": ["id": ["type": "string"]]],
                                             "annotations": ["readOnlyHint": true, "title": $0]] as [String: Any] }]
    }

    func testInitializeNeedsNoApp() {
        let server = RelayServer { _, _ in XCTFail("initialize must not touch the app"); throw RelayError.unavailable }
        let reply = call(server, ["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": [:]])
        XCTAssertEqual(dict(dict(reply["result"])["serverInfo"])["name"] as? String, "Meeting Minutes")
        XCTAssertNil(server.handle(line: rpc(["jsonrpc": "2.0", "method": "notifications/initialized"])))
    }

    // Build 37 shape: discover answers {version, operations} only -> minimal list without schema.
    func testBuild37DiscoverGivesMinimalList() {
        let fake = FakeAppServer { _ in .init(id: "", result: self.json(self.b37)) }; fake.start(); defer { fake.stop() }
        let reply = call(relay(against: fake), ["jsonrpc": "2.0", "id": 2, "method": "tools/list"])
        XCTAssertEqual(toolNames(reply), ["discover", "status", "export"])
        let first = tools(reply).first ?? [:]
        XCTAssertEqual(dict(first["inputSchema"])["type"] as? String, "object")
        XCTAssertEqual(fake.received.map(\.operation), ["discover"])
    }

    // The evolution test: full catalog, then one tool more, same relay process, nothing changed on the plug-in side.
    func testCatalogThenCatalogPlusOne() {
        let fake = FakeAppServer { _ in .init(id: "", result: self.json(self.catalog(["alpha", "beta"]))) }; fake.start(); defer { fake.stop() }
        let relay = relay(against: fake)
        let first = call(relay, ["jsonrpc": "2.0", "id": 3, "method": "tools/list"])
        XCTAssertEqual(toolNames(first), ["alpha", "beta"])
        let firstTool = tools(first).first ?? [:]
        XCTAssertEqual(dict(firstTool["annotations"])["readOnlyHint"] as? Bool, true, "annotations pass through verbatim")
        XCTAssertEqual(firstTool["description"] as? String, "d-alpha")
        fake.handler = { _ in .init(id: "", result: self.json(self.catalog(["alpha", "beta", "gamma"]))) }
        let second = call(relay, ["jsonrpc": "2.0", "id": 4, "method": "tools/list"])
        XCTAssertEqual(toolNames(second), ["alpha", "beta", "gamma"])
    }

    func testToolCallIsForwardedAndErrorsAreFlagged() {
        let fake = FakeAppServer { req in
            req.operation == "status" ? .init(id: "", result: Data(#"{"state":"ok"}"#.utf8))
                                      : .init(id: "", error: .init(code: "disabled", message: "off"))
        }; fake.start(); defer { fake.stop() }
        let relay = relay(against: fake)
        let ok = call(relay, ["jsonrpc": "2.0", "id": 5, "method": "tools/call", "params": ["name": "status", "arguments": ["id": "x1"]]])
        let content = ((dict(ok["result"])["content"] as? [[String: Any]])?.first)?["text"] as? String
        XCTAssertEqual(content, #"{"state":"ok"}"#)
        XCTAssertEqual(dict(ok["result"])["isError"] as? Bool, false)
        XCTAssertEqual(fake.received.last?.operation, "status"); XCTAssertEqual(fake.received.last?.parameters, ["id": "x1"])
        XCTAssertEqual(fake.received.last?.version, 1)
        let bad = call(relay, ["jsonrpc": "2.0", "id": 6, "method": "tools/call", "params": ["name": "export", "arguments": [:]]])
        XCTAssertEqual(dict(bad["result"])["isError"] as? Bool, true)
        // non-string argument values are refused before reaching the app
        let count = fake.received.count
        let refused = call(relay, ["jsonrpc": "2.0", "id": 7, "method": "tools/call", "params": ["name": "status", "arguments": ["id": 3]]])
        XCTAssertEqual(errorCode(refused), -32602)
        XCTAssertEqual(fake.received.count, count)
    }

    func testRefusedAdmissionIsAnErrorNotAHang() {
        let fake = FakeAppServer { _ in .init(id: "", result: Data("{}".utf8)) }; fake.admit = false; fake.start(); defer { fake.stop() }
        let reply = call(relay(against: fake), ["jsonrpc": "2.0", "id": 8, "method": "tools/list"])
        XCTAssertEqual(errorCode(reply), -32000)
        XCTAssertTrue(errorMessage(reply).contains("same macOS user"), errorMessage(reply))
        XCTAssertFalse(errorMessage(reply).contains("turned"), "a refused peer is not the same thing as an off switch")
        XCTAssertTrue(fake.received.isEmpty, "no request is sent to a peer that refused admission")
    }

    // The app says its agent switch is off (error code automation_disabled): a distinct, actionable message.
    func testSwitchOffIsDistinctFromRefusedPeer() {
        let fake = FakeAppServer { _ in .init(id: "", error: .init(code: "automation_disabled", message: "off")) }; fake.start(); defer { fake.stop() }
        let reply = call(relay(against: fake), ["jsonrpc": "2.0", "id": 11, "method": "tools/list"])
        XCTAssertEqual(errorCode(reply), -32000)
        XCTAssertTrue(errorMessage(reply).contains("turned off"), errorMessage(reply))
        XCTAssertFalse(errorMessage(reply).contains("same macOS user"))
    }

    // Cold start: nothing listens -> launch called once -> the app appears -> request served.
    func testColdLaunchThenServed() {
        let fake = FakeAppServer { _ in .init(id: "", result: self.json(self.b37)) }
        var launches = 0
        let relay = relay(against: fake, launch: { launches += 1; Thread.sleep(forTimeInterval: 0.3); fake.start() })
        defer { fake.stop() }
        let reply = call(relay, ["jsonrpc": "2.0", "id": 9, "method": "tools/list"])
        XCTAssertEqual(launches, 1)
        XCTAssertEqual(toolNames(reply), ["discover", "status", "export"])
    }

    func testAppNeverComesUpTimesOut() {
        let fake = FakeAppServer { _ in .init(id: "", result: Data("{}".utf8)) }
        let relay = relay(against: fake, launch: { })
        let t0 = Date()
        let reply = call(relay, ["jsonrpc": "2.0", "id": 10, "method": "tools/list"])
        XCTAssertEqual(errorCode(reply), -32000)
        XCTAssertLessThan(Date().timeIntervalSince(t0), 4)
        fake.stop()
    }

    func testFrameBoundsAndMarkerShape() throws {
        XCTAssertThrowsError(try Frame.encode(Data()))
        XCTAssertThrowsError(try Frame.encode(Data(count: Frame.maximumSize + 1)))
        var decoder = Frame.Decoder()
        XCTAssertThrowsError(try decoder.append(Data([0xFF, 0xFF, 0xFF, 0xFF])))
        let url = URL(fileURLWithPath: "/tmp/mmrelay-marker-\(UUID().uuidString.prefix(6))/a.launch")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let id = UUID().uuidString
        try LaunchMarker.write(fixture: id, to: url)
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        XCTAssertEqual(Set(object.keys), ["at", "fixture", "socketFixture"])
        XCTAssertEqual(object["fixture"] as? String, id)
        XCTAssertThrowsError(try Endpoint.fixtureID("not-a-uuid"))
    }

    func testAppLocatorRequiresOurBundleIdentifier() throws {
        let dir = "/tmp/mmrelay-app-\(UUID().uuidString.prefix(6))"
        defer { try? FileManager.default.removeItem(atPath: dir) }
        for (name, id) in [("Meeting Minutes.app", "ai.ag3ntlab.meetingminutes"), ("Other.app", "com.example.other")] {
            let contents = dir + "/" + name + "/Contents"
            try FileManager.default.createDirectory(atPath: contents, withIntermediateDirectories: true)
            try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": id], format: .xml, options: 0).write(to: URL(fileURLWithPath: contents + "/Info.plist"))
        }
        XCTAssertEqual(AppLocator.find(environment: ["MM_APP_DIRS": dir], home: "/nonexistent")?.lastPathComponent, "Meeting Minutes.app")
        XCTAssertNotEqual(AppLocator.find(environment: ["MM_APP_PATH": dir + "/Other.app", "MM_APP_DIRS": "/nonexistent"], home: "/nonexistent")?.lastPathComponent, "Other.app")
    }
}

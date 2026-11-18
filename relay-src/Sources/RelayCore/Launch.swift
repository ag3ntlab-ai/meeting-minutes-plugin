import AppKit
import Foundation

/// Where the app listens and where the "started by automation" marker goes (group container shared with the app).
public enum Endpoint {
    public static let group = "2Q6VY4YW5F.ai.ag3ntlab.mm"
    public static let bundleIdentifier = "ai.ag3ntlab.meetingminutes"

    public static func fixtureID(_ candidate: String?) throws -> String? {
        guard let candidate else { return nil }
        guard let uuid = UUID(uuidString: candidate) else { throw RelayError.invalidFrame }
        return uuid.uuidString
    }
    static func root() throws -> URL {
        guard let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else { throw RelayError.unavailable }
        return root
    }
    /// A UUID fixture selects a disposable app instance (QA seam shared with the app's own helper).
    public static func socketURL(fixture: String?) throws -> URL {
        guard let id = try fixtureID(fixture) else { return try root().appendingPathComponent("a.sock") }
        return try root().appendingPathComponent("qa-" + String(id.prefix(8)), isDirectory: true).appendingPathComponent("a.sock")
    }
    public static func markerURL(fixture: String?) throws -> URL {
        try socketURL(fixture: fixture).deletingLastPathComponent().appendingPathComponent("a.launch")
    }
}

/// Same JSON the app reads and deletes at start (`at` in epoch seconds, valid 20 s).
public struct LaunchMarker: Codable, Equatable {
    public var at: Double
    public var fixture: String?
    public var socketFixture: String?
    public static func write(fixture: String?, to url: URL, now: Date = Date()) throws {
        let marker = LaunchMarker(at: now.timeIntervalSince1970, fixture: fixture, socketFixture: fixture)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(marker).write(to: url, options: .atomic)
        chmod(url.path, S_IRUSR | S_IWUSR)
    }
}

public enum AppLocator {
    /// First installed Meeting Minutes app: explicit path, then standard folders.
    public static func find(environment: [String: String] = ProcessInfo.processInfo.environment,
                            home: String = NSHomeDirectory()) -> URL? {
        var candidates: [URL] = []
        if let explicit = environment["MM_APP_PATH"], !explicit.isEmpty { candidates.append(URL(fileURLWithPath: explicit)) }
        let dirs = (environment["MM_APP_DIRS"] ?? "/Applications:\(home)/Applications").split(separator: ":").map(String.init)
        candidates += dirs.map { URL(fileURLWithPath: $0).appendingPathComponent("Meeting Minutes.app") }
        // yagni: no Launch Services lookup by bundle identifier; an app installed elsewhere sets MM_APP_PATH.
        return candidates.first(where: isMeetingMinutes)
    }
    /// Read the plist itself and require our identifier: the relay launches only our own app.
    static func isMeetingMinutes(_ app: URL) -> Bool {
        guard app.pathExtension == "app" else { return false }
        let plist = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        return plist?["CFBundleIdentifier"] as? String == Endpoint.bundleIdentifier
    }
}

public enum AppLauncher {
    /// Write the marker, then ask Launch Services to start the app without activating it.
    public static func launch(app: URL, fixture: String?) throws {
        let markerURL = try Endpoint.markerURL(fixture: fixture)
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        if fixture != nil { config.createsNewApplicationInstance = true }
        try LaunchMarker.write(fixture: fixture, to: markerURL)
        var finished = false
        var failure: Error?
        NSWorkspace.shared.openApplication(at: app, configuration: config) { _, error in failure = error; finished = true }
        let deadline = Date().addingTimeInterval(3)
        while !finished, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        // A marker that no launch consumed must not turn a later manual start into a silent one.
        if let failure { try? FileManager.default.removeItem(at: markerURL); throw failure }
    }
}

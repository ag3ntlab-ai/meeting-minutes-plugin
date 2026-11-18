// swift-tools-version:6.2
import PackageDescription

// Stdio-to-socket relay for Meeting Minutes. System frameworks only: no package dependency.
let package = Package(name: "mm-mcp-relay", platforms: [.macOS("26")], products: [
    .executable(name: "mm-mcp-relay", targets: ["mm-mcp-relay"])
], targets: [
    .target(name: "RelayCore", swiftSettings: [.swiftLanguageMode(.v5)]),
    .executableTarget(name: "mm-mcp-relay", dependencies: ["RelayCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
    .testTarget(name: "RelayCoreTests", dependencies: ["RelayCore"], swiftSettings: [.swiftLanguageMode(.v5)])
])

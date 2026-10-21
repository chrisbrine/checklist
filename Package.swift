// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Checklist", platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ChecklistApp", targets: ["ChecklistApp"]),
        .executable(name: "ChecklistService", targets: ["ChecklistService"]),
        .executable(name: "checklist", targets: ["ChecklistCLI"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.11.1"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", exact: "0.12.1")
    ],
    targets: [
        .target(name: "ChecklistCore", dependencies: [.product(name: "GRDB", package: "GRDB.swift")]),
        .target(name: "ChecklistIPC"),
        .target(name: "ChecklistBridges", dependencies: ["ChecklistCore", "ChecklistIPC"]),
        .target(name: "ChecklistMCPServer", dependencies: ["ChecklistIPC", "ChecklistBridges", .product(name: "MCP", package: "swift-sdk")]),
        .executableTarget(name: "ChecklistService", dependencies: ["ChecklistCore", "ChecklistIPC", "ChecklistBridges"]),
        .executableTarget(name: "ChecklistCLI", dependencies: ["ChecklistIPC", "ChecklistBridges", "ChecklistMCPServer", .product(name: "MCP", package: "swift-sdk")]),
        .executableTarget(name: "ChecklistApp", dependencies: ["ChecklistIPC", "ChecklistCore"]),
        .target(name: "StorageReleasedCoreFixture", dependencies: [.product(name: "GRDB", package: "GRDB.swift")], path: "Tests/StorageCrashProbe/ReleasedCore"),
        .executableTarget(name: "StorageCrashProbe", dependencies: ["ChecklistCore", "StorageReleasedCoreFixture", .product(name: "GRDB", package: "GRDB.swift")], path: "Tests/StorageCrashProbe", exclude: ["ReleasedCore"]),
        .testTarget(name: "ChecklistCoreTests", dependencies: ["ChecklistCore", "ChecklistBridges", .product(name: "GRDB", package: "GRDB.swift")]),
        .testTarget(name: "ChecklistAppTests", dependencies: ["ChecklistApp", "ChecklistCore", "ChecklistIPC"]),
        .testTarget(name: "ChecklistIPCTests", dependencies: ["ChecklistIPC", "ChecklistCore", .product(name: "GRDB", package: "GRDB.swift")]),
        .testTarget(name: "ChecklistBridgesTests", dependencies: ["ChecklistBridges", "ChecklistIPC"]),
        .testTarget(name: "ChecklistMCPServerTests", dependencies: ["ChecklistMCPServer", "ChecklistBridges", "ChecklistIPC", .product(name: "MCP", package: "swift-sdk")])
    ], swiftLanguageModes: [.v5]
)

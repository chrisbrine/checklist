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
        .target(name: "ChecklistProviders"),
        .target(name: "ChecklistCore", dependencies: ["ChecklistProviders", .product(name: "GRDB", package: "GRDB.swift")]),
        .target(name: "ChecklistIPC"),
        .target(name: "ChecklistBridges", dependencies: ["ChecklistCore", "ChecklistIPC", "ChecklistProviders"]),
        .target(name: "ChecklistMCPServer", dependencies: ["ChecklistIPC", "ChecklistBridges", .product(name: "MCP", package: "swift-sdk")]),
        .executableTarget(name: "ChecklistService", dependencies: ["ChecklistCore", "ChecklistIPC", "ChecklistBridges", "ChecklistProviders"]),
        .executableTarget(name: "ChecklistCLI", dependencies: ["ChecklistIPC", "ChecklistBridges", "ChecklistMCPServer", .product(name: "MCP", package: "swift-sdk")]),
        .executableTarget(name: "ChecklistApp", dependencies: ["ChecklistIPC", "ChecklistCore", "ChecklistProviders"]),
        // Build-only group: link all shipping executables in one SwiftPM pass.
        .target(name: "ChecklistProducts", dependencies: ["ChecklistApp", "ChecklistService", "ChecklistCLI"]),
        .target(name: "StorageReleasedCoreFixture", dependencies: [.product(name: "GRDB", package: "GRDB.swift")], path: "Tests/StorageCrashProbe/ReleasedCore"),
        .executableTarget(name: "StorageCrashProbe", dependencies: ["ChecklistCore", "StorageReleasedCoreFixture", .product(name: "GRDB", package: "GRDB.swift")], path: "Tests/StorageCrashProbe", exclude: ["ReleasedCore"]),
        .executableTarget(name: "ChecklistCLIInputProbe", dependencies: ["ChecklistIPC"], path: "Tests/ChecklistCLIInputProbe"),
        .testTarget(name: "ChecklistProvidersTests", dependencies: ["ChecklistProviders"]),
        .testTarget(name: "ChecklistCoreTests", dependencies: ["ChecklistCore", "ChecklistBridges", "ChecklistProviders", .product(name: "GRDB", package: "GRDB.swift")]),
        .testTarget(name: "ChecklistAppTests", dependencies: ["ChecklistApp", "ChecklistCore", "ChecklistIPC", "ChecklistProviders"]),
        .testTarget(name: "ChecklistCLITests", dependencies: ["ChecklistCLI", .product(name: "MCP", package: "swift-sdk")]),
        .testTarget(name: "ChecklistIPCTests", dependencies: ["ChecklistIPC", "ChecklistCore", .product(name: "GRDB", package: "GRDB.swift")]),
        .testTarget(name: "ChecklistBridgesTests", dependencies: ["ChecklistBridges", "ChecklistIPC", "ChecklistProviders"]),
        .testTarget(name: "ChecklistMCPServerTests", dependencies: ["ChecklistMCPServer", "ChecklistBridges", "ChecklistIPC", .product(name: "MCP", package: "swift-sdk")])
    ], swiftLanguageModes: [.v5]
)

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
        .package(path: "Packages/ChecklistShared"),
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.11.1"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", exact: "0.12.1")
    ],
    targets: [
        .target(name: "ChecklistProviders"),
        .target(name: "ChecklistFileAccess"),
        .target(name: "ChecklistCore", dependencies: [
            .product(name: "ChecklistDomain", package: "ChecklistShared"),
            .product(name: "ChecklistContracts", package: "ChecklistShared"),
            .product(name: "ChecklistApplication", package: "ChecklistShared"),
            "ChecklistProviders", "ChecklistFileAccess", .product(name: "GRDB", package: "GRDB.swift")
        ]),
        .target(name: "ChecklistIPC", dependencies: [.product(name: "ChecklistContracts", package: "ChecklistShared")]),
        .target(name: "ChecklistBridges", dependencies: ["ChecklistCore", "ChecklistIPC", "ChecklistProviders"]),
        .target(name: "ChecklistMCPServer", dependencies: ["ChecklistIPC", "ChecklistBridges", .product(name: "MCP", package: "swift-sdk")]),
        .executableTarget(name: "ChecklistService", dependencies: ["ChecklistCore", "ChecklistIPC", "ChecklistBridges", "ChecklistProviders"]),
        .executableTarget(name: "ChecklistCLI", dependencies: ["ChecklistProviders", "ChecklistIPC", "ChecklistBridges", "ChecklistMCPServer", .product(name: "MCP", package: "swift-sdk")]),
        .executableTarget(name: "ChecklistApp", dependencies: [
            .product(name: "ChecklistDomain", package: "ChecklistShared"),
            "ChecklistIPC", "ChecklistCore", "ChecklistProviders"
        ]),
        // Build-only group: link all shipping executables in one SwiftPM pass.
        .target(name: "ChecklistProducts", dependencies: ["ChecklistApp", "ChecklistService", "ChecklistCLI"]),
        .target(name: "StorageReleasedCoreFixture", dependencies: [.product(name: "GRDB", package: "GRDB.swift")], path: "Tests/StorageCrashProbe/ReleasedCore"),
        .executableTarget(name: "StorageCrashProbe", dependencies: ["ChecklistCore", "StorageReleasedCoreFixture", .product(name: "GRDB", package: "GRDB.swift")], path: "Tests/StorageCrashProbe", exclude: ["ReleasedCore"]),
        .executableTarget(name: "ChecklistCLIInputProbe", dependencies: ["ChecklistIPC"], path: "Tests/ChecklistCLIInputProbe"),
        .testTarget(name: "ChecklistServiceTests", dependencies: ["ChecklistService", "ChecklistCore", "ChecklistIPC"]),
        .testTarget(name: "DesktopAlertsTests", dependencies: ["ChecklistApp"]),
        .testTarget(name: "RequestAnswerCompletionTests", dependencies: ["ChecklistApp"]),
        .testTarget(name: "RequestRowPresentationTests", dependencies: ["ChecklistApp"]),
        .testTarget(name: "TestResultEvidenceProjectionTests", dependencies: ["ChecklistApp"]),
        .testTarget(name: "TestResultParserTests", dependencies: ["ChecklistApp"]),
        .testTarget(name: "ChecklistProvidersTests", dependencies: ["ChecklistProviders"]),
        .target(name: "ChecklistTestSupport", dependencies: ["ChecklistCore", "ChecklistProviders", .product(name: "GRDB", package: "GRDB.swift")], path: "Tests/ChecklistTestSupport"),
        .testTarget(name: "ChecklistCoreTests", dependencies: ["ChecklistTestSupport", "ChecklistCore", "ChecklistBridges", "ChecklistProviders", .product(name: "GRDB", package: "GRDB.swift")]),
        .testTarget(name: "ChecklistAppTests", dependencies: ["ChecklistTestSupport", "ChecklistApp", "ChecklistCore", "ChecklistIPC", "ChecklistProviders"]),
        .testTarget(name: "ChecklistCLITests", dependencies: ["ChecklistCLI", .product(name: "MCP", package: "swift-sdk")]),
        .testTarget(name: "ChecklistIPCTests", dependencies: ["ChecklistTestSupport", "ChecklistIPC", "ChecklistCore", .product(name: "GRDB", package: "GRDB.swift")]),
        .testTarget(name: "ChecklistBridgesTests", dependencies: ["ChecklistBridges", "ChecklistIPC", "ChecklistProviders"]),
        .testTarget(name: "ChecklistMCPServerTests", dependencies: ["ChecklistMCPServer", "ChecklistBridges", "ChecklistIPC", .product(name: "MCP", package: "swift-sdk")])
    ], swiftLanguageModes: [.v5]
)

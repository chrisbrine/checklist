// swift-tools-version: 6.0
import PackageDescription

// Portable values and command planning only. Native effects belong to the root adapters.
let package = Package(
    name: "ChecklistShared",
    products: [
        .library(name: "ChecklistDomain", targets: ["ChecklistDomain"]),
        .library(name: "ChecklistContracts", targets: ["ChecklistContracts"]),
        .library(name: "ChecklistApplication", targets: ["ChecklistApplication"])
    ],
    targets: [
        .target(name: "ChecklistDomain", swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]),
        .target(name: "ChecklistContracts", dependencies: ["ChecklistDomain"],
                swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]),
        .target(name: "ChecklistApplication", dependencies: ["ChecklistDomain", "ChecklistContracts"],
                swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]),
        .testTarget(name: "ChecklistSharedTests", dependencies: ["ChecklistDomain", "ChecklistContracts", "ChecklistApplication"])
    ],
    swiftLanguageModes: [.v6]
)

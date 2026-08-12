// swift-tools-version: 6.0
import PackageDescription

// A SwiftPM view of the modules that do not need Xcode.
//
// The Xcode project (`Project.swift`, via Tuist) remains the source of truth for the app: SwiftUI,
// the app bundle, entitlements and UI tests all need a Mac. But everything below — the domain rules,
// the mock engine, persistence, the control plane, spec import, and the CLI — is plain Swift, and
// Vapor's native home is Linux. Building them here means the bulk of the logic is testable on a free
// Linux runner instead of an expensive macOS one.
//
// Both manifests declare these modules from the *same* directories, so they cannot drift in what
// they compile — only in how targets are declared. Their two lockfiles can and did drift, which is
// why CI compares them before building.
let package = Package(
    name: "Mimic",
    // The same floor `Project.swift` sets as MACOSX_DEPLOYMENT_TARGET, and the same one
    // CONTRIBUTING.md, the README badge and the installer's `<os-version min>` all state. This said
    // `.v15` — eleven majors below every other artefact — and nothing caught it because no CI job
    // builds this manifest on a Mac, and Linux ignores `platforms:` entirely. A contributor running
    // `swift build` locally compiled the portable modules against a macOS 15 availability floor while
    // Xcode used 26, so an API introduced in between built in one and errored in the other.
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "mimic", targets: ["mimic"]),
        .library(name: "MimicDomain", targets: ["Domain"]),
    ],
    dependencies: [
        .package(url: "https://github.com/vapor/vapor", from: "4.76.0"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.10.0"),
        .package(url: "https://github.com/mattpolzin/OpenAPIKit.git", from: "3.3.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        .target(name: "Domain", path: "Sources/Domain"),
        .testTarget(name: "DomainTests", dependencies: ["Domain"], path: "Tests/DomainTests"),

        .target(
            name: "Persistence",
            dependencies: ["Domain", .product(name: "GRDB", package: "GRDB.swift")],
            path: "Sources/Persistence"
        ),
        .testTarget(
            name: "PersistenceTests",
            dependencies: ["Persistence", "Domain"],
            path: "Tests/PersistenceTests"
        ),

        .target(
            name: "MockServerEngine",
            dependencies: ["Domain", .product(name: "Vapor", package: "vapor")],
            path: "Sources/MockServerEngine"
        ),
        .testTarget(
            name: "MockServerEngineTests",
            dependencies: ["MockServerEngine", "Domain"],
            path: "Tests/MockServerEngineTests",
            exclude: ["MockServerEngineTests.entitlements"]
        ),

        .target(
            name: "SpecImport",
            dependencies: ["Domain", .product(name: "OpenAPIKit30", package: "OpenAPIKit")],
            path: "Sources/SpecImport"
        ),
        .testTarget(
            name: "SpecImportTests",
            dependencies: ["SpecImport", "Domain"],
            path: "Tests/SpecImportTests"
        ),

        .target(
            name: "ControlPlane",
            dependencies: [
                "Domain",
                "Persistence",
                "MockServerEngine",
                .product(name: "Vapor", package: "vapor"),
            ],
            path: "Sources/ControlPlane"
        ),
        .testTarget(
            name: "ControlPlaneTests",
            dependencies: ["ControlPlane", "Persistence", "MockServerEngine", "Domain"],
            path: "Tests/ControlPlaneTests",
            exclude: ["ControlPlaneTests.entitlements"]
        ),

        .target(
            name: "MimicCLICore",
            dependencies: ["Domain", .product(name: "ArgumentParser", package: "swift-argument-parser")],
            path: "Sources/MimicCLICore"
        ),
        .testTarget(
            name: "MimicCLICoreTests",
            dependencies: ["MimicCLICore", "Domain"],
            path: "Tests/MimicCLICoreTests"
        ),

        .executableTarget(name: "mimic", dependencies: ["MimicCLICore"], path: "Tools/mimic"),
    ]
)

// swift-tools-version: 6.2
import PackageDescription

// Portable modules use the same sources, Swift 6 language mode and upcoming features as Tuist.
// Swift 6 already enables the other features grouped under approachable concurrency in Xcode.
let sharedSwiftSettings: [SwiftSetting] = [
    .enableUpcomingFeature("MemberImportVisibility"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
]

let package = Package(
    name: "Mimic",
    // check_compiler_settings.py enforces this floor and every portable target's Swift settings.
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "mimic", targets: ["mimic"]),
        .library(name: "MimicDomain", targets: ["Domain"]),
    ],
    dependencies: [
        .package(url: "https://github.com/vapor/vapor", from: "4.76.0"),
        .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.33.1"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.10.0"),
        .package(url: "https://github.com/mattpolzin/OpenAPIKit.git", from: "3.3.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        .target(name: "Domain", path: "Sources/Domain", swiftSettings: sharedSwiftSettings),
        .testTarget(name: "DomainTests", dependencies: ["Domain"], path: "Tests/DomainTests",
                    swiftSettings: sharedSwiftSettings),

        .target(
            name: "Persistence",
            dependencies: ["Domain", .product(name: "GRDB", package: "GRDB.swift")],
            path: "Sources/Persistence",
            swiftSettings: sharedSwiftSettings
        ),
        .testTarget(
            name: "PersistenceTests",
            dependencies: ["Persistence", "Domain"],
            path: "Tests/PersistenceTests",
            swiftSettings: sharedSwiftSettings
        ),

        .target(
            name: "MockServerEngine",
            dependencies: ["Domain", .product(name: "Vapor", package: "vapor"), .product(name: "AsyncHTTPClient", package: "async-http-client")],
            path: "Sources/MockServerEngine",
            swiftSettings: sharedSwiftSettings
        ),
        .testTarget(
            name: "MockServerEngineTests",
            dependencies: ["MockServerEngine", "Domain"],
            path: "Tests/MockServerEngineTests",
            exclude: ["MockServerEngineTests.entitlements"],
            swiftSettings: sharedSwiftSettings
        ),

        .target(
            name: "SpecImport",
            dependencies: ["Domain", .product(name: "OpenAPIKit30", package: "OpenAPIKit")],
            path: "Sources/SpecImport",
            swiftSettings: sharedSwiftSettings
        ),
        .testTarget(
            name: "SpecImportTests",
            dependencies: ["SpecImport", "Domain"],
            path: "Tests/SpecImportTests",
            swiftSettings: sharedSwiftSettings
        ),

        .target(
            name: "ControlPlane",
            // The app supplies the sole host; this module owns only its HTTP adapter and discovery.
            dependencies: [
                "Domain",
                .product(name: "Vapor", package: "vapor"),
            ],
            path: "Sources/ControlPlane",
            swiftSettings: sharedSwiftSettings
        ),
        .testTarget(
            name: "ControlPlaneTests",
            dependencies: ["ControlPlane", "Domain"],
            path: "Tests/ControlPlaneTests",
            exclude: ["ControlPlaneTests.entitlements"],
            swiftSettings: sharedSwiftSettings
        ),

        .target(
            name: "MimicCLICore",
            dependencies: ["Domain", .product(name: "ArgumentParser", package: "swift-argument-parser")],
            path: "Sources/MimicCLICore",
            swiftSettings: sharedSwiftSettings
        ),
        .testTarget(
            name: "MimicCLICoreTests",
            dependencies: ["MimicCLICore", "Domain"],
            path: "Tests/MimicCLICoreTests",
            swiftSettings: sharedSwiftSettings
        ),

        .executableTarget(name: "mimic", dependencies: ["MimicCLICore"], path: "Tools/mimic",
                          swiftSettings: sharedSwiftSettings),
    ],
    swiftLanguageModes: [.v6]
)

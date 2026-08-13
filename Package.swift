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
//
// They drift in a second way, and this one is not fixed: how the compiler is configured.
// `Project.swift` sets four Swift settings in its shared base, and no target below sets
// `swiftSettings:` at all — so this manifest is the *looser* of the two, and a Linux run can go
// green on code Xcode rejects. The case that bites is an implicit transitive import, because
// member-import visibility is enforced there and not here.
//
// Tightening it is not an edit to make blind. Turning that diagnostic on lights up every portable
// module at once, and CI is the only place a Linux compiler runs, so the resulting errors would have
// to be fixed against a red pipeline. Until somebody does that with a toolchain to hand, CI
// *reports* the gap rather than closing it: the "Compiler settings" step in
// `.github/workflows/ci.yml` prints every Swift setting one manifest asks for and the other does
// not, as a warning. That step reads this file and drops whole-line comments before it looks, so
// naming a feature in a note here cannot make it believe one is declared.
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
            // Domain and Vapor only, since the owner's decision to delete `MimicControlService` and
            // `MimicDaemon` — the two files that were the module's whole use of Persistence and
            // MockServerEngine. `check_module_edges.py` forbids those edges now, so putting one back
            // is a decision to be argued, not an accident.
            dependencies: [
                "Domain",
                .product(name: "Vapor", package: "vapor"),
            ],
            path: "Sources/ControlPlane"
        ),
        .testTarget(
            name: "ControlPlaneTests",
            dependencies: ["ControlPlane", "Domain"],
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

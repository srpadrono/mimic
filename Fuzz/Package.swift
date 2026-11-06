// swift-tools-version: 6.2
import PackageDescription

// libFuzzer targets for the code that reads files and requests Mimic did not write: HAR captures,
// OpenAPI and Swagger specs, project exports and control API payloads. A separate package, so the
// `-sanitize=fuzzer` instrumentation applies only to these executables and what they import.
//
// Linux only: Apple's toolchains ship no libFuzzer runtime. Build and run as `.github/workflows/fuzz.yml`
// does; Fuzz/README.md has the commands.

let package = Package(
    name: "MimicFuzz",
    platforms: [.macOS("26.0")],
    dependencies: [.package(path: "..")],
    targets: [
        .target(name: "FuzzSupport", path: "Sources/FuzzSupport"),
        .executableTarget(
            name: "FuzzHAR",
            dependencies: ["FuzzSupport", .product(name: "MimicSpecImport", package: "mimic")],
            path: "Sources/FuzzHAR"
        ),
        .executableTarget(
            name: "FuzzOpenAPI",
            dependencies: ["FuzzSupport", .product(name: "MimicSpecImport", package: "mimic")],
            path: "Sources/FuzzOpenAPI"
        ),
        .executableTarget(
            name: "FuzzProjectDocument",
            dependencies: ["FuzzSupport", .product(name: "MimicDomain", package: "mimic")],
            path: "Sources/FuzzProjectDocument"
        ),
    ]
)

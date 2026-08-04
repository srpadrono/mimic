// swift-tools-version: 6.0
import PackageDescription

#if TUIST
import ProjectDescription

let packageSettings = PackageSettings(
    productTypes: [
        "Vapor": .framework,
        "NIOEmbedded": .framework,
        "NIOCore": .framework,
        "NIOPosix": .framework,
        "NIOHTTP1": .framework,
        "DequeModule": .framework,
        "Atomics": .framework,
        "_AtomicsShims": .framework,
        "GRDB": .framework,
        "LanguageSupport": .framework,
        "CodeEditorView": .framework,
        "Rearrange": .framework,
        // Static: the `mimic` command line tool is a bare executable with no bundle to embed a
        // dynamic framework in and no @rpath to resolve one through, so its dependencies must link
        // statically. This is also why the CLI depends on Domain only — never on Vapor or GRDB.
        "ArgumentParser": .staticFramework,
    ]
)
#endif

let package = Package(
    name: "MimicDependencies",
    platforms: [.macOS(.v15)],
    dependencies: [
        // Vapor declared via SPM URL (not Tuist external) — workaround for vapor/vapor #3369
        // SPM's linker handles ManagedAtomic correctly; Tuist's does not
        .package(url: "https://github.com/vapor/vapor", from: "4.76.0"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.10.0"),
        .package(url: "https://github.com/mchakravarty/CodeEditorView.git", exact: "0.15.4"),
        .package(url: "https://github.com/mattpolzin/OpenAPIKit.git", from: "3.3.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: []
)

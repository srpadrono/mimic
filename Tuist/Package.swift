// swift-tools-version: 6.0
import PackageDescription

#if TUIST
import ProjectDescription

// Tuist 4.209 emits swift-collections' per-target language mode both as SWIFT_VERSION and
// as an extra -swift-version flag. Keep _RopeModule in its upstream Swift 5 mode, with the
// pinned package's feature/availability flags intact, but express that mode only once.
let ropeAvailability: [(String, String)] = [
    ("5.0", "macOS 10.14.4, iOS 12.2, watchOS 5.2, tvOS 12.2"),
    ("5.1", "macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0"),
    ("5.6", "macOS 12.3, iOS 15.4, watchOS 8.5, tvOS 15.4"),
    ("5.7", "macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0"),
    ("5.8", "macOS 13.3, iOS 16.4, watchOS 9.4, tvOS 16.4"),
    ("5.9", "macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0"),
    ("5.10", "macOS 14.4, iOS 17.4, watchOS 10.4, tvOS 17.4, visionOS 1.1"),
    ("6.0", "macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0"),
    ("6.1", "macOS 15.4, iOS 18.4, watchOS 11.4, tvOS 18.4, visionOS 2.4"),
    ("6.2", "macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0"),
    ("6.3", "macOS 26.4, iOS 26.4, watchOS 26.4, tvOS 26.4, visionOS 26.4"),
]
let ropeFlags = ["$(inherited)", "-enable-upcoming-feature MemberImportVisibility"]
    + ropeAvailability.map { "-enable-experimental-feature \"AvailabilityMacro=SwiftStdlib \($0.0): \($0.1)\"" }
    + ["BuiltinModule", "Lifetimes", "InoutLifetimeDependence", "SuppressedAssociatedTypes",
       "AddressableParameters", "AddressableTypes"].map { "-enable-experimental-feature \($0)" }

// Keep the dependency graph on one explicit floor. Xcode's recommended-target macro is tied to
// the Xcode version doing the build (CI's Xcode 26 resolves it below the Regex APIs used by
// CodeEditorView, while Xcode 27 recommends 14), so it is not a reproducible manifest value.
// These pinned dependencies support macOS 14 or earlier; Mimic itself requires macOS 26.
let dependencyTargets = [
    "Algorithms", "ArgumentParser", "ArgumentParserToolInfo", "AsyncHTTPClient", "AsyncKit", "Atomics",
    "BitCollections", "CAsyncHTTPClient", "CCryptoBoringSSL", "CCryptoBoringSSLShims", "CNIOAtomics",
    "CNIOBoringSSL", "CNIOBoringSSLShims", "CNIODarwin", "CNIOExtrasZlib", "CNIOFreeBSD", "CNIOLLHTTP", "CNIOLinux",
    "CNIOOpenBSD", "CNIOPosix", "CNIOSHA1", "CNIOWASI", "CNIOWindows", "CSystem", "CVaporBcrypt",
    "CodeEditorView", "Collections", "Configuration", "ConsoleKit", "ConsoleKitCommands",
    "ConsoleKitTerminal", "ContainersPreview", "CoreMetrics", "Crypto", "CryptoBoringWrapper",
    "CryptoExtras", "DequeModule", "GRDB", "GRDBSQLite", "HashTreeCollections", "HeapModule",
    "Instrumentation", "InternalCollectionsUtilities", "LanguageSupport", "Logging", "Metrics",
    "MultipartKit", "NIO", "NIOConcurrencyHelpers", "NIOCore", "NIOEmbedded", "NIOExtras",
    "NIOFileSystem", "NIOFoundationCompat", "NIOFoundationEssentialsCompat", "NIOHPACK", "NIOHTTP1", "NIOHTTP2", "NIOHTTPCompression",
    "NIOPosix", "NIOSOCKS", "NIOSSL", "NIOTLS", "NIOTransportServices", "NIOWebSocket", "OpenAPIKit30",
    "OpenAPIKitCore", "OrderedCollections", "RealModule", "Rearrange", "RoutingKit", "ServiceContextModule",
    "SwiftASN1", "SystemPackage", "Tracing", "Vapor", "WebSocketKit", "X509", "_AtomicsShims",
    "_CertificateInternals", "_CryptoExtras", "_NIOBase64", "_NIODataStructures", "_NIOFileSystem",
    "_NIOFileSystemFoundationCompat", "_NumericsShims", "_RopeModule",
]
let dependencySettings: [String: Settings] = Dictionary(uniqueKeysWithValues: dependencyTargets.map { name in
    var settings: SettingsDictionary = [
        "MACOSX_DEPLOYMENT_TARGET": "14.0",
    ]
    if name == "_RopeModule" {
        settings["SWIFT_VERSION"] = "5"
        // A string replaces the translated flags; an array would append to them.
        settings["OTHER_SWIFT_FLAGS"] = .string(ropeFlags.joined(separator: " "))
    }
    if name == "Vapor" {
        // Vapor links the static BoringSSL objects transitively. At the recommended macOS
        // floor their C++ standard-library calls require an explicit runtime link.
        settings["OTHER_LDFLAGS"] = .array(["$(inherited)", "-lc++"])
    }
    return (name, .settings(base: settings))
})

let packageSettings = PackageSettings(
    productTypes: [
        "Vapor": .framework,
        // Shared by Vapor and the streaming forwarder. Dynamic products keep a single runtime
        // copy of the client, TLS, connection pools, and their transitive type metadata.
        "AsyncHTTPClient": .framework,
        "Algorithms": .framework,
        "NIOFoundationCompat": .framework,
        "NIOHTTP2": .framework,
        "NIOHTTPCompression": .framework,
        "NIOSSL": .framework,
        "NIOTLS": .framework,
        "Logging": .framework,
        "Instrumentation": .framework,
        "Tracing": .framework,
        "ServiceContextModule": .framework,
        "SystemPackage": .framework,
        "RealModule": .framework,

        "NIOTransportServices": .framework,
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
    ],
    baseSettings: .settings(base: [
        "ENABLE_MODULE_VERIFIER": "YES",
        "MODULE_VERIFIER_KIND": "builtin",
        "MODULE_VERIFIER_SUPPORTED_LANGUAGES": "objective-c objective-c++",
        "MODULE_VERIFIER_SUPPORTED_LANGUAGE_STANDARDS": "gnu11 gnu++14",
        "ENABLE_USER_SCRIPT_SANDBOXING": "YES",
        "ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS": "YES",
        "STRING_CATALOG_GENERATE_SYMBOLS": "YES",
    ]),
    targetSettings: dependencySettings
)
#endif

let package = Package(
    name: "MimicDependencies",
    // Matches `Project.swift`'s MACOSX_DEPLOYMENT_TARGET and `Package.swift`'s floor.
    platforms: [.macOS("26.0")],
    dependencies: [
        // Vapor declared via SPM URL (not Tuist external) — workaround for vapor/vapor #3369
        // SPM's linker handles ManagedAtomic correctly; Tuist's does not
        .package(url: "https://github.com/vapor/vapor", from: "4.76.0"),
        .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.33.1"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.10.0"),
        .package(url: "https://github.com/mchakravarty/CodeEditorView.git", exact: "0.15.4"),
        .package(url: "https://github.com/mattpolzin/OpenAPIKit.git", from: "3.3.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: []
)

// swift-tools-version: 5.10
// Acme Store: the demo client for "Close the loop". A small Mac shop that talks to three backends
// (Auth, Catalog, Payments), so a Mimic project with three named servers can stand in for all of
// them. It is not part of the Mimic build: `swift run AcmeStore` from this folder.
import PackageDescription

let package = Package(
    name: "AcmeStore",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "AcmeStore", path: "Sources/AcmeStore")
    ]
)

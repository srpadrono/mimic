import ProjectDescription

let sharedSettings: Settings = .settings(
    base: [
        "SWIFT_VERSION": "6.2",
        "SWIFT_DEFAULT_ACTOR_ISOLATION": "MainActor",
        "SWIFT_APPROACHABLE_CONCURRENCY": "YES",
        "SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY": "YES",
        "ENABLE_HARDENED_RUNTIME": "YES",
        "MACOSX_DEPLOYMENT_TARGET": "26.0",
        "DEVELOPMENT_TEAM": "KW6369JJL9",
        // Surfaced by `mimic state` as `appVersion`, so a caller can tell which build it is driving.
        "MARKETING_VERSION": "0.9.3",
        "CURRENT_PROJECT_VERSION": "1",
    ],
    configurations: [
        .debug(name: "Debug"),
        .release(name: "Release"),
    ]
)

let project = Project(
    name: "Mimic",
    settings: sharedSettings,
    targets: [
        // Domain — hub, zero deps on other Mimic modules (D-01)
        // SWIFT_DEFAULT_ACTOR_ISOLATION is overridden to "none" — Domain is a pure value-type
        // library used from any isolation context; MainActor isolation on struct inits would
        // prevent other nonisolated modules from constructing Domain types.
        .target(
            name: "Domain",
            destinations: [.mac],
            product: .staticFramework,
            bundleId: "devxa.Mimic.Domain",
            buildableFolders: ["Sources/Domain"],
            dependencies: [],
            settings: .settings(base: ["SWIFT_DEFAULT_ACTOR_ISOLATION": "none"])
        ),
        .target(
            name: "DomainTests",
            destinations: [.mac],
            product: .unitTests,
            bundleId: "devxa.Mimic.DomainTests",
            buildableFolders: ["Tests/DomainTests"],
            dependencies: [.target(name: "Domain")],
            settings: .settings(base: ["SWIFT_DEFAULT_ACTOR_ISOLATION": "none"])
        ),

        // MockServerEngine — depends on Domain + Vapor (Phase 2)
        // SWIFT_DEFAULT_ACTOR_ISOLATION overridden to "none" — engine lives on NIO threads;
        // any MainActor isolation would deadlock or fail to compile with Vapor's concurrency model.
        .target(
            name: "MockServerEngine",
            destinations: [.mac],
            product: .staticFramework,
            bundleId: "devxa.Mimic.MockServerEngine",
            buildableFolders: ["Sources/MockServerEngine"],
            dependencies: [
                .target(name: "Domain"),
                .external(name: "Vapor"),
            ],
            settings: .settings(base: ["SWIFT_DEFAULT_ACTOR_ISOLATION": "none"])
        ),
        .target(
            name: "MockServerEngineTests",
            destinations: [.mac],
            product: .unitTests,
            bundleId: "devxa.Mimic.MockServerEngineTests",
            buildableFolders: ["Tests/MockServerEngineTests"],
            entitlements: .file(path: "Tests/MockServerEngineTests/MockServerEngineTests.entitlements"),
            dependencies: [
                .target(name: "MockServerEngine"),
                .target(name: "Domain"),
            ],
            settings: .settings(base: [
                "SWIFT_DEFAULT_ACTOR_ISOLATION": "none",
                "ENABLE_APP_SANDBOX": "NO",
            ])
        ),

        // Persistence — depends on Domain + GRDB
        // SWIFT_DEFAULT_ACTOR_ISOLATION overridden to "none" — GRDB closures run on background
        // threads; MainActor isolation causes deadlocks with DatabaseQueue.
        .target(
            name: "Persistence",
            destinations: [.mac],
            product: .staticFramework,
            bundleId: "devxa.Mimic.Persistence",
            buildableFolders: ["Sources/Persistence"],
            dependencies: [
                .target(name: "Domain"),
                .external(name: "GRDB"),
            ],
            settings: .settings(base: ["SWIFT_DEFAULT_ACTOR_ISOLATION": "none"])
        ),
        .target(
            name: "PersistenceTests",
            destinations: [.mac],
            product: .unitTests,
            bundleId: "devxa.Mimic.PersistenceTests",
            buildableFolders: ["Tests/PersistenceTests"],
            dependencies: [
                .target(name: "Persistence"),
                .target(name: "Domain"),
            ],
            settings: .settings(base: [
                "SWIFT_DEFAULT_ACTOR_ISOLATION": "none",
                "ENABLE_APP_SANDBOX": "NO",
            ])
        ),

        // ControlPlane — the automation surface: a loopback HTTP admin API over the same engine and
        // store the window uses. Hosted by the app; also runnable headless for CI.
        // SWIFT_DEFAULT_ACTOR_ISOLATION overridden to "none" — it owns a Vapor application and an
        // actor-isolated service, neither of which belongs on the main actor.
        .target(
            name: "ControlPlane",
            destinations: [.mac],
            product: .staticFramework,
            bundleId: "devxa.Mimic.ControlPlane",
            buildableFolders: ["Sources/ControlPlane"],
            dependencies: [
                .target(name: "Domain"),
                .target(name: "Persistence"),
                .target(name: "MockServerEngine"),
                .external(name: "Vapor"),
            ],
            settings: .settings(base: ["SWIFT_DEFAULT_ACTOR_ISOLATION": "none"])
        ),
        .target(
            name: "ControlPlaneTests",
            destinations: [.mac],
            product: .unitTests,
            bundleId: "devxa.Mimic.ControlPlaneTests",
            buildableFolders: ["Tests/ControlPlaneTests"],
            entitlements: .file(path: "Tests/ControlPlaneTests/ControlPlaneTests.entitlements"),
            dependencies: [
                .target(name: "ControlPlane"),
                .target(name: "Persistence"),
                .target(name: "MockServerEngine"),
                .target(name: "Domain"),
            ],
            settings: .settings(base: [
                "SWIFT_DEFAULT_ACTOR_ISOLATION": "none",
                "ENABLE_APP_SANDBOX": "NO",
            ])
        ),

        // MimicCLICore — the whole `mimic` command surface as a library so it can be unit tested.
        // Depends on Domain and ArgumentParser only: the CLI is a client, never a host, so it links
        // neither Vapor nor GRDB and stays a small static binary.
        .target(
            name: "MimicCLICore",
            destinations: [.mac],
            product: .staticFramework,
            bundleId: "devxa.Mimic.MimicCLICore",
            buildableFolders: ["Sources/MimicCLICore"],
            dependencies: [
                .target(name: "Domain"),
                .external(name: "ArgumentParser"),
            ],
            settings: .settings(base: ["SWIFT_DEFAULT_ACTOR_ISOLATION": "none"])
        ),
        .target(
            name: "MimicCLICoreTests",
            destinations: [.mac],
            product: .unitTests,
            bundleId: "devxa.Mimic.MimicCLICoreTests",
            buildableFolders: ["Tests/MimicCLICoreTests"],
            dependencies: [
                .target(name: "MimicCLICore"),
                .target(name: "Domain"),
            ],
            settings: .settings(base: [
                "SWIFT_DEFAULT_ACTOR_ISOLATION": "none",
                "ENABLE_APP_SANDBOX": "NO",
            ])
        ),

        // MimicCLI — the command line tool. Thin shell over MimicCLICore.
        //
        // Naming here is fiddly for one reason: macOS filesystems are case-insensitive by default, so
        // anything called `mimic` collides with the app's `Mimic`. A target named `mimic` loses the
        // app's scheme (`mimic.xcscheme` == `Mimic.xcscheme`), and setting `productName: "mimic"` also
        // sets the module name, so `mimic.swiftmodule` shadows `Mimic.swiftmodule` and
        // `@testable import Mimic` stops resolving.
        //
        // So: target and module are `MimicCLI`, and only PRODUCT_NAME is lowercased — the built binary
        // is `mimic`, which is all that matters to a caller.
        //
        // Not sandboxed and not hardened: it launches the app, signals it, and reads the discovery
        // file the app writes into its own container.
        .target(
            name: "MimicCLI",
            destinations: [.mac],
            product: .commandLineTool,
            bundleId: "devxa.Mimic.cli",
            buildableFolders: ["Tools/mimic"],
            dependencies: [
                .target(name: "MimicCLICore"),
                .target(name: "Domain"),
            ],
            settings: .settings(base: [
                "SWIFT_DEFAULT_ACTOR_ISOLATION": "none",
                "ENABLE_APP_SANDBOX": "NO",
                "ENABLE_HARDENED_RUNTIME": "NO",
                "CODE_SIGN_IDENTITY": "-",
                "PRODUCT_NAME": "mimic",
                "PRODUCT_MODULE_NAME": "MimicCLI",
            ])
        ),

        // DesignSystem — NO Domain dep (D-02)
        .target(
            name: "DesignSystem",
            destinations: [.mac],
            product: .staticFramework,
            bundleId: "devxa.Mimic.DesignSystem",
            buildableFolders: ["Sources/DesignSystem"],
            dependencies: [
                .external(name: "CodeEditorView"),
            ]
        ),

        .target(
            name: "DesignSystemTests",
            destinations: [.mac],
            product: .unitTests,
            bundleId: "devxa.Mimic.DesignSystemTests",
            buildableFolders: ["Tests/DesignSystemTests"],
            dependencies: [.target(name: "DesignSystem")]
        ),

        // SpecImport — HAR, OpenAPI, Swagger parsers → ImportCandidate (D-03)
        // SWIFT_DEFAULT_ACTOR_ISOLATION overridden to "none" — parsing runs on background
        // threads; MainActor isolation would prevent use from Task.detached.
        .target(
            name: "SpecImport",
            destinations: [.mac],
            product: .staticFramework,
            bundleId: "devxa.Mimic.SpecImport",
            buildableFolders: ["Sources/SpecImport"],
            dependencies: [
                .target(name: "Domain"),
                .external(name: "OpenAPIKit30"),
            ],
            settings: .settings(base: ["SWIFT_DEFAULT_ACTOR_ISOLATION": "none"])
        ),
        .target(
            name: "SpecImportTests",
            destinations: [.mac],
            product: .unitTests,
            bundleId: "devxa.Mimic.SpecImportTests",
            buildableFolders: ["Tests/SpecImportTests"],
            dependencies: [.target(name: "SpecImport"), .target(name: "Domain")],
            settings: .settings(base: ["SWIFT_DEFAULT_ACTOR_ISOLATION": "none"])
        ),

        // AppFeatures — deep application module for app workflows and SwiftUI flows
        .target(
            name: "AppFeatures",
            destinations: [.mac],
            product: .staticFramework,
            bundleId: "devxa.Mimic.AppFeatures",
            buildableFolders: ["Sources/AppFeatures"],
            dependencies: [
                .target(name: "Domain"),
                .target(name: "Persistence"),
                .target(name: "MockServerEngine"),
                .target(name: "ControlPlane"),
                .target(name: "DesignSystem"),
                .target(name: "SpecImport"),
            ]
        ),

        // MimicUITests — UI test target for end-to-end journey tests
        // SWIFT_DEFAULT_ACTOR_ISOLATION overridden to "none" — XCTestCase lifecycle methods
        // (setUp, tearDown, init) are nonisolated and conflict with MainActor isolation.
        .target(
            name: "MimicUITests",
            destinations: [.mac],
            product: .uiTests,
            bundleId: "devxa.Mimic.UITests",
            buildableFolders: ["MimicUITests"],
            dependencies: [
                .target(name: "Mimic"),
            ],
            settings: .settings(base: [
                "SWIFT_DEFAULT_ACTOR_ISOLATION": "none",
                "ENABLE_HARDENED_RUNTIME": "NO",
            ])
        ),

        // App — thin executable target that hosts the app entry point only
        .target(
            name: "Mimic",
            destinations: [.mac],
            product: .app,
            bundleId: "devxa.Mimic",
            // Version comes from MARKETING_VERSION so the tag, the bundle, and the `appVersion`
            // that `mimic state` reports cannot disagree.
            infoPlist: .extendingDefault(with: [
                "NSMainStoryboardFile": "",
                "CFBundleShortVersionString": "$(MARKETING_VERSION)",
                "CFBundleVersion": "$(CURRENT_PROJECT_VERSION)",
            ]),
            buildableFolders: ["App/Sources", "App/Resources"],
            entitlements: .file(path: "App/Mimic.entitlements"),
            dependencies: [
                .target(name: "Domain"),
                .target(name: "MockServerEngine"),
                .target(name: "Persistence"),
                .target(name: "ControlPlane"),
                .target(name: "DesignSystem"),
                .target(name: "SpecImport"),
                .target(name: "AppFeatures"),
            ],
            settings: .settings(
                base: [
                    "ENABLE_APP_SANDBOX": "YES",
                    "PRODUCT_BUNDLE_IDENTIFIER": "devxa.Mimic",
                ]
            )
        ),
        .target(
            name: "MimicTests",
            destinations: [.mac],
            product: .unitTests,
            bundleId: "devxa.Mimic.AppTests",
            buildableFolders: [
                "Tests/MimicTests",
                "Tests/WorkspaceFeatureTests",
                "Tests/EndpointFeatureTests",
                "Tests/ProjectFeatureTests",
                "Tests/ImportFeatureTests",
                "Tests/JourneyFeatureTests",
            ],
            dependencies: [
                .target(name: "Mimic"),
                .target(name: "AppFeatures"),
            ]
        ),
    ]
    ,
    schemes: [
        .scheme(
            name: "Mimic",
            buildAction: .buildAction(
                targets: [
                    .target("Mimic"),
                    // The CLI ships with the app, so a plain build produces both.
                    .target("MimicCLI"),
                ]
            ),
            testAction: .targets(
                [
                    .testableTarget(target: .target("MimicTests")),
                    .testableTarget(target: .target("MimicUITests")),
                ],
                expandVariableFromTarget: .target("Mimic"),
                options: .options(
                    coverage: true,
                    codeCoverageTargets: [
                        .target("AppFeatures"),
                        .target("ControlPlane"),
                        .target("DesignSystem"),
                        .target("Domain"),
                        .target("Mimic"),
                        .target("MimicCLICore"),
                        .target("MockServerEngine"),
                        .target("Persistence"),
                        .target("SpecImport"),
                    ]
                )
            ),
            runAction: .runAction(
                executable: .target("Mimic")
            ),
            archiveAction: .archiveAction(
                configuration: .release
            ),
            profileAction: .profileAction(
                executable: .target("Mimic")
            ),
            analyzeAction: .analyzeAction(
                configuration: .debug
            )
        ),
    ]
)

import ProjectDescription

let sharedSettings: Settings = .settings(
    base: [
        "SWIFT_VERSION": "6.2",
        "SWIFT_DEFAULT_ACTOR_ISOLATION": "MainActor",
        "SWIFT_APPROACHABLE_CONCURRENCY": "YES",
        "SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY": "YES",
        "ENABLE_HARDENED_RUNTIME": "YES",
        "ENABLE_MODULE_VERIFIER": "YES",
        "MODULE_VERIFIER_KIND": "builtin",
        "MODULE_VERIFIER_SUPPORTED_LANGUAGES": "objective-c objective-c++",
        "MODULE_VERIFIER_SUPPORTED_LANGUAGE_STANDARDS": "gnu11 gnu++14",
        "ENABLE_USER_SCRIPT_SANDBOXING": "YES",
        "ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS": "YES",
        "STRING_CATALOG_GENERATE_SYMBOLS": "YES",
        "MACOSX_DEPLOYMENT_TARGET": "26.0",
        "DEVELOPMENT_TEAM": "KW6369JJL9",
        // Surfaced by `mimic state` as `appVersion`, so a caller can tell which build it is driving.
        "MARKETING_VERSION": "0.13.0",
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
                .external(name: "AsyncHTTPClient"),
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

        // ControlPlane — the automation surface: the loopback HTTP admin API (`ControlServer`) and
        // the 0600 discovery file (`ControlEndpointFile`). The host behind the API is supplied by
        // the app (`AppControlHost`); this module holds no host of its own since the owner's
        // decision to delete `MimicControlService` and `MimicDaemon`, which is why it depends on
        // Domain and Vapor alone — the deleted pair was its whole use of Persistence and
        // MockServerEngine, and `check_module_edges.py` now forbids both edges.
        // SWIFT_DEFAULT_ACTOR_ISOLATION overridden to "none" — it owns a Vapor application, which
        // does not belong on the main actor.
        .target(
            name: "ControlPlane",
            destinations: [.mac],
            product: .staticFramework,
            bundleId: "devxa.Mimic.ControlPlane",
            buildableFolders: ["Sources/ControlPlane"],
            dependencies: [
                .target(name: "Domain"),
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

        // UI sections — one framework per part of the window, each built, tested and previewed on its
        // own. A section depends on Domain, DesignSystem and FeatureSupport only (ImportFeature also on
        // SpecImport, whose parsers it drives): never on AppFeatures, the server, the store, or another
        // section. `check_module_edges.py` enforces it. Each section reads and edits through a model
        // protocol it declares, which `AppState` conforms to in AppFeatures, the composition root.
        // FeatureSupport — the small pieces more than one section uses: navigator tabs, the rename
        // sheet, the request field, status phrases, port probing.
        .target(
            name: "FeatureSupport",
            destinations: [.mac],
            product: .staticFramework,
            bundleId: "devxa.Mimic.FeatureSupport",
            buildableFolders: ["Sources/FeatureSupport"],
            dependencies: [
                .target(name: "Domain"),
                .target(name: "DesignSystem"),
            ]
        ),
        .target(
            name: "FeatureSupportTests",
            destinations: [.mac],
            product: .unitTests,
            bundleId: "devxa.Mimic.FeatureSupportTests",
            buildableFolders: ["Tests/FeatureSupportTests"],
            dependencies: [
                .target(name: "FeatureSupport"),
                .target(name: "Domain"),
            ]
        ),
        // WorkspaceShell — the window skeleton: panel layout and chrome, jump bar, toolbar tiers,
        // inspector overview. It takes the sections as slots and knows none of them.
        .target(
            name: "WorkspaceShell",
            destinations: [.mac],
            product: .staticFramework,
            bundleId: "devxa.Mimic.WorkspaceShell",
            buildableFolders: ["Sources/WorkspaceShell"],
            dependencies: [
                .target(name: "Domain"),
                .target(name: "DesignSystem"),
                .target(name: "FeatureSupport"),
            ]
        ),
        .target(
            name: "WorkspaceShellTests",
            destinations: [.mac],
            product: .unitTests,
            bundleId: "devxa.Mimic.WorkspaceShellTests",
            buildableFolders: ["Tests/WorkspaceShellTests"],
            dependencies: [
                .target(name: "WorkspaceShell"),
                .target(name: "Domain"),
            ]
        ),
        // EndpointsFeature — endpoint navigator, editor, scenarios inspector, sheets, first-run chooser.
        .target(
            name: "EndpointsFeature",
            destinations: [.mac],
            product: .staticFramework,
            bundleId: "devxa.Mimic.EndpointsFeature",
            buildableFolders: ["Sources/EndpointsFeature"],
            dependencies: [
                .target(name: "Domain"),
                .target(name: "DesignSystem"),
                .target(name: "FeatureSupport"),
            ]
        ),
        .target(
            name: "EndpointsFeatureTests",
            destinations: [.mac],
            product: .unitTests,
            bundleId: "devxa.Mimic.EndpointsFeatureTests",
            buildableFolders: ["Tests/EndpointsFeatureTests"],
            dependencies: [
                .target(name: "EndpointsFeature"),
                .target(name: "Domain"),
                .target(name: "DesignSystem"),
            ]
        ),
        // JourneysFeature — journey navigator, editor, step inspector, step and capture sheets.
        .target(
            name: "JourneysFeature",
            destinations: [.mac],
            product: .staticFramework,
            bundleId: "devxa.Mimic.JourneysFeature",
            buildableFolders: ["Sources/JourneysFeature"],
            dependencies: [
                .target(name: "Domain"),
                .target(name: "DesignSystem"),
                .target(name: "FeatureSupport"),
            ]
        ),
        .target(
            name: "JourneysFeatureTests",
            destinations: [.mac],
            product: .unitTests,
            bundleId: "devxa.Mimic.JourneysFeatureTests",
            buildableFolders: ["Tests/JourneysFeatureTests"],
            dependencies: [
                .target(name: "JourneysFeature"),
                .target(name: "Domain"),
                .target(name: "DesignSystem"),
            ]
        ),
        // RequestLogFeature — request log table, filters, request detail, export.
        .target(
            name: "RequestLogFeature",
            destinations: [.mac],
            product: .staticFramework,
            bundleId: "devxa.Mimic.RequestLogFeature",
            buildableFolders: ["Sources/RequestLogFeature"],
            dependencies: [
                .target(name: "Domain"),
                .target(name: "DesignSystem"),
                .target(name: "FeatureSupport"),
            ]
        ),
        .target(
            name: "RequestLogFeatureTests",
            destinations: [.mac],
            product: .unitTests,
            bundleId: "devxa.Mimic.RequestLogFeatureTests",
            buildableFolders: ["Tests/RequestLogFeatureTests"],
            dependencies: [
                .target(name: "RequestLogFeature"),
                .target(name: "Domain"),
                .target(name: "DesignSystem"),
            ]
        ),
        // ServerFeature — run control, server status, server settings.
        .target(
            name: "ServerFeature",
            destinations: [.mac],
            product: .staticFramework,
            bundleId: "devxa.Mimic.ServerFeature",
            buildableFolders: ["Sources/ServerFeature"],
            dependencies: [
                .target(name: "Domain"),
                .target(name: "DesignSystem"),
                .target(name: "FeatureSupport"),
            ]
        ),
        .target(
            name: "ServerFeatureTests",
            destinations: [.mac],
            product: .unitTests,
            bundleId: "devxa.Mimic.ServerFeatureTests",
            buildableFolders: ["Tests/ServerFeatureTests"],
            dependencies: [
                .target(name: "ServerFeature"),
                .target(name: "Domain"),
                .target(name: "DesignSystem"),
            ]
        ),
        // ImportFeature — HAR and OpenAPI import review and commit.
        .target(
            name: "ImportFeature",
            destinations: [.mac],
            product: .staticFramework,
            bundleId: "devxa.Mimic.ImportFeature",
            buildableFolders: ["Sources/ImportFeature"],
            dependencies: [
                .target(name: "Domain"),
                .target(name: "DesignSystem"),
                .target(name: "FeatureSupport"),
                .target(name: "SpecImport"),
            ]
        ),
        .target(
            name: "ImportFeatureTests",
            destinations: [.mac],
            product: .unitTests,
            bundleId: "devxa.Mimic.ImportFeatureTests",
            buildableFolders: ["Tests/ImportFeatureTests"],
            dependencies: [
                .target(name: "ImportFeature"),
                .target(name: "SpecImport"),
                .target(name: "FeatureSupport"),
                .target(name: "Domain"),
                .target(name: "DesignSystem"),
            ]
        ),
        // ProjectsFeature — welcome window and new project sheet.
        .target(
            name: "ProjectsFeature",
            destinations: [.mac],
            product: .staticFramework,
            bundleId: "devxa.Mimic.ProjectsFeature",
            buildableFolders: ["Sources/ProjectsFeature"],
            dependencies: [
                .target(name: "Domain"),
                .target(name: "DesignSystem"),
                .target(name: "FeatureSupport"),
            ]
        ),
        .target(
            name: "ProjectsFeatureTests",
            destinations: [.mac],
            product: .unitTests,
            bundleId: "devxa.Mimic.ProjectsFeatureTests",
            buildableFolders: ["Tests/ProjectsFeatureTests"],
            dependencies: [
                .target(name: "ProjectsFeature"),
                .target(name: "Domain"),
            ]
        ),
        // UpdatesFeature — the update sheet. The feed, download and installer stay in AppFeatures.
        .target(
            name: "UpdatesFeature",
            destinations: [.mac],
            product: .staticFramework,
            bundleId: "devxa.Mimic.UpdatesFeature",
            buildableFolders: ["Sources/UpdatesFeature"],
            dependencies: [
                .target(name: "Domain"),
                .target(name: "DesignSystem"),
            ]
        ),
        // MimicFixtures — the design canvas's data as Mimic values, for the gallery, previews and
        // snapshot tests. Debug only: every file is `#if DEBUG`.
        .target(
            name: "MimicFixtures",
            destinations: [.mac],
            product: .staticFramework,
            bundleId: "devxa.Mimic.MimicFixtures",
            buildableFolders: ["Sources/MimicFixtures"],
            dependencies: [
                .target(name: "Domain"),
            ],
            settings: .settings(base: ["SWIFT_DEFAULT_ACTOR_ISOLATION": "none"])
        ),
        // SnapshotSupport — renders a view to a 2x PNG, scores it against an exported artboard, and
        // writes a fidelity report. No Mimic dependencies.
        .target(
            name: "SnapshotSupport",
            destinations: [.mac],
            product: .staticFramework,
            bundleId: "devxa.Mimic.SnapshotSupport",
            buildableFolders: ["Sources/SnapshotSupport"],
            dependencies: [],
            settings: .settings(base: ["SWIFT_DEFAULT_ACTOR_ISOLATION": "none"])
        ),
        .target(
            name: "SnapshotSupportTests",
            destinations: [.mac],
            product: .unitTests,
            bundleId: "devxa.Mimic.SnapshotSupportTests",
            buildableFolders: ["Tests/SnapshotSupportTests"],
            dependencies: [.target(name: "SnapshotSupport")],
            settings: .settings(base: ["SWIFT_DEFAULT_ACTOR_ISOLATION": "none"])
        ),

        // MimicGallery — a development tool, never shipped or archived: every component and section
        // on its own, drawn from MimicFixtures, with the design artboard over it. It carries no
        // server, store or AppState; a section that needs them to draw is a section that leaked.
        .target(
            name: "MimicGallery",
            destinations: [.mac],
            product: .app,
            bundleId: "devxa.Mimic.Gallery",
            infoPlist: .extendingDefault(with: [
                "NSMainStoryboardFile": "",
                "CFBundleShortVersionString": "$(MARKETING_VERSION)",
                "CFBundleVersion": "$(CURRENT_PROJECT_VERSION)",
            ]),
            buildableFolders: ["Tools/MimicGallery"],
            dependencies: [
                .target(name: "Domain"),
                .target(name: "DesignSystem"),
                .target(name: "SpecImport"),
                .target(name: "FeatureSupport"),
                .target(name: "WorkspaceShell"),
                .target(name: "EndpointsFeature"),
                .target(name: "JourneysFeature"),
                .target(name: "RequestLogFeature"),
                .target(name: "ServerFeature"),
                .target(name: "ImportFeature"),
                .target(name: "ProjectsFeature"),
                .target(name: "UpdatesFeature"),
                .target(name: "MimicFixtures"),
                .target(name: "SnapshotSupport"),
            ],
            settings: .settings(base: [
                "ENABLE_APP_SANDBOX": "NO",
                "CODE_SIGN_IDENTITY": "-",
            ])
        ),
        // DesignFidelityTests — renders every gallery entry and scores it against its artboard. The
        // scores are a report, never a failure; see the suite's own comment.
        .target(
            name: "DesignFidelityTests",
            destinations: [.mac],
            product: .unitTests,
            bundleId: "devxa.Mimic.DesignFidelityTests",
            buildableFolders: ["Tests/DesignFidelityTests"],
            dependencies: [
                .target(name: "MimicGallery"),
                .target(name: "SnapshotSupport"),
            ],
            settings: .settings(base: ["ENABLE_APP_SANDBOX": "NO"])
        ),

        // AppFeatures — the composition root: AppState, the control host, the server runtime,
        // persistence wiring, and the views that put the sections together.
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
                .target(name: "FeatureSupport"),
                .target(name: "WorkspaceShell"),
                .target(name: "EndpointsFeature"),
                .target(name: "JourneysFeature"),
                .target(name: "RequestLogFeature"),
                .target(name: "ServerFeature"),
                .target(name: "ImportFeature"),
                .target(name: "ProjectsFeature"),
                .target(name: "UpdatesFeature"),
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
            // The runner binds a port of its own, so it needs what the other two port-binding test
            // targets need. The port-conflict alert can only be reached by holding the port the app
            // is about to take, and the code that does the holding runs in the XCTest *runner* app,
            // not in Mimic — so the runner is the process that must be allowed to listen. Without
            // this every `bind(2)` came back `EPERM`, on ports from 21311 to 65535 alike, which
            // reads as "that port is busy" and is really "this process may not listen at all".
            // `ControlPlaneTests` and `MockServerEngineTests` carry the same pair for the same
            // reason; this target was the one that binds a socket without them.
            entitlements: .file(path: "MimicUITests/MimicUITests.entitlements"),
            dependencies: [
                .target(name: "Mimic"),
            ],
            settings: .settings(base: [
                "SWIFT_DEFAULT_ACTOR_ISOLATION": "none",
                "ENABLE_HARDENED_RUNTIME": "NO",
                "ENABLE_APP_SANDBOX": "NO",
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
                "LSApplicationCategoryType": "public.app-category.developer-tools",
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
                // Tests that need more than one section, or a section inside the window.
                "Tests/WorkspaceFeatureTests",
            ],
            dependencies: [
                .target(name: "Mimic"),
                .target(name: "AppFeatures"),
                // Declared for `ComposedControlServerTests`, which stands the shipped pairing up —
                // `ControlServer` on `AppControlHost` — over a loopback socket. The module is
                // reachable through the two edges above whether or not it is named here; naming it
                // is what stops that from being an implicit transitive import, which
                // SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY exists to refuse.
                .target(name: "ControlPlane"),
                .target(name: "FeatureSupport"),
                .target(name: "WorkspaceShell"),
                .target(name: "EndpointsFeature"),
                .target(name: "JourneysFeature"),
                .target(name: "RequestLogFeature"),
                .target(name: "ServerFeature"),
                .target(name: "ImportFeature"),
                .target(name: "ProjectsFeature"),
                .target(name: "UpdatesFeature"),
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
                        .target("EndpointsFeature"),
                        .target("FeatureSupport"),
                        .target("ImportFeature"),
                        .target("JourneysFeature"),
                        .target("Mimic"),
                        .target("MimicCLICore"),
                        .target("MockServerEngine"),
                        .target("Persistence"),
                        .target("ProjectsFeature"),
                        .target("RequestLogFeature"),
                        .target("ServerFeature"),
                        .target("SpecImport"),
                        .target("UpdatesFeature"),
                        .target("WorkspaceShell"),
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

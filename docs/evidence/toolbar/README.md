# Native toolbar review

Captured on 2026-09-21 from the Debug app with isolated XCUITest projects, after updating the
toolbar branch onto `f22e171` (main). These are actual window screenshots, not design mockups.

| Screenshot | Observed state |
| --- | --- |
| [Running](running.png) | Green Stop button and green status below the localhost port; neutral Local mock subtitle. Import and settings remain at the editor's right edge. |
| [Stopped](stopped.png) | Red Stopped status, neutral Play button, and the same project/address arrangement. |
| [Compact details](compact-details.png) | Project and server summary remain visible; editor actions use overflow while panel controls remain separate. The popover offers per-port URL copying. |
| [Pending ports](pending-ports.png) | Two listeners remain active while edited configuration requires a restart; the summary reports that warning in amber. |

The final focused run passed 13 presentation/rendering tests and three XCUITests. The UI checks
cover opening directly into a compact window, toolbar column ownership, panel collapse/restore,
start/stop geometry, URL copying, and active versus pending listener addresses. The nine house-rule
checks and diff whitespace check also passed.

```sh
xcodebuild -workspace Mimic.xcworkspace -scheme Mimic \
  -destination 'platform=macOS' -derivedDataPath .artifacts/DerivedData \
  -parallel-testing-enabled NO \
  -only-testing:MimicTests/ServerStatusWellTests \
  -only-testing:MimicTests/WorkspaceFeatureRenderingTests \
  -only-testing:MimicUITests/BackendSettingsUITests/testToolbarDistinguishesListeningAndPendingPorts \
  -only-testing:MimicUITests/WorkspaceShellUITests/testToolbarPreservesIdentityAndCollapsesSecondaryActions \
  -only-testing:MimicUITests/WorkspaceShellUITests/testServerWellReportsItsStateAndCopiesTheAddress \
  COMPILER_INDEX_STORE_ENABLE=NO CODE_SIGN_IDENTITY=- test
```

These checks establish the selected toolbar behavior. They do not replace the full repository
suite, import completion checks, or normal-session persistence evidence. Static images do not
demonstrate the symbol animation; its implementation honors Reduce Motion.

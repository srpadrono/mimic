# Redesign test inventory

Every XCUIElement query in the UI suite, traced to the identifier or label it targets in `Sources/`, and mapped to the redesign issue that changes it.

## Why this file exists

The redesign lands on a long-lived branch. That means the test migration is never reviewed incrementally: no single PR shows "this issue renamed a control, and here is the query that followed it". A query whose target is deleted does not fail loudly at review time — it fails at the end, in a batch, in a suite that has already been red for other reasons, and by then nobody can tell which of eleven merged issues orphaned it.

This document is the only thing that catches that. It is a fixed record of what each query resolves against **today**, so that when an issue changes a control, the person doing the work can see — before writing a line — which tests point at it and whether they point at an identifier or at a string of English.

**How to use it.** Every UI-facing issue quotes its own rows in its acceptance criteria. Not "update the UI tests if needed" — the actual rows, with their `MimicUITests.swift:NNN` locations, and a statement of what the query becomes. An issue that deletes a control and does not name its rows here is not ready to start. Issue #30 already does this correctly (it counts its twelve call sites and commits to re-pointing them in the same commit); #41 and #44 currently do not, and between them they delete eight live query targets while naming none.

**The single most important distinction in this file** is `Resolves by`. AGENTS.md rule 8 explains it: a container's `.accessibilityIdentifier` overrides its descendants', and pairing it with `.accessibilityElement(children: .contain)` preserves each child's **label and value** but *not* its identifier. So a control can carry a perfectly good identifier in the source and still be reachable only by its label. Those queries are invisible to `rg`: renaming a `help:` string looks like copy editing and breaks a test. They are collected in their own section below, and every one of them is a label the owning issue must treat as an API.

### Provenance and caveats

- Scanned against the working tree of `redesign/workspace`. A parallel session landed **#25** mid-inventory (`BreadcrumbJumpBar.swift` deleted, `CenterPaneNavigation.swift` and `NavigationHistory.swift` added, `WorkspaceView.swift` / `EndpointEditorView.swift` / `JourneyEditorView.swift` / `CenterPaneView.swift` / `DSFilterField.swift` / `DSBarHeight.swift` modified). **Source line numbers here are post-#25** and differ from any inventory taken against HEAD — e.g. `endpointEditor.statusCode` moved `:310 → :338`, `journeyEditor.name` moved `:101 → :116`, and the navigator's `help: "Add endpoint"` sits at `WorkspaceView.swift:560`. Verify with `rg -n` before quoting a line in an issue; identifiers are stable, offsets are not.
- Issue assignments are inferences from the issue bodies as written. Several issues name a file without naming the control inside it. **ORPHAN here means "no issue body mentions it", not "no issue will touch it"** — which is exactly the failure this document exists to surface.
- The suite was **not executed**. Nothing here is a claim about current pass/fail, only about what each query resolves against.
- Cut issues **#7 #20 #22 #32 #35 #45** (latency chain, sparkline) own nothing in the UI suite. Confirmed: no query touches latency, sparklines or log statistics.

---

## 1. The readiness gate

`WorkspacePage.assertVisible` at `MimicUITests/MimicUITests.swift:203` is the widest blast radius in the repository.

```
UITestApp.waitForAny([sidebarEmptyHeading, addEndpointButton], timeout: 10)
```

It polls **exactly two elements, and neither is an identifier query**:

| # | Query | Location | Resolves against |
|---|-------|----------|------------------|
| 1 | `app.staticTexts["No endpoints"]` | `MimicUITests.swift:104` | `DSEmptyState(heading:)` — `Sources/AppFeatures/WorkspaceFeature/SidebarView.swift:89`. The identifier `ds.empty.sidebar.endpoints.heading` exists (`DSEmptyState.swift:104`) and is **not used**; the heading arrives as the flattened element's *value*. |
| 2 | `app.buttons["Add endpoint"].firstMatch` | `MimicUITests.swift:125` | `sidebar.addEndpointButton` is set at `Sources/AppFeatures/AppCore/WorkspaceView.swift:580` and **never reaches the tree**. The match comes from `help: "Add endpoint"` at `WorkspaceView.swift:560`, surfaced by `.accessibilityLabel(help)` at `Sources/DesignSystem/Components/DSPanelHeader.swift:159`. |

**Reach: 28 of 32 tests in `MimicUITests.swift`, plus all 7 in `JourneyUITests.swift`.** Directly at `:640 :652 :718 :730 :757 :767 :937 :1028 :1078 :1102 :1459 :1471 :1515 :1537`, and indirectly from `createProjectViaUI:1612`, which ends in `_ = workspace.assertVisible()`. `JourneyUITests.swift:194` and `:397` call the same gate. Only `testWelcomeScreenShowsHeroAndButtons:608`, `testPortValidationShowsInlineError:867`, `testEscapeDismissesNewProjectSheet:903` and `testCancelButtonDismissesNewProjectSheet:944` bypass it.

**The failure mode is the problem.** If either string moves, 28 + 7 tests fail during setup, before reaching their own subject, reporting *"Workspace should appear"*. That reads as a broken app or a broken launch — not as a copy edit in `SidebarView.swift`. A journeys-issue owner would never think to look there.

### What must happen

**Candidate 2 is scheduled for change and nobody has connected the two.** #26's acceptance criteria include *"every leaf carries a unique `.accessibilityLabel`"* for `DSPanelHeader` leaves — and this button *is* a `DSPanelHeaderButton`. Making its label unique within its header is precisely what breaks `app.buttons["Add endpoint"]`. #28's review correction additionally puts the `DSTabStrip` restyle in scope, and that strip is the accessory the button lives in.

**Candidate 1 is an orphan.** No issue in the set changes `"No endpoints"`. #28 rewrites `SidebarView.swift` extensively — rows, widths, group headers, trailing slot, selection modifier — but never mentions the `DSEmptyState` at `:87-99`. #41 states `DSEmptyState` is untouched and covers journeys only. #43 covers `ds.empty.journeys.empty`. The most load-bearing string in the suite sits inside the file #28 rewrites, with nobody assigned to preserve it.

**It is also ambiguous.** Three production views emit the label `"Add endpoint"`, and `.firstMatch` takes whichever the tree lists first:

- `WorkspaceView.swift:560` — the navigator `DSTabStrip` accessory button
- `SidebarView.swift:95` — the `DSEmptyState` CTA (`DSEmptyState.swift:115-121`)
- `NewEndpointSheet.swift:117` + `.accessibilityLabel("Add endpoint")` at `:124` — the sheet's own Create button

With the sheet open, the gate can resolve to the sheet's button.

**Required before #26 or #28 lands:**

1. Assign `"No endpoints"` explicitly to **#28**, in its acceptance criteria, by string.
2. Give the gate a handle that is verified to survive — an identifier confirmed present in an `app.debugDescription` dump, or a label the issue commits to — and re-point `assertVisible` **in the same commit**, the way #30 already commits to re-pointing its server call sites.
3. Disambiguate `"Add endpoint"`: three emitters, one `.firstMatch`.

### The second gate, for journeys

`JourneysNavigatorPage.waitUntilVisible` at `JourneyUITests.swift:78-83` polls three candidates owned by **three different issues** and nothing coordinates them:

| Candidate | Owner |
|---|---|
| `app.menuButtons["Add journey"].firstMatch` (`:42`) | #41 / #43 |
| `ds.empty.journeys.empty` (`:52-54`) | #43 |
| `app.staticTexts["journeyEditor.name"]` (`:56`) | #25 / #44 |

Called from `showJourneysNavigator()` at `:215`, which all 7 journey tests call. Land any two of those three and the whole file fails at the same line with *"Journeys navigator should appear in the sidebar"*.

---

## 2. Queries that resolve by label, not identifier

These are the fragile ones. Each has a real `.accessibilityIdentifier` in `Sources/` that **does not reach the accessibility tree**, because a container above it stamps its own name over the leaf. The label is the API. Renaming a `help:` string, an `actionTitle:`, a `heading:` or a `Text` breaks a test and looks like copy editing in the diff.

| Query | Test location | Label string | Identifier that does *not* survive | Owner | Risk |
|---|---|---|---|---|---|
| `app.buttons["Add endpoint"].firstMatch` | `MimicUITests.swift:125` | `help: "Add endpoint"` — `WorkspaceView.swift:560` | `sidebar.addEndpointButton` — `WorkspaceView.swift:580` | #26 / #28 | breaks-readiness-gate |
| `app.staticTexts["No endpoints"]` | `MimicUITests.swift:104` | `heading:` — `SidebarView.swift:89` | `ds.empty.sidebar.endpoints.heading` — `DSEmptyState.swift:104` | ORPHAN | breaks-readiness-gate |
| `app.buttons["Show journeys"].firstMatch` | `JourneyUITests.swift:25` | `NavigatorTab.journeys.help` — `NavigatorTab.swift:51` | `navigator.tab.journeys` — `DSTabStrip.swift:99,180` | unaffected | safe |
| `app.menuButtons["Add journey"].firstMatch` | `JourneyUITests.swift:42` | `WorkspaceView.swift:529` | `journeys.addJourneyButton` — `WorkspaceView.swift:528` | #41 / #43 | breaks-readiness-gate |
| `app.buttons["Back to the endpoint inspector"].firstMatch` | `MimicUITests.swift:396` | `help:` — `InspectorPanelView.swift:162` | `inspector.closeRequestDetailButton` — `:163` | #36 | breaks-test |
| `app.staticTexts["No requests yet"]` | `MimicUITests.swift:163`, `:280` | `heading:` — `RequestLogDrawerView.swift:307` | `ds.empty.drawer.requests.heading` | ORPHAN | may-break |
| `app.staticTexts["No endpoint selected"]` | `MimicUITests.swift:107` | `heading:` — `CenterPaneView.swift:48` | `ds.empty.center.noSelection.heading` | ORPHAN | may-break |
| `app.staticTexts["No matching requests"]` | `MimicUITests.swift:281` | `heading:` — `RequestLogDrawerView.swift:313` | `ds.empty.drawer.noMatches.heading` | ORPHAN | safe (dead) |
| `app.staticTexts["No OpenAPI spec loaded"]` | `MimicUITests.swift:483` | `ImportFlow.emptyHeading` — `ImportFlowSupport.swift:49` | `openAPIImport.empty` — `:103` | unaffected | safe |
| `app.staticTexts["No HAR file loaded"]` | `MimicUITests.swift:496` | `ImportFlowSupport.swift:48` | `harImport.empty` — `:102` | unaffected | safe |
| `endpointPathText(_:)` = `app.staticTexts[path].firstMatch` | `MimicUITests.swift:165` | `Text(endpoint.path)` — `SidebarView.swift:396` | `endpoint-<uuid>` — `SidebarView.swift:432` | #28 | may-break |
| `app.staticTexts["/api/users"]`, `["/api/posts"]` | `MimicUITests.swift:1178-1179` | as above | as above | #28 | may-break |
| `journeyRow(named:)` — `label CONTAINS <name>` over all descendants | `JourneyUITests.swift:67-71` | row label `"<name>, <n> steps, active\|not active"` — `JourneyNavigatorList.swift:292` | `journeys.row.<uuid>` — `:291` | #43 | may-break |
| `app.buttons["Add journey"].firstMatch` (empty-state CTA) | `JourneyUITests.swift:45` | `actionTitle:` — `JourneyNavigatorList.swift:66` | `empty.journeys.empty.cta` — `DSEmptyState.swift:120` | #43 | may-break |
| `app.buttons.matching(label CONTAINS "Choose HAR file")` | `MimicUITests.swift:499` | `ImportFlow.emptyActionTitle` — `ImportFlowSupport.swift:74` | `empty.harImport.empty.cta` | unaffected | safe (dead) |
| `app.sheets.firstMatch.buttons["Delete project"]` / `["Keep project"]` | `MimicUITests.swift:512-513` | `WelcomeWindow.swift:116`, `:119` | none set | unaffected | safe |
| `app.sheets.firstMatch.buttons["Delete"]` | `MimicUITests.swift:1072` | `EndpointEditorView.swift:287` (also `SidebarView.swift:117`) | none set | #31 | safe |
| `app.menuItems["Delete endpoint…"]` | `MimicUITests.swift:1067` | `EndpointEditorView.swift:265` (also `SidebarView.swift:226`) | none set | #25 / #39 | may-break |
| `app.menuItems["Duplicate"]` | `MimicUITests.swift:800`, `:824`, `:1132`, `:1155` | four emitters: `WelcomeWindow.swift:297`, `SidebarView.swift:220`, `InspectorPanelView.swift:377`, `JourneyNavigatorList.swift:277` | none set | #39 | safe |
| `app.menuItems["Add 2 requests to journey"]` | `MimicUITests.swift:1277` | count-interpolated — `RequestLogDrawerView.swift:887` | `requestLog.addToJourneyMenu.<uuid>` — `:908` | #34 | may-break |
| `app.menuItems["New journey from these 2 requests…"]` | `MimicUITests.swift:1284` | count-interpolated — `RequestLogDrawerView.swift:902` | `requestLog.addToNewJourney.<uuid>` — `:906` | #34 | may-break |
| `app.menuItems["New Project…"]`, `["Close Project"]`, `["Open"]`, `["Delete project…"]`, `["Show Journeys"]`, `menuBarItems["Journeys"]` / `["File"]` | `MimicUITests.swift:744`, `:798`, `:802`, `:1592`; `JourneyUITests.swift:207`, `:211`, `:388`, `:390` | `MimicScene.swift:46,51,82,91`; `WelcomeWindow.swift:293,301` | none set | unaffected | safe |
| `RequestDetailPage.tab(_:)` — `radioButtons[title]` then `buttons[title]` | `MimicUITests.swift:420` | `RequestDetailTab` raw values — `RequestDetailInspector.swift:8-10` | `requestDetail.tabs` — `:113` | unaffected | safe |
| `WelcomePage.heroTitleByLabel`, `windowByTitle`, `noRecentProjectsLabelByLabel` | `MimicUITests.swift:13`, `:14`, `:17` | `WelcomeWindow.swift:159`, bundle display name, `:256` | — | unaffected | safe |

**Two structural notes that belong with this table:**

- **`menuButtons` vs `buttons` is load-bearing.** `JourneyUITests.swift:42` and `:45` both target the label `"Add journey"`; only the element type separates the `DSTabStrip`'s Menu from the `DSEmptyState`'s plain Button. Collapse the distinction and the query resolves to the empty state and then waits forever for a menu item that never appears.
- **The inverse rule, which #31 must not violate.** `app.textFields["projectNameField"]` and `app.textFields["newJourney.nameField"]` work *because* their `DSTextField` is deliberately **not** paired with `.accessibilityElement(children: .contain)` — the wrapper lends its name to the single field inside. Adding `.contain` there turns the element into a container and the query stops finding a text field at all. That pattern accounts for most of the sheet coverage in the suite.

---

## 3. Main table, by owning issue

Locations are `MimicUITests/` files. "—" in Test location means the identifier exists in `Sources/` with no query pointing at it (see §5).

### #25 — delete BreadcrumbJumpBar *(landed mid-inventory)*

| Query | Test location | Source identifier | Resolves by | Risk | Note |
|---|---|---|---|---|---|
| `EndpointEditorPage.pathLabel` | `MimicUITests.swift:247`, waited at `:1626`, asserted `:1032` | `endpointEditor.path` — `EndpointEditorView.swift:221` | identifier | may-break | **Load-bearing:** the wait target of `createEndpointViaUI`, so every endpoint-creating test blocks on it. #25 moved the back/forward pair into this header row and #39 mounts `DSScenarioControl` there — adding siblings is exactly when SwiftUI starts or stops flattening a leaf. |
| `WorkspacePage.centerPane` | `MimicUITests.swift:98` | `centerPane` — `WorkspaceView.swift:147` | identifier | safe | Dead query. The breadcrumb mount that sat here is gone; pane is 24pt taller. |
| `app.menuItems["Delete endpoint…"]` | `MimicUITests.swift:1067` | none — `EndpointEditorView.swift:265` | label | may-break | Reached through `endpointEditor.moreMenu`, whose header row #25 and #39 both edit. |
| `EditorHistoryButton` identifier | — | `editor.navigation.back` / `.forward` — `CenterPaneNavigation.swift:96,104,138` | identifier | may-break | **New, no coverage.** Replaces `breadcrumb.back` / `.forward`. Mounted in `EndpointEditorView.swift:222` and in `CenterPaneView`'s empty-state header. **Not** in `JourneyEditorView` — the inventory scanned mid-#25 and caught an intermediate state; the arrows were removed from the journey editor because the history they steer is over endpoints while that pane renders a journey. Covered by `testCentrePaneHistoryWalksBackAndForward`, which targets by label. |
| `editor.jump.<section>.<uuid>` | — | `CenterPaneNavigation.swift:173` | label | may-break | Covered by `testEditorOverflowJumpsToSiblingEndpoint`. Replaces `breadcrumb.option.<uuid>`. Menu items keep their own identity, but #25 says target by label; options carry `"<title>, selected"` when current. |
| `journeyEditor.jumpMenu` | — | `JourneyEditorView.swift:219` | label | safe | Covered by `JourneyUITests.testJourneyEditorOverflowJumpsToAnotherJourney`, which targets `"Go to another journey"` by label with an identifier fallback. |

### #26 — DSPanelHeader accessory slot

| Query | Test location | Source identifier | Resolves by | Risk | Note |
|---|---|---|---|---|---|
| `WorkspacePage.addEndpointButton` | `MimicUITests.swift:125`; the gate at `:204` | `help: "Add endpoint"` — `WorkspaceView.swift:560`; identifier `:580` lost | **label** | breaks-readiness-gate | See §1. #26's "every leaf carries a unique label" is what breaks it. |
| `RequestDetailPage.panelTitle(_:)` | `MimicUITests.swift:379`, used `:1337`, `:1387` | `ds.panelheader.title.<id>` — `DSPanelHeader.swift:51`; container `ds.panelheader.<id>` — `:95` | **value** | breaks-test | Compound predicate accepting *either* identifier and matching on value — already a workaround for the flattening. #26 re-typesets the title to 12pt semibold; the **value match** is the part that must survive. |
| `DSPanelHeaderButton` identifier | six realized ids | `DSPanelHeader.swift:159` | **label** | breaks-readiness-gate | All six stamped over by their host: `sidebar.addEndpointButton`, `inspector.closeRequestDetailButton`, `inspector.addScenarioButton`, `clearRequestLogButton`, `journeys.restartButton/.advanceButton/.deactivateButton`. The unique-label requirement is the only thing making them addressable — and the thing that breaks the gate. |
| `ds.panelheader.subtitle.<id>` | — | `DSPanelHeader.swift:73` | value | safe | The count slot, untested. #26 keeps `labelSecondary` rather than the spec's `labelTertiary`. |

### #28 — navigator re-typeset

| Query | Test location | Source identifier | Resolves by | Risk | Note |
|---|---|---|---|---|---|
| `WorkspacePage.sidebarEmptyHeading` | `MimicUITests.swift:104`; gate at `:204`; `:652 :1028 :1078 :1102` | `heading: "No endpoints"` — `SidebarView.swift:89` | **label** | breaks-readiness-gate | Currently an orphan. **Assign to #28.** |
| `WorkspacePage.endpointPathText(_:)` | `MimicUITests.swift:165`, used `:1517-1520` | `Text(endpoint.path)` — `SidebarView.swift:396` | **label** | may-break | #28 re-typesets this row: 30pt height, 8pt insets, `dsSelectedListRow()`, `.truncationMode(.middle)`, 80pt trailing cap. `.firstMatch` is ambiguous — `EndpointEditorView.swift:221` renders the same string. |
| `app.staticTexts["/api/users"]` / `["/api/posts"]` | `MimicUITests.swift:1178-1179`, asserted `:1180 :1182 :1209 :1211` | as above | **label** | may-break | `testSidebarSearchFiltersEndpoints`. The test's own comment concedes it cannot tell the sidebar copy from the editor copy, so "filtered out of the sidebar" is not what it proves. |
| `WorkspacePage.sidebar` | `MimicUITests.swift:97` | `sidebar` — `WorkspaceView.swift:95` | identifier | safe | Dead query, but load-bearing in the negative: this is AGENTS.md rule 8's opening example. Keep the tag and the `.contain` pairing; do not assume the pairing preserves child identifiers. |
| `DSTabStrip` container / `TabButton` | `MimicUITests.swift:113-124`; `JourneyUITests.swift:19-25` | `ds.tabstrip.<id>` — `DSTabStrip.swift:142`; leaf ids `:99,180` | **label** | breaks-readiness-gate | Realized as `ds.tabstrip.navigator` / `.inspector`. Leaf ids (`navigator.tab.endpoints`, `.journeys`, …) never reach the tree. #28 must keep `NavigatorTab.help` strings stable or every journey test loses its entry point. |
| `endpoint-<uuid>` | — | `SidebarView.swift:432` | identifier | safe | Dead as an identifier; tests reach rows by path text. |
| `sidebar.group.<name>` | — | `SidebarView.swift:187` | unknown | safe | Dead. #28's own criterion — "collapse a group, relaunch, assert still collapsed" — needs this reachable. Dump the tree first. |
| `sidebar.noMatches` | — | `SidebarView.swift:156` | unknown | safe | Dead as an identifier; the copy string is the handle. |

### #29 — 52pt toolbar

| Query | Test location | Source identifier | Resolves by | Risk | Note |
|---|---|---|---|---|---|
| `WorkspacePage.toggleDrawerButton` | `MimicUITests.swift:149`; `:670 :984 :992 :999` | `toggleDrawerButton` — `WorkspaceView.swift:253` | identifier | breaks-test | Scoped to `app.toolbars` — breaks if renamed **or** if a `ToolbarItemGroup` reparents it so it is no longer a direct toolbar descendant. |
| `WorkspacePage.toggleInspectorButton` | `MimicUITests.swift:148`; `:668 :966 :971 :974` | `toggleInspectorButton` — `WorkspaceView.swift:263` | identifier | breaks-test | Same scoping fragility. |
| `WorkspacePage.importMenuButton` | `MimicUITests.swift:142`; `:1402 :1405 :1431` | `importMenuButton` — `WorkspaceView.swift:208` | identifier | may-break | Already written defensively across element types (a toolbar `Menu` realizes as `MenuButton` or `PopUpButton` by placement) — #29 changes exactly that placement, and its yield order makes Import lose its word and keep its glyph. |
| `app.menuItems["importHARMenuItem"]` | `MimicUITests.swift:1408-1411` | `importHARMenuItem` — `WorkspaceView.swift:196` | identifier | may-break | Menu items keep their own identity. Safe unless #29 restructures the menu. |
| `app.menuItems["importOpenAPIMenuItem"]` | `MimicUITests.swift:1434-1437` | `importOpenAPIMenuItem` — `WorkspaceView.swift:202` | identifier | may-break | Same. |
| `WorkspacePage.toolbarAddEndpointButton` | `MimicUITests.swift:127`, asserted **absent** at `:677` | none — deliberately removed | identifier | safe | Negative assertion. Fails only if #29's rebuild reintroduces the identifier. |
| `WorkspacePage.toolbarJourneysButton` | `MimicUITests.swift:131`, asserted **absent** at `:679` | none — deliberately removed | identifier | safe | Same shape. |

### #30 — DSServerSegment

| Query | Test location | Source identifier | Resolves by | Risk | Note |
|---|---|---|---|---|---|
| `WorkspacePage.serverToggleButton` | `MimicUITests.swift:110`; `:1247 :1321 :1391 :1472-1481 :1550-1557` | `serverToggleButton` — `ServerToggleButton.swift:58` | identifier | breaks-test | Highest-volume migration in the set. #30 deletes the file and already commits to re-pointing the call sites in the same commit. |
| `WorkspacePage.serverURLText(port:)` | `MimicUITests.swift:172-176` | `serverStatusWell.url` — `ServerStatusWell.swift:107` (running, a copy Button) **and** `:111` (stopped, a Text) | identifier | breaks-test | Matched across element types deliberately: the element changes type with server state. `DSServerSegment` must keep **both** states addressable under one name. |
| `WorkspacePage.waitForServerURL(port:)` | `MimicUITests.swift:188-195`; `:1249 :1323 :1477 :1552` | content from `spokenPrimaryLabel` — `ServerStatusWell.swift:215`, builders `:259`, `:273` | **value** | breaks-test | Double exposure — identifier *and* rendered text. Re-word the address (e.g. `127.0.0.1:<port>`) and the element is found while the assertion fails, reading as a server that did not start. |
| `serverStatusWell` | — | `ServerStatusWell.swift:79` | identifier | may-break | Container, paired with `.contain`. |
| `serverStatusWell.requestCount` | — | `ServerStatusWell.swift:145` | identifier | safe | Dead. #30 keeps the count in the segment's third region; never tested. |
| `serverStatusWell.unmatched` | — | `ServerStatusWell.swift:157` (Button) and `:162` (static) | identifier | safe | Dead. #30's criterion "clicking the unmatched count opens the log filtered to unmatched" needs a test that does not exist. |
| `ds.status.<id>` | — | `DSStatusBadge.swift:56` | unknown | safe | **Zero production call sites** — only `DSComponentPreviews.swift:40-45`. #19 and #30 both retire it. Delete the file; nothing to migrate. |

### #31 — sheets on surfaceElevated

All background/fill work; no structural change. Listed so #31 can assert it broke nothing.

| Query | Test location | Source identifier | Resolves by | Risk | Note |
|---|---|---|---|---|---|
| `NewProjectSheetPage.nameField` | `MimicUITests.swift:80`; `createProjectViaUI:1601-1603`; `JourneyUITests.swift:190-192` | `projectNameField` — `NewProjectSheet.swift:85` | identifier | safe | The canonical "wrapper lends its name" case. **Do not add `.contain`.** |
| `NewProjectSheetPage.portField` | `MimicUITests.swift:81`; `:629 :871 :877-890 :1605-1608` | `serverPortField` — `NewProjectSheet.swift:96` | identifier | safe | |
| `NewProjectSheetPage.createButton` | `MimicUITests.swift:82`; `:874 :883-896` | `createProjectButton` — `NewProjectSheet.swift:121` | identifier | safe | `isEnabled` is the assertion vehicle for the whole port-validation test. |
| `NewProjectSheetPage.cancelButton` | `MimicUITests.swift:83`; `:752 :948-951` | `cancelCreateButton` — `NewProjectSheet.swift:110` | identifier | safe | |
| `NewEndpointSheetPage.nameField` | `MimicUITests.swift:213`; `:694 :1014 :1619-1621` | `newEndpoint.nameField` — `NewEndpointSheet.swift:53` | identifier | safe | |
| `NewEndpointSheetPage.pathField` | `MimicUITests.swift:215`; `:697-699 :1622-1624` | `newEndpoint.pathField` — `NewEndpointSheet.swift:94` | identifier | safe | |
| `NewEndpointSheetPage.createButton` | `MimicUITests.swift:216`; `:700 :1025 :1625` | `newEndpoint.createButton` — `NewEndpointSheet.swift:123` | identifier | safe | **Also carries `.accessibilityLabel("Add endpoint")` at `:124`** — a live competitor for the readiness gate's `.firstMatch` while the sheet is open. |
| `CaptureJourneySheetPage.nameField` | `MimicUITests.swift:354`; `:1293-1298` | `captureJourney.nameField` — `CaptureJourneySheet.swift:69` | identifier | safe | `DSTextField` pattern; must not gain `.contain`. |
| `CaptureJourneySheetPage.createButton` | `MimicUITests.swift:355`; `:1299` | `captureJourney.createButton` — `CaptureJourneySheet.swift:93` | identifier | safe | |
| `NewJourneySheetPage.nameField` | `JourneyUITests.swift:106`; `:323-325 :353-355` | `newJourney.nameField` — `NewJourneySheet.swift:48` | identifier | safe | Same pattern. |
| `NewJourneySheetPage.createButton` | `JourneyUITests.swift:107`; `:326 :356` | `newJourney.createButton` — `NewJourneySheet.swift:72` | identifier | safe | |
| `StepSheetPage.pathField` | `JourneyUITests.swift:117`; `:331-333 :360-363 :370` | `stepSheet.pathField` — `JourneyStepSheet.swift:95` | identifier | safe | Busiest query in the two formerly-skipped tests; the gate proving the sheet presented. |
| `StepSheetPage.statusField` | `JourneyUITests.swift:118`; `:334-336` | `stepSheet.statusField` — `JourneyStepSheet.swift:119` | identifier | safe | Exists only under the `.respond` branch — conditional on picker state. |
| `StepSheetPage.saveButton` | `JourneyUITests.swift:121`; `:337 :364` | `stepSheet.saveButton` — `JourneyStepSheet.swift:220` | identifier | safe | Title flips `"Add step"` / `"Save step"` (`:216`, label `:222`) — a label re-point would need both spellings. |
| `StepSheetPage.validationMessage` | `JourneyUITests.swift:123`; `:367` | `stepSheet.validationMessage` — `JourneyStepSheet.swift:247` | identifier | safe | **Flag to #31:** a plain `Text` in `DSColors.destructive`, not a `DSTextField` error row, so it is outside #31's error-row re-measurement. A second error surface #31 does not currently list. |
| `app.sheets.firstMatch.buttons["Delete"]` | `MimicUITests.swift:1072-1075` | none — `EndpointEditorView.swift:287` | label | safe | |
| `NewScenarioSheetPage.*` (3 members) | `MimicUITests.swift:473-475` | `newScenario.nameField/.createButton/.cancelButton` — `InspectorPanelView.swift:420,444,433` | identifier | safe | All dead — the new-scenario sheet has **no coverage at all**. |
| `NewEndpointSheetPage.methodPicker/.cancelButton/.pathError` | `MimicUITests.swift:214,217,223` | `NewEndpointSheet.swift:83,112`; `DSTextField.swift:104` | identifier | safe | All dead. `createEndpointViaUI` takes a `method` parameter it never uses (`:1617`), so no test creates anything but a GET. |
| `NewProjectSheetPage.portValidationError` | `MimicUITests.swift:84` | `ds.textfield.newProject.port.error` — `DSTextField.swift:104` | identifier | safe | Dead. The sheet's inline error message has zero coverage; the test asserts `createButton.isEnabled` instead. |
| `StepSheetPage.nameField/.holdField/.cancelButton` | `JourneyUITests.swift:116,119,122` | `JourneyStepSheet.swift:82,160,209` | identifier | safe | Dead. `.drop` and `.timeout` outcomes are entirely untested — a gap #41 widens, since it needs defined chips for both. |
| `StepSheetPage.outcomePicker` | `JourneyUITests.swift:120` | `stepSheet.outcomePicker` — `JourneyStepSheet.swift:109` | **element-type** | may-break | Dead **and unverified** — nothing has ever confirmed a segmented SwiftUI `Picker` realizes as an AppKit `radioGroup` on macOS. Per AGENTS.md rule 7, dump the tree before relying on it. |

### #33 — request log header

| Query | Test location | Source identifier | Resolves by | Risk | Note |
|---|---|---|---|---|---|
| `app.textFields["ds.filterfield.sidebar.filter"]` | `MimicUITests.swift:1190`, throughout `testSidebarSearchFiltersEndpoints` | `ds.filterfield.<id>` — `DSFilterField.swift:97`, with `identifier: "sidebar.filter"` — `SidebarView.swift:80` | identifier | breaks-test | **Element type is what separates the field from the scope menu beside it** — both report the same identifier. #33 applies four reversals to this component (magnifier, 5pt rect over Capsule, scope leading→trailing, 21-24pt height where `:89` pins 20). Moving the scope control changes which child AppKit hands the container's name to. Already broke once (AGENTS.md rule 8). |
| `RequestLogDrawerPage.filterField` | `MimicUITests.swift:273`; used **only** at `:1227` as `XCTAssertFalse(exists)` | `drawer.filterField` — `RequestLogDrawerView.swift:433` | identifier | may-break | **Vacuous coverage.** Today a raw `TextField` in a hand-built `HStack` (`:427-435`), inside `DSPanelHeader(identifier: "requestLog")` at `:403` — so the identifier is likely flattened and the negative assertion has been passing for the wrong reason. If #33 adopts `DSFilterField`, the name becomes `ds.filterfield.<id>` — the exact rename the sidebar already paid for, recorded at `:1186-1189`. |
| `RequestLogDrawerPage.methodFilter` | `MimicUITests.swift:276` | `drawer.methodFilter` — `RequestLogDrawerView.swift:421` | identifier | safe | Dead, and likely flattened. #33 restyles the popup and adds a fourth control (`journeyOnly`) plus a collapse order to the same row. |
| `RequestLogDrawerPage.clearButton` | `MimicUITests.swift:279` | `clearRequestLogButton` — `RequestLogDrawerView.swift:449` | **label** | safe | Dead *and* flattened — target `app.buttons["Clear request log"]` (`:448`). #29's criterion "the log's Clear button is hittable at 900×450" cannot be written against this query as it stands. |
| `drawer.unmatchedFilter` | — | `RequestLogDrawerView.swift:386` | unknown | safe | Dead. The app's primary "show me what I am missing" control, zero coverage, and the pairing #17 measures at 3.90:1 in light. #33 switches it to `warningDeep` and adds a `journeyOnly` sibling — both need identifiers and a test. |
| `DSFilterField` inner ids `<id>.field` / `<id>.scope` | `MimicUITests.swift:1186` documents the first as unreachable | `DSFilterField.swift:67`, `:198` | unknown | safe | Dead: the outer container identifier wins. Remove them or pair the container — do not leave both. The scope Menu's per-option `Button(scope.title)` at `:121` carries no identifier at all. |
| `DSClearButton` identifier | — | `DSClearButton.swift:63` | unknown | safe | Realized as `requestDetail.clearBodySearch` and `sidebar.filter.clear`. Neither tested. |
| `WorkspacePage.drawer` | `MimicUITests.swift:100` | `drawer` — `WorkspaceView.swift:659` | identifier | safe | Dead query. Drawer presence is proven entirely through the `"No requests yet"` string. |

### #34 — request log rows

| Query | Test location | Source identifier | Resolves by | Risk | Note |
|---|---|---|---|---|---|
| `RequestLogDrawerPage.firstLogRow` | `MimicUITests.swift:292`; `:1330-1333` | `requestLog-<uuid>` — `RequestLogDrawerView.swift:926` | identifier (**prefix**) | breaks-test | The suite depends on the **prefix**, not the id — a test cannot know a server-minted UUID. It also depends on the row *not* being one element: the identifier is flattened onto six cells (dumped at `:302-307`) and clicking any one selects the row. #34's row rewrite (row view-model, precomputed `displayOrder`, dropped `enumerated()`) must carry the prefix verbatim. |
| `RequestLogDrawerPage.allRowCells` | `MimicUITests.swift:314` | as above | identifier | may-break | Documented to return **six** elements per row. #34 changes the columns (`Endpoint` → `Answered by`, new widths, Scenario retained at 78pt), so the fan-out count changes. `distinctRows` dedupes, so it survives — any assumption about cells-per-row does not. |
| `RequestLogDrawerPage.distinctRows(limit:)` | `MimicUITests.swift:320`; `:1261` | as above | identifier | may-break | Supplies the two rows for the ⌘-click multi-select. #34 commits to keeping multi-row selection (`Set<UUID>`, `WorkspaceView.swift:19`), but the 3pt selection rail replaces the 2pt overlay this selection is drawn by. |
| `RequestLogDrawerPage.waitForRowCount(_:)` | `MimicUITests.swift:337`; `:1257` | as above | identifier | may-break | Counts distinct rows, deliberately. |
| `app.menuItems["Add 2 requests to journey"]` | `MimicUITests.swift:1277-1279` | count-interpolated — `RequestLogDrawerView.swift:887` | **label** | may-break | The assertion that proves ⌘-click reached the app as a modifier. #34 protects the mechanism; nobody owns the wording. |
| `app.menuItems["New journey from these 2 requests…"]` | `MimicUITests.swift:1284-1286` | `RequestLogDrawerView.swift:902` | **label** | may-break | Same. #34's own criterion ("selecting 8 rows still offers *New journey from these 8 requests…*") rests on this string. |
| `RequestLogDrawerPage.logRow(id:)` | `MimicUITests.swift:283` | `requestLog-<uuid>` | identifier | safe | Dead **and it could never have worked** — it queries `otherElements`, but the dump at `:304-308` shows rows realize as Buttons. |
| `requestLog.endpointName.<uuid>` | — | `RequestLogDrawerView.swift:846` | unknown | safe | Dead. The "Answered by" cell. #34 gives `.blockedByJourney` a defined treatment — a fourth outcome with no coverage. |
| `requestLog.scenarioName.<uuid>` | — | `RequestLogDrawerView.swift:854` | unknown | safe | Dead. |
| `requestLog.addToJourney.<uuid>` / `.addToNewJourney.<uuid>` / `.addToJourneyMenu.<uuid>` | — (reached by label) | `RequestLogDrawerView.swift:892`, `:906`, `:908` | identifier | safe | Covered in substance, not by identifier. |

### #36 — inspector mode rail

| Query | Test location | Source identifier | Resolves by | Risk | Note |
|---|---|---|---|---|---|
| `RequestDetailPage.panelTitle(_:)` | `MimicUITests.swift:379` | `ds.panelheader.title.inspector` / `ds.panelheader.inspector` — `DSPanelHeader.swift:51,95`; **strings** from `InspectorPanelView.Mode.title:117-122` | **value** | breaks-test | Highest risk after the gate. #36 replaces the header title with `DSModeRail` ("three text items with a disabled tier and a pin toggle") plus a `DSProvenanceLine`. The four `Mode.title` strings **and** their placement both move. |
| `RequestDetailPage.waitForPanelTitle(_:)` | `MimicUITests.swift:430`; `:1337` (`"Request"`), `:1387` (`"Scenarios"`) | as above | **value** | breaks-test | The mode-change signal for the whole inspector test. |
| `RequestDetailPage.closeButton` | `MimicUITests.swift:396`; clicked `:1385` | `inspector.closeRequestDetailButton` — `InspectorPanelView.swift:163` (never in tree); label `help:` at `:162` | **label** | breaks-test | #36 says it outright: *"The rail replaces it, so that identifier and its coverage move."* The migration handle is the **label string** `"Back to the endpoint inspector"`, not the identifier. |
| `WorkspacePage.autosaveSavedIndicator` | `MimicUITests.swift:155`; `:704`, `waitForAsyncSave:1662-1665` (8 tests) | `autosaveStatus.saved` — `AutosaveStatusIndicator.swift:25` | identifier | safe | Correctly polled with `waitForAny` per rule 9. **#36's own criterion:** pin state must not fire this indicator. |
| `WorkspacePage.autosaveSavingIndicator` | `MimicUITests.swift:158`; `:704 :1662 :1666` | `autosaveStatus.saving` — `AutosaveStatusIndicator.swift:19` | identifier | safe | |
| `InspectorPage.addScenarioButton` | `MimicUITests.swift:440` | `inspector.addScenarioButton` — `InspectorPanelView.swift:202` | **label** | safe | **Doubly dead:** matched by an identifier a `DSPanelHeader` accessory never keeps, and never called. Target `app.buttons["Add scenario"]` (`:201`). #37 also deletes the nested `DSTabStrip` it is grouped with. |
| `WorkspacePage.inspector` | `MimicUITests.swift:99` | `inspector` — `WorkspaceView.swift:172` | identifier | safe | Dead query. |
| `RequestDetailPage.tab(_:)` | `MimicUITests.swift:420`; `:1346` | `RequestDetailTab` raw values — `RequestDetailInspector.swift:8-10` | **label** | safe | Unowned, but note the collision #36 creates: `"Request"` as a rail item and `"Summary"/"Headers"/"Body"` as tabs, two rows of text segments in one panel. |

### #37 — endpoint traffic

| Query | Test location | Source identifier | Resolves by | Risk | Note |
|---|---|---|---|---|---|
| `endpointTraffic` | — | `EndpointTrafficList.swift:132` | identifier | safe | #37's Milestone 0 retires the whole 398-line file. Nothing in the suite ever queried this panel. |
| `endpointTraffic.summary` | — | `EndpointTrafficList.swift:157` | identifier | safe | Deleted with the file. |
| `endpointTraffic.status.<code>` | — | `EndpointTrafficList.swift:205` | identifier | safe | Also one of #19's four hand-rolled status pills (`pill(text:color:isFilled:)` at `:296-310`) — deleting the file removes one duplicate for free. |
| `endpointTraffic.row.<uuid>` | — | `EndpointTrafficList.swift:275` | identifier | safe | Deleted with the file. |
| `ds.empty.endpointTraffic.empty` | — | `DSEmptyState.swift:146` | identifier | safe | Orphaned by the deletion. |
| `InspectorPage.addScenarioButton`'s container | `MimicUITests.swift:440` | nested `DSTabStrip` — `InspectorPanelView.swift:170-207` | label | may-break | #37 (option B) removes `InspectorPanelView.EndpointTab` and `endpointTabBinding`, deleting the strip this button is grouped with. |

### #38 — inspector overview cards

| Query | Test location | Source identifier | Resolves by | Risk | Note |
|---|---|---|---|---|---|
| `inspector.overview` | — | `InspectorOverview.swift:136` | identifier | safe | **Not paired with `.contain`** — so this bare identifier probably stamps over everything beneath it. Pair it or accept label targeting before writing #38's tests. |
| `inspector.overview.<label>` | — | `InspectorOverview.swift:186` | unknown | safe | Likely unreachable for the reason above. Realized as `.project/.endpoints/.journeys/.server/.port/.active/.requests/.unmatched`. #38's criteria ("all values have accessibility labels", plus an XCUITest asserting the counts) need the pairing fixed first. |
| `inspector.overview.openJourneys` | — | `InspectorOverview.swift:102` | unknown | safe | Same problem, **set twice**: `DSButton(identifier:)` at `:100` emits `ds.button.inspector.overview.openJourneys` and the outer modifier at `:102` overrides it. Its label `"Show journeys"` collides with the navigator tab's label — label targeting here needs element-type disambiguation. |

### #39 — DSScenarioControl

| Query | Test location | Source identifier | Resolves by | Risk | Note |
|---|---|---|---|---|---|
| `InspectorPage.scenarioRow(named:)` | `MimicUITests.swift:446`; `:1115 :1128-1137 :1151-1164` | `inspector.scenario.<name>` — `InspectorPanelView.swift:382` | identifier | may-break | Drives three scenario tests. #39 adds a second way to switch scenarios without deleting this list; #36 renames the mode it lives in. |
| `InspectorPage.findScenario(named:)` | `MimicUITests.swift:451`; `:1128 :1137 :1151 :1157` | as above, **falling back to `app.staticTexts[name].firstMatch`** | identifier | may-break | **The fallback is unscoped.** #39 puts the active scenario name in the editor header and #28 proposes it in the navigator row's trailing slot — after either, the fallback can return a control in a different panel and the test right-clicks the wrong thing while reporting success. |
| `InspectorPage.isScenarioActive(named:)` | `MimicUITests.swift:458`; `:1115 :1164` | substring `"active"` from the activeLabel — `InspectorPanelView.swift:363` | **value** | may-break | A content assertion. Re-word the marker (a filled dot, or "In use") and both tests fail while the feature works. |
| `EndpointEditorPage.moreMenu` | `MimicUITests.swift:238`; `:1063-1064` | `endpointEditor.moreMenu` — `EndpointEditorView.swift:282` | identifier | may-break | #39 mounts `DSScenarioControl` "trailing, before the overflow menu" and #25 has already moved the chevrons into the same row. The three-way probe uses non-waiting `.exists` checks, so the chain is only correct once the header has rendered. |
| `app.menuItems["Delete endpoint…"]` | `MimicUITests.swift:1067` | `EndpointEditorView.swift:265`; also `SidebarView.swift:226` | **label** | may-break | Reached through `moreMenu`. Two emitters. |
| `app.menuItems["Duplicate"]` (scenario) | `MimicUITests.swift:1132`, `:1155` | `InspectorPanelView.swift:377` | **label** | safe | `:1155` clicks **without** a `waitForExistence` — the one place in the suite that omits it. |

### #40 — editor response row

| Query | Test location | Source identifier | Resolves by | Risk | Note |
|---|---|---|---|---|---|
| `EndpointEditorPage.statusCodeField` | `MimicUITests.swift:235`; `:1044-1052 :1492-1523 :1544-1547` | `endpointEditor.statusCode` — `EndpointEditorView.swift:338` | identifier (**element type**) | breaks-test | **The headline migration.** Today a `DSTextField` realized as a textField. #40 replaces it with a status control (9pt colour bar, 14pt tabular code, reason phrase, chevron) — AppKit realizes that as `MenuButton`/`PopUpButton`, so `app.textFields[…]` matches **nothing**. Breaks `testEditEndpointStatusCode`, `testEndpointStatusCodePersistsAfterCloseAndReopen`, `testCaptureEvidenceScreenshots`. #40's own review correction names this and requires re-pointing in the same commit. |
| `EndpointEditorPage.waitForStatusCodeValue(_:)` | `MimicUITests.swift:260`; `:1500 :1547` | as above | **value** | breaks-test | An `XCTNSPredicateExpectation` on `.value == "401"`. The replacement renders a code **plus a reason phrase**, so even if an element survives, the predicate does not. |
| `EndpointEditorPage.delayField` | `MimicUITests.swift:236` | `endpointEditor.delay` — `EndpointEditorView.swift:521` | identifier | may-break | Dead. #40's spec puts Delay in the new single control row. |
| `EndpointEditorPage.groupTagField` | `MimicUITests.swift:237` | `endpointEditor.groupTag` — `EndpointEditorView.swift:503` | identifier | may-break | Dead. #40 rewrites the control rows without naming it; it is also what #28's group sections are built on. |

### #41 — journeys template gallery

| Query | Test location | Source identifier | Resolves by | Risk | Note |
|---|---|---|---|---|---|
| `TemplatePickerPage.addButton` | `JourneyUITests.swift:93`; gate at `:224`, commit at `:236` | `journeyTemplate.addButton` — `JourneyTemplatePicker.swift:104` | identifier | breaks-test | **Highest-impact single query in the journeys file.** A click-to-create gallery has no Add button. Its removal fails **4 of 7 tests at the same line**: `testAddJourneyFromTemplateListsItsStepsInOrder`, `testActivatingAJourneyEnablesRunControls`, `testDeactivatingReturnsToEndpointOnlyServing`, `testJourneysSurviveClosingAndReopeningTheProject`. |
| `TemplatePickerPage.activateToggle` | `JourneyUITests.swift:92`; `:232-234` | `journeyTemplate.activateToggle` — `JourneyTemplatePicker.swift:71` | identifier + **value** (`value as? Int == 1`) | breaks-test | #41's criterion preserves the *behaviour* ("optionally activates it, matching today's checkbox behaviour") but names no control. If the checkbox vanishes, `addTemplate(activate:)` silently stops choosing anything and `testDeactivatingReturnsToEndpointOnlyServing` starts from an unknown state instead of failing. |
| `TemplatePickerPage.template(_:)` | `JourneyUITests.swift:96-98`; `:226` (`retry-after-failure`), `:377` (`payment-retry`) | `journeyTemplate-<template.id>` — `JourneyTemplatePicker.swift:61` | identifier | breaks-test | Template ids are stable (they are the CLI's handles; renaming is out of scope for #41), so **the fix is to keep `journeyTemplate-<id>` on `DSTemplateCard`**. Note `:227` guards with `if row.waitForExistence(timeout: 3)` and silently proceeds — a missing card fails later, as the wrong template. |
| `app.menuItems["journeys.templateMenuItem"]` | `JourneyUITests.swift:48`; `:221-222` | `journeys.templateMenuItem` — `WorkspaceView.swift:511` | identifier | breaks-test | #41 retargets this item ("*From template…* opens the same gallery, not a second sheet"). The click still lands; the failure surfaces one line later at `:224` — the confusing kind. |
| `app.menuItems["journeys.newEmptyMenuItem"]` | `JourneyUITests.swift:47`; `:320-321 :351-352` | `journeys.newEmptyMenuItem` — `WorkspaceView.swift:503` | identifier | breaks-test | Survives DSTabStrip flattening because menu items are presented, not embedded. Entry point for both formerly-skipped tests. Survives only if #41 keeps the two-item menu. |
| `app.menuButtons["Add journey"].firstMatch` | `JourneyUITests.swift:42`; `:220 :236 :250 :319 :350` and `waitUntilVisible` | `journeys.addJourneyButton` — `WorkspaceView.swift:528`, label `:529` | **label + element type** | breaks-readiness-gate | Every add path in the file. If the two-item menu collapses to a single add button, `menuButtons` matches nothing and 5 of 7 tests die at the first click. |
| `ds.empty.<id>.heading` | `MimicUITests.swift:104,106,163,280,281` | `DSEmptyState.swift:104` | **value** | breaks-readiness-gate | #41 must not change `"No endpoints"`; it replaces `"No journey selected"` (`CenterPaneView.swift:69-75`). |
| `TemplatePickerPage.list` | `JourneyUITests.swift:91` | `journeyTemplate.list` — `JourneyTemplatePicker.swift:67` | identifier + **element type** | safe | Dead. A 3-column card grid is not an AppKit table; identifier and type both go. Delete it. |
| `TemplatePickerPage.cancelButton` | `JourneyUITests.swift:94` | `journeyTemplate.cancelButton` — `JourneyTemplatePicker.swift:87` | identifier | safe | Dead. Dies with the sheet. |
| `WorkspacePage.centerEmptyHeading` | `MimicUITests.swift:107`; `:656` | `heading:` — `CenterPaneView.swift:48` | **label** | may-break | The **endpoints** centre empty state, in the same file #41 edits, owned by nobody. |

**#41's stated test plan adds a new gallery test and says nothing about re-pointing the four existing ones.** `addTemplate()` at `JourneyUITests.swift:218-237` is four lines of test code that four tests depend on, and #41 deletes all three controls it drives.

### #42 — DSJourneyChip

| Query | Test location | Source identifier | Resolves by | Risk | Note |
|---|---|---|---|---|---|
| `journeyEditor.activeBadge` | `JourneyUITests.swift:57`; `:293` | `JourneyEditorView.swift:134` | identifier | may-break | The assertion that a journey reads as active. #42 scopes the chip to toolbar and navigator sizes and does not claim this pill — so nothing plans to replace it, and nothing plans to preserve it. |
| `journeyRun.progress` | `JourneyUITests.swift:65` | `JourneyRunControls.swift:153` | identifier | safe | Dead. #42's criterion "the chip's label reports the right count" needs a progress readout to assert on — **revive this identifier rather than inventing one**. |

### #43 — journeys navigator

| Query | Test location | Source identifier | Resolves by | Risk | Note |
|---|---|---|---|---|---|
| `ds.empty.journeys.empty` | `JourneyUITests.swift:52-54`; `:247`, `:401`, and inside `waitUntilVisible:80` | `identifier: "journeys.empty"` — `JourneyNavigatorList.swift:67` → `DSEmptyState.swift:146` | identifier | breaks-test | **The only identifier in the journeys file an issue names by name:** #43's criterion is *"either keeps its identifier or the UI suite is re-pointed in this commit"*. Watch `:401` — it asserts **absence** (`XCTAssertFalse`), so a rename makes `testJourneysSurviveClosingAndReopeningTheProject` pass while proving nothing. |
| `journeyRow(named:)` | `JourneyUITests.swift:67-71`; `:407` | row label — `JourneyNavigatorList.swift:292` | **label**, unscoped | may-break | Matches `label CONTAINS <name>` across **every descendant**, then `.firstMatch`, then clicks. Once #41 renders a template gallery in the centre pane, the card titled *"Payment succeeds on retry"* is a competing match — clicking it **creates a second journey** instead of selecting the existing one, and the test still passes. Scope it to the navigator, or match on the `", not active"` suffix. |
| `app.buttons["Add journey"].firstMatch` (empty-state CTA) | `JourneyUITests.swift:45` | `actionTitle:` — `JourneyNavigatorList.swift:66` | **label** | may-break | Unused; exists to document the collision with the menuButton above it. #43 must decide the empty state explicitly, and retitling the CTA silently changes what `app.buttons["Add journey"]` means. |
| `journeys.list` | — | `JourneyNavigatorList.swift:89` | identifier | safe | Dead. #43 restyles the list (active journey → 9pt-radius card, inactive → 34pt rows). |
| `journeys.runControls` | — | `JourneyNavigatorList.swift:215` | identifier | safe | Dead. #43 dissolves this strip into the card. |
| `journeys.restartButton` / `.advanceButton` / `.deactivateButton` | — | `JourneyNavigatorList.swift:158`, `:165`, `:183` | **label** | safe | Dead, and flattened by `ds.panelheader` — reachable only as `"Restart the active journey"` etc. **Note the near-collision** with the tested `journeyRun.*` equivalents: two Advance controls, two Deactivate controls, one of each covered. |
| `journeys.activate.<uuid>` | — | `JourneyNavigatorList.swift:354` | identifier | safe | Dead. #43 replaces the hollow-circle toggle with a 16pt `play.circle.fill`. |
| `journeys.row.<uuid>` | — (test uses the label) | `JourneyNavigatorList.swift:291` | **label** | may-break | #43's card rewrite must keep the journey name in the row's label. |

### #44 — journey run bar

| Query | Test location | Source identifier | Resolves by | Risk | Note |
|---|---|---|---|---|---|
| `RunControlsPage.activateButton` | `JourneyUITests.swift:61`; `:280 :283 :308` | `journeyRun.activateButton` — `JourneyRunControls.swift:107` | identifier | breaks-test | #44 rebuilds the row at 38pt (`DSBarHeight.journeyRunBar`) and names **none** of the five `journeyRun.*` identifiers; its only relevant criterion is "All controls have identifiers and labels", which is satisfied by inventing five new names. |
| `RunControlsPage.deactivateButton` | `JourneyUITests.swift:62`; `:290 :304 :305` | `journeyRun.deactivateButton` — `JourneyRunControls.swift:94` | identifier | breaks-test | **Do not shorten the deliberate 10s wait at `:290`** — activation mutates the project, schedules a save and hands the journey to the engine before the button swaps. |
| `RunControlsPage.restartButton` | `JourneyUITests.swift:63`; `:281 :294 :311` | `journeyRun.restartButton` — `JourneyRunControls.swift:121` | identifier | breaks-test | **Silent-pass hazard — the worst failure mode in the suite.** `:281` and `:311` are `XCTAssertFalse(...isEnabled)`, and `isEnabled` on a **missing** element returns `false`. Rename this identifier and both assertions keep passing against a control that is gone; `testDeactivatingReturnsToEndpointOnlyServing` loses its only real assertion and keeps its green tick. Only `:294` fails loudly. |
| `RunControlsPage.advanceButton` | `JourneyUITests.swift:64`; `:295` | `journeyRun.advanceButton` — `JourneyRunControls.swift:134` | identifier | breaks-test | `XCTAssertTrue(isEnabled)` — fails loudly, unlike restart. Never clicked: nothing in the suite advances a journey. |
| `journeyStep-<index>` | `JourneyUITests.swift:73-75`; `:268` (loop `0..<4`), `:340` | `JourneyStepRow.swift:85` | identifier (**positional**) | breaks-test | The only place the suite proves step **sequence**. #44 replaces `JourneyStepRow` (264 lines) with `DSStepTimeline` and specifies no per-node identifier scheme. A timeline keyed by step UUID cannot be asserted in order without a rewrite — **carry the index-keyed identifier onto the nodes**. |
| `journeyEditor.name` | `JourneyUITests.swift:56`; `waitUntilVisible:80`, `:260 :378 :409`; also `MimicUITests.swift:1303` | `JourneyEditorView.swift:116` | identifier | breaks-readiness-gate | Survives because `center.journeyEditor` (`CenterPaneView.swift:72`) is paired with `.contain` and does not flatten it. Part of the journeys readiness closure **and** the proof that capturing opened the journey (`MimicUITests.swift:1302-1305`). #25 has already reshaped this header; if it becomes a `DSPanelHeader`, this must become a label/value query. |
| `journeyEditor.addStepButton` | `JourneyUITests.swift:58`; `:263 :328-329 :358-359` | `JourneyEditorView.swift:172` | identifier | breaks-test | **Two issues depend on it:** #44's rebuild, and #29's criterion that it stays hittable at 900×450. This is the control from issue #2 — it stayed in the accessibility tree while drawn off-screen, so clicks reported success and the test failed later on a sheet that never opened. If #25/#26 put it into a re-laid-out header, that is the failure mode to expect, and it does not look like a layout bug in the log. Re-point to `app.buttons["Add step"]` (label already set at `:173`, unique in that header). |
| `journeyEditor.stepList` | `JourneyUITests.swift:59` | `JourneyEditorView.swift:408` | identifier + **element type** | may-break | Queried as `app.tables[…]`. If `DSStepTimeline` is a `ScrollView`/`LazyVStack` rather than a `List`, the query stops matching **even if the identifier is kept** — the same trap as `endpointEditor.statusCode`. Delete it or re-point it in #44. |
| `journeyRun.progress` | `JourneyUITests.swift:65` | `JourneyRunControls.swift:153` | identifier | safe | Dead — **nothing in the suite asserts run progress**, so `"Step 2 of 4 — 3 served"` is untested. #44's own test plan (activate `maintenance-window`, serve two requests, assert the cursor held; toggle auto-advance; serve again; assert it advanced) needs exactly this readout. Build on it. |
| `journeyEditor.autoAdvanceToggle` | — | `JourneyEditorView.swift:308` | identifier | safe | Dead today and #44's most consequential control: it **stays inline** in the run bar (it is the switch `maintenance-window` is built around, `JourneyTemplates.swift:174-176`) while the other three move to the popup. The criterion that depends on it has no test. |
| `journeyEditor.matchModePicker` / `.completionPicker` / `.unmatchedPicker` | — | `JourneyEditorView.swift:275`, `:287`, `:299` | identifier | safe | Dead. All three move into the behaviour popup. |
| `journeyEditor.summary` | — | `JourneyEditorView.swift:146` | identifier | safe | Dead. |
| `center.journeyEditor` | — | `CenterPaneView.swift:72` | identifier | safe | Dead as a query, load-bearing as a container — its `.contain` pairing is why `journeyEditor.name` survives. |

### #46 — journey log filter + create-from-log

| Query | Test location | Source identifier | Resolves by | Risk | Note |
|---|---|---|---|---|---|
| `requestLog.createEndpoint.<uuid>` | — | `RequestLogDrawerView.swift:879` | identifier | safe | Dead. #46 rewires this context-menu item through a Domain `mockablePath` + suggested-name rule so window and CLI produce byte-identical endpoints — its criterion needs a test that does not exist. Also adds to the same menu at `:870-878`. |

### #47 — verification sweep

| Query | Test location | Source identifier | Resolves by | Risk | Note |
|---|---|---|---|---|---|
| `app.screenshot()` / `XCTAttachment` | `MimicUITests.swift:1565` | — | n/a | safe | `captureScreenshot` writes six labelled PNGs. The natural consumer of #47's "both appearances at three widths". |
| `runsForEachTargetApplicationUIConfiguration` | `MimicUITestsLaunchTests.swift:12-14` | — | n/a | safe | The only place in the suite that varies configuration at all. Point #47 at this hook rather than building a parallel mechanism. |
| `UITestApp.waitForAny(_:timeout:)` | `AppLaunchSupport.swift:43-46` | — | n/a | safe | The primitive rule 9 mandates and #47 restates. Polls all candidates together at 50ms. Every new query any issue writes goes through this or `waitForExistence`. |
| `launchAndBringToForeground` | `AppLaunchSupport.swift:92-115` | bundle id `devxa.Mimic` at `:14` | n/a | safe | The launch contract rule 6 requires. Callers supply their own readiness closure — which is **why breaking a readiness gate manifests as a launch failure**, not as a missing element. |

### Unaffected — verified, no redesign issue touches them

`WelcomePage.assertVisible:33` · `newProjectButton:15` · `noRecentProjectsLabelByIdentifier:16` · `waitForNoRecentProjectsLabel:46` · `recentProjectRow(named:):54` · `recentProjectText(named:):58` · `findRecentProject(named:):64` · `heroTitleByIdentifier:12` · `heroTitleByLabel:13` · `windowByTitle:14` · `noRecentProjectsLabelByLabel:17` · `DeleteConfirmationPage.deleteButton:512` / `.keepButton:513` · `RequestDetailPage.path:387` (`requestDetail.path` — `RequestDetailInspector.swift:176`) · `.bodySearchField:399` · `.copyCurlButton:402` · `.copyConfirmation:405` · `.responseBody:408` · `.responseBodyMatches:411` · `requestLog.body.request.matches` inline at `:1366` · `.tab(_:):420` · `EndpointEditorPage.addHeaderButton:245` / `.prettyPrintButton:246` / `.headerKeyField:253` / `.headerValueField:256` · `OpenAPIImportPage.emptyHeading:483` · `HARImportPage.cancelButton:493` / `.emptyHeading:496` / `.chooseFileButton:499` / `.importButton:502` · every menu-bar query (`MimicScene.swift`) · `app.menuBars.firstMatch` (`JourneyUITests.swift:204,388`).

Three caveats inside that list: `RequestDetailPage.status:390` belongs to **#19** (one of the four hand-rolled status pills it extracts, `RequestDetailInspector.swift:203,216`) though nothing asserts on it; `.responseBody:408` belongs to **#16** (a fill change at `RequestBodyView.swift:69`); and `windowByTitle:14` makes `WelcomePage.assertVisible` nearly unfalsifiable — it matches whenever *any* window exists, including the workspace.

---

## 4. Orphans

**This section is the point of the exercise.** Three kinds of orphan, in descending order of how much they will cost.

### 4a. Live queries with no owning issue

Every one of these is asserted by a running test and no issue body mentions it.

| Query | Test location | Target | Who is nearest | Why it is orphaned |
|---|---|---|---|---|
| `app.staticTexts["No endpoints"]` | `MimicUITests.swift:104` — **the readiness gate**, 28+7 tests | `SidebarView.swift:89` | **#28** | #28 rewrites `SidebarView.swift` (rows, widths, group headers, trailing slot, selection modifier) and never mentions the `DSEmptyState` at `:87-99`. #41 says `DSEmptyState` is untouched; #43 covers only the journeys one. **Assign to #28 by string.** |
| `app.staticTexts["No requests yet"]` | `MimicUITests.swift:163`, `:280`; asserted `:660 :988 :995 :1001 :1223` | `RequestLogDrawerView.swift:307` | **#33** | The **entire mechanism** of `testToggleDrawerPanel`, which infers drawer visibility from this string appearing and disappearing. #33 rebuilds the header and #34 the rows; neither names the empty state. Two page objects own the same string (`WorkspacePage.drawerEmptyHeading` and `RequestLogDrawerPage.emptyHeading`). |
| `app.staticTexts["No endpoint selected"]` | `MimicUITests.swift:107`; `:656` | `CenterPaneView.swift:48` | **#41** | #41 replaces the *journeys* centre empty state at `:69-75` in the same file and states `DSEmptyState` is untouched. The endpoints one at `:46-51` is unassigned. |
| `"No endpoints match \"<text>\""` predicate | `MimicUITests.swift:1197`; negative assertion `:1200` | `SidebarView.swift:138` | **#28** | #28 rewrites `SidebarView` without naming the no-match string, and its review correction adds filter-match highlighting at `syntax.searchHit` to the same code path. |
| `app.staticTexts["No matching requests"]` | `MimicUITests.swift:281` | `RequestLogDrawerView.swift:313` | **#33** | Dead today — so #33's "type in the filter and assert rows reduce" test has no existing hook to reuse. |
| `app.menuItems["Add 2 requests to journey"]`, `["New journey from these 2 requests…"]` | `MimicUITests.swift:1277`, `:1284` | `RequestLogDrawerView.swift:887`, `:902` | **#34** | #34 protects the multi-select *mechanism* and cites these strings, but does not own the wording, which is count-interpolated. |

### 4b. A query that has never matched anything

| Query | Test location | Reality |
|---|---|---|
| `WorkspacePage.autosaveIndicator` | `MimicUITests.swift:152`, targets `"autosaveStatusIndicator"` | **The identifier does not exist in `Sources/` and never has.** `rg autosaveStatusIndicator` over the whole repository returns exactly one hit: that line. The real identifiers are `autosaveStatus.saving/.saved/.failed` (`AutosaveStatusIndicator.swift:19,25,36`). Harmless only because no test uses the member — if one ever did, it would fail permanently. **Delete it or re-point it.** |

### 4c. Sources identifiers the redesign deletes that no test covers

Nothing to migrate; listed so an issue owner does not spend time preserving them, and so the coverage gaps they represent are visible.

| Identifier | Source | Deleted by | Coverage gap it leaves |
|---|---|---|---|
| `endpointTraffic`, `.summary`, `.status.<code>`, `.row.<uuid>`, `ds.empty.endpointTraffic.empty` | `EndpointTrafficList.swift:132,157,205,275` | #37 | None — the panel was never tested. |
| `ds.status.<id>` (`DSStatusBadge`) | `DSStatusBadge.swift:56` | #19 / #30 | None. Zero production call sites; only `DSComponentPreviews.swift:40-45`. |
| `serverStatusWell`, `.requestCount`, `.unmatched` (×2) | `ServerStatusWell.swift:79,145,157,162` | #30 | #30's criterion "clicking the unmatched count opens the log filtered to unmatched" has no test. |
| `journeys.list`, `.runControls`, `.activate.<uuid>`, `.restartButton`, `.advanceButton`, `.deactivateButton` | `JourneyNavigatorList.swift:89,215,354,158,165,183` | #43 | The navigator's run strip is entirely untested, while its `journeyRun.*` twins are covered — two Advance controls, one covered. |
| `journeyTemplate.list`, `.cancelButton` | `JourneyTemplatePicker.swift:67,87` | #41 | None. |
| `journeyEditor.matchModePicker`, `.completionPicker`, `.unmatchedPicker`, `.autoAdvanceToggle`, `.summary` | `JourneyEditorView.swift:275,287,299,308,146` | #44 | `autoAdvanceToggle` is the switch #44's headline behaviour test needs and it has never been driven. |
| `drawer.unmatchedFilter` | `RequestLogDrawerView.swift:386` | #33 (restyled) | The app's primary "show me what I am missing" control, zero coverage, and the pairing #17 measures at 3.90:1 in light. |
| `requestLog.endpointName.<uuid>`, `.scenarioName.<uuid>` | `RequestLogDrawerView.swift:846,854` | #34 (relabelled) | `.blockedByJourney` is a fourth row outcome with no coverage. |
| `requestLog.createEndpoint.<uuid>` | `RequestLogDrawerView.swift:879` | #46 (rewired) | #46's byte-identical-with-CLI criterion has no test. |
| `sidebar.group.<name>`, `sidebar.noMatches`, `endpoint-<uuid>` | `SidebarView.swift:187,156,432` | #28 (rewritten) | #28's "collapse a group, relaunch, assert still collapsed" needs `sidebar.group.<name>` reachable — verify with a dump first. |
| `inspector.overview`, `.<label>`, `.openJourneys` | `InspectorOverview.swift:136,186,102` | #38 | The parent is **not** paired with `.contain`, so the children are probably unreachable. #38's "assert the counts" test needs that fixed before it can be written. |
| `DSFilterField` inner `<id>.field`, `<id>.scope`; `DSClearButton` ids | `DSFilterField.swift:67,198`; `DSClearButton.swift:63` | #33 | Names that cannot resolve. Remove them or pair the container — do not leave both. The scope Menu's per-option buttons (`DSFilterField.swift:121`) carry no identifier at all. |
| `endpointEditor.addHeaderButton`, `.prettyPrintButton`, `.headerKeyField.<n>`, `.headerValueField.<n>` | `EndpointEditorView.swift:353,478,407,415` | none | The editor's response-headers block is unowned **and** untested. |
| `import.importButton`, `harImport.cancelButton`, empty-state CTAs | `ImportReviewList.swift:206`; `ImportFlowSupport.swift:81,74` | none | The import review list — the 92pt flag-column bug AGENTS.md documents — has **no XCUITest coverage at all**. |

### 4d. Two AGENTS.md violations in the test target itself, owned by nobody

`MimicUITestsLaunchTests.swift:22-23` calls `XCUIApplication(); app.launch()` with **no launch arguments and no launch environment**.

1. It sets neither `-MimicResetForTesting` nor `MIMIC_DEFAULTS_SUITE`, and `UITestSupport` arms its isolation on exactly those two (`Sources/AppFeatures/AppCore/UITestSupport.swift:27`). So `UITestSupport.databaseURL()` returns `nil`, `AppState.swift:173` falls through, and **this test launches the real app against the developer's real `mimic.sqlite` and `.standard` UserDefaults**, on every local and CI run. It does not *delete* anything (the reset needs the argument), but AGENTS.md rule 4 says a UI test run must never **open** it either.
2. It bypasses `UITestApp.launchAndBringToForeground`, which rule 6 makes mandatory. Consequently its screenshot at `:28-31` — the suite's only one — may capture the runner rather than Mimic, because nothing activated the app first.

Fix both as part of **#47**, or delete the file.

---

## 5. Counts

### Total

| | Count |
|---|---|
| Queries inventoried in `MimicUITests.swift` | 100 |
| Queries inventoried in `JourneyUITests.swift` | 52 |
| `.accessibilityIdentifier(` call sites in `Sources/` | 174, across 40 files |
| Page objects | 15 (`MimicUITests.swift`) + 4 (`JourneyUITests.swift`) |
| Tests | 32 (`MimicUITests.swift`) + 7 (`JourneyUITests.swift`) + 1 launch |

### By resolution mechanism

| Resolves by | `MimicUITests.swift` | `JourneyUITests.swift` |
|---|---|---|
| identifier | 63 | 28 |
| **label** | **31** | **13** |
| value / rendered content | 6 | 1 |
| element type alone | — | 4 |
| launch/readiness contract, no element | — | 6 |

The six value-based queries in `MimicUITests.swift` are `recentProjectText:58`, `waitForServerURL`'s localhost check `:191`, `panelTitle:379`, `isScenarioActive:458`, `waitForStatusCodeValue:260`, and the `"No endpoints match"` predicate `:1197`. **Every one of them can fail while the feature works** — those are the rows to re-verify by hand after #30, #36, #39 and #40.

### By risk

| Risk | Count | Where |
|---|---|---|
| `breaks-readiness-gate` | 8 | `"No endpoints"` · `"Add endpoint"` · `WorkspacePage.assertVisible` · `DSTabStrip.TabButton` · `DSPanelHeaderButton` · `journeys.addJourneyButton` · `journeyEditor.name` · `JourneysNavigatorPage.waitUntilVisible` |
| `breaks-test` | 28 | #30 (3) · #36 (3) · #40 (2) · #41 (5) · #44 (6) · #33 (1) · #29 (2) · #34 (1) · #26 (2) · #43 (1) · #25 (1) · #37/#39 (1) |
| `may-break` | 44 | mostly #28, #29, #34, #39, #43, #44 |
| `safe` | ~72 | includes all dead weight |

### Dead weight

**28 page-object members in `MimicUITests.swift` that no test asserts on:** `portValidationError:84` · `sidebar:97` · `centerPane:98` · `inspector:99` · `drawer:100` · `autosaveIndicator:152` · `methodPicker:214` · `NewEndpointSheetPage.cancelButton:217` · `pathError:223` · `delayField:236` · `groupTagField:237` · `addHeaderButton:245` · `prettyPrintButton:246` · `headerKeyField:253` · `headerValueField:256` · `methodFilter:276` · `clearButton:279` · `noMatchesHeading:281` · `logRow:283` · `CaptureJourneySheetPage.cancelButton:356` · `RequestDetailPage.status:390` · `addScenarioButton:440` · `NewScenarioSheetPage` ×3 `:473-475` · `HARImportPage.cancelButton:493` · `chooseFileButton:499` · `importButton:502`.

**8 in `JourneyUITests.swift`:** `window:16` · `showJourneysButton:25` · `addJourneyEmptyButton:45` · `journeyEditor.stepList:59` · `journeyRun.progress:65` · `journeyTemplate.list:91` · `journeyTemplate.cancelButton:94` · `newJourney.cancelButton:108` · plus four `StepSheetPage` members (`nameField:116`, `holdField:119`, `outcomePicker:120`, `cancelButton:122`).

Two are worth knowing specifically: `logRow(id:):283` queries `otherElements`, but the dump at `:304-308` shows log rows realize as **Buttons** — it could never have worked. And `clearRequestLogButton:279` is a `DSPanelHeaderButton` inside a `DSPanelHeader`, so per rule 8 it almost certainly does not keep its identifier.

### By owning issue

| Issue | Queries | breaks-readiness-gate | breaks-test | may-break |
|---|---|---|---|---|
| #25 | 6 | — | — | 4 |
| #26 | 4 | 2 | 2 | — |
| #28 | 8 | 2 | — | 3 |
| #29 | 7 | — | 2 | 3 |
| #30 | 7 | — | 3 | 1 |
| #31 | 22 | — | — | 1 |
| #33 | 8 | — | 1 | 2 |
| #34 | 10 | — | 1 | 5 |
| #36 | 8 | — | 3 | 1 |
| #37 | 6 | — | — | 1 |
| #38 | 3 | — | — | — |
| #39 | 6 | — | — | 4 |
| #40 | 4 | — | 2 | 2 |
| #41 | 10 | 2 | 5 | 2 |
| #42 | 2 | — | — | 1 |
| #43 | 8 | — | 1 | 4 |
| #44 | 13 | 1 | 6 | 2 |
| #46 | 1 | — | — | — |
| #47 | 4 | — | — | — |
| **ORPHAN** | **9** | **1** | — | **5** |
| unaffected | ~30 | — | — | — |

Issues **#13 #14 #15 #16 #17 #18 #19 #21 #23 #24 #27** own no query directly — they are token, colour, geometry and performance work. Two exceptions worth recording: **#19** moves `requestDetail.status` (`RequestDetailInspector.swift:219`) into `DSStatusCodeBadge` even though nothing asserts on it, and **#16** changes the fill behind `requestLog.body.response` (`RequestBodyView.swift:69`), which **is** asserted at `MimicUITests.swift:1349`.

Cut issues **#7 #20 #22 #32 #35 #45** own nothing here.

---

## 6. If only two things get funded

1. **Protect the readiness gate before #26 or #28 lands.** Assign `"No endpoints"` to #28 explicitly, give `assertVisible` a handle verified against an `app.debugDescription` dump, and re-point it in the same commit. Thirty-five tests depend on two English strings that no issue currently promises to preserve, and when they break the failure names the wrong subsystem.
2. **Make #41 and #44 own their query rows the way #30 already does.** #41 deletes three controls that `addTemplate()` drives, failing 4 of 7 journey tests at one line; #44 renames five `journeyRun.*` identifiers, and because two of their assertions are `XCTAssertFalse(isEnabled)`, the suite will go **green** over a control that no longer exists. That silent pass is the worst outcome in this document, and it is the one the current acceptance criteria permit.

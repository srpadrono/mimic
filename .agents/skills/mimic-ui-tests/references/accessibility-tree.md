# What the accessibility tree actually contains

**A container's `.accessibilityIdentifier` overrides its descendants', and `.contain` does not
reliably stop it.** `WorkspaceView` tags the sidebar `"sidebar"`; every element inside it then
reports that identifier instead of its own. The search field only escaped this while it lived
inside a `List`, because list rows form their own accessibility elements — pinning it above the
list made `sidebar.searchField` vanish from the tree and broke `testSidebarSearchFiltersEndpoints`.

Pairing the identifier with `.accessibilityElement(children: .contain)` keeps each child as its
own element carrying **its own label and value**. That is not the same as keeping its own
*identifier*, and treating the two as equivalent has now cost this suite twice. Dumped from
`app.debugDescription`:

```
Button, identifier: 'ds.tabstrip.navigator', label: 'Show endpoints'
Button, identifier: 'ds.tabstrip.navigator', label: 'Add endpoint'      ← set to sidebar.addEndpointButton
StaticText, identifier: 'ds.panelheader.inspector', value: Overview     ← set to ds.panelheader.title.inspector
StaticText, identifier: 'ds.empty.sidebar.endpoints', value: No endpoints
```

All four are inside a container that *is* paired with `.contain`, and all four lost their own
names. Whether the child's identifier survives depends on how SwiftUI collapses that particular
subtree — `sidebar`, `centerPane` and `inspector` do not flatten the containers beneath them, but
a `DSTabStrip`, a `DSPanelHeader` or a `DSEmptyState` flattens its leaves. **So the rule for a leaf
control inside a named container is: target it by label, not by identifier.** Keep setting the
identifier — it costs nothing and it lands whenever SwiftUI does not flatten — but never write a
query that assumes it did without dumping the tree first.

**The other exception, which matters:** when the propagation is the thing you want, do not pair it.
A `DSTextField` tagged `"projectNameField"` forwards that name to the single text field inside it,
which is exactly why `app.textFields["projectNameField"]` matches. Adding `.contain` there turns the
element into a container and the query stops finding a text field at all — that pattern accounts for
most of the sheet coverage in the suite. Pair the identifier when the container holds *several*
things worth addressing; leave it alone when it wraps one control and lends it its name.

**A `.contextMenu` must attach *after* `.accessibilityElement(children: .ignore)`, never beneath
it.** The composition collapses the accessibility of everything below it in the chain, and a menu
attached down there still opens for the pointer — but its items surface through the swallowed
subtree and never exist as elements, so `app.menuItems[…]` matches nothing whatever the menu
shows, and VoiceOver loses the menu outright. The request log's row shipped exactly this: five
consecutive CI runs failed the capture test as "no menu appeared", it read as a flaky modifier,
and the retry iteration resuming *after* the failed test (rather than re-running it) kept the
misreading alive for all five. The scenario row's ordering — form the element, then attach the
menu — is the pattern; `.contain` sites are unaffected because `.contain` keeps its children.

When an identifier mysteriously stops matching, dump `app.debugDescription` and look at what the
element is actually called. `MimicUITests/TreeDumpTests.swift` is not kept in the repo — write a
throwaway test that prints `app.debugDescription` line by line, because the runner is sandboxed and
cannot write the dump to a file.

**And `print()` is not that channel.** A `print` from the runner does not reach the xcodebuild log —
a whole round of injected-import diagnostics was written, shipped to CI, and simply never appeared.
What does come back is the text of an assertion message and an `XCTAttachment`. Put the evidence in
the `XCTAssert…` message, where the "Test failure details" step will read it out.

## A menu item is matched by its `title`, not its `label`

An open pop-up's menu does **not** hang off the pop-up button, and its items carry no label at all.
Dumped from a failure message:

```
Not hittable: MenuItem, {{6.0, 224.0}, {251.0, 24.0}}, identifier: '_restartNowRequested:', title: 'Restart'
```

XCUITest prints `label:` when there is one, and there is none — so a
`matching(NSPredicate(format: "label == %@", …))` over menu items matches **nothing in this app**,
and a query scoped to the button's descendants matches nothing either. `app.menuItems["POST"]` keeps
working because the subscript matches identifier *or* title. Match on `title`, or use the subscript.

The menu bar's own items are the trap in the other direction: the Apple menu contains a "Restart",
so a bare title match can resolve to a system item in a menu that is not even open. A closed menu's
items are not hittable and an open pop-up's are, so hittability is the discriminator **here** — see
the next rule for why that is the only place to trust it.

## `isHittable` is not a reachability gate

Three suites reached for `XCUIElement.isHittable` to prove an element was on screen before clicking
it, and it is not sound in this window. `endpointEditor.groupTagField` reports `isHittable == false`
while a test in another suite clicks that same field, types into it, and watches the jump bar grow a
crumb — passing, in the same CI run in which two tests declared the field "not reachable". SwiftUI
wells report false for controls the window drives perfectly well, so a gate on it fails a working
control and measures nothing.

Use a **behavioural read-back** instead: click, type, then assert the field holds what you typed, or
that the sheet opened, or that the crumb appeared. That catches what the gate was reaching for — a
click landing on whatever happens to be at that point when the card is below the fold — and it
catches it at the click rather than three assertions later as "the value never committed".

## `waitForExistence` is not "it has stopped moving", and a click computes a frame

This is the rule behind the longest-running flake in the suite, and the first two attempts to fix it
were both wrong in the same way.

`waitForExistence` returns when an element enters the accessibility tree. For an AppKit menu that
happens when the menu is **created** — before it is positioned, and while it is still fading in.
`click()` then resolves the element again, takes the frame from that snapshot, and synthesizes an
event at its centre. If the frame is a moment stale, the click lands on the menu's backdrop, the menu
closes, and **nothing happens at all**. The only evidence is the absence of whatever the item was
supposed to produce, which is indistinguishable from the app failing to produce it.

The same applies outside menus, to anything the window is animating. Selecting a request log row
opens the inspector inside `withAnimation(DSAnimation.drawerToggle)`, which narrows the drawer
underneath it and moves every row — so a ⌘-click aimed at the next row can land between two rows and
select nothing, and it presents as the modifier having been dropped rather than as a moved target.

**What went wrong twice.** `testAddingRequestsToAnExistingJourneyFromTheLog` failed waiting five
seconds for the capture sheet on run #91 and passed on the retry, so the wait was widened to fifteen
under a comment explaining that the machine had been busy. Run #98 failed at that same line **twice
in one run** at fifteen seconds. A sheet that is merely slow arrives inside fifteen seconds; the
clock was never the variable. Widening a timeout is what you do when something arrives late — not
when it never arrives.

**What to do instead.** `UITestApp.waitForStableFrame(_:)` polls until an element reports the same
non-empty frame twice, which is the cheapest available statement of "it has stopped". Call it before
any click aimed at something that has just appeared or is being animated. For a nested menu — a
submenu parent, then a child — use `UITestApp.chooseFromSubmenu(in:parent:item:thenAwait:…)`, which
settles both levels, and re-opens the whole menu and tries again if the outcome never comes.

Two properties of that helper worth keeping if it is ever rewritten. It takes the **outcome** as an
argument and every attempt ends waiting for it, so a broken app still fails — the retry removes a
lost click, not a missing sheet. And a retry is recorded with `XCTContext.runActivity`, because it
cannot tell a missed click apart from an app that intermittently fails to present, and the result
bundle is the only place that distinction can be recovered. `print()` is no use for this: runner
output never reaches the xcodebuild log CI reads.

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

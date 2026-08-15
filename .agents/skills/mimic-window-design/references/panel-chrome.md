# Panel chrome

The workspace is three panels around a centre pane: sidebar, request log, inspector. They follow one
set of rules, because they used to follow none and the window read as three unrelated things.

- **Every panel wears one bar of chrome, `DSBarHeight.panelHeader` tall.** Usually that is
  `DSPanelHeader` — one row, title left, controls right, count in the subtitle slot. The navigator is
  the exception: it wears a `DSTabStrip` instead, because the selected tab already names the list and
  a title row repeating it would cost a second 30pt band before the first endpoint. Both are the same
  height, so the three panels' headers still align horizontally. Header buttons are
  `DSPanelHeaderButton` in either — a bare `Image` in a `.plain` button gives an ~11pt hit target.
- **A bar's height comes from `DSBarHeight`, not from a literal.** Four rungs: `panelHeader` 30,
  `secondaryBar` 24, `controlRow` 32, `columnHeader` 22. The window once had ten, most of them
  emergent — a `.padding(.vertical)` around whatever AppKit's small controls happened to measure.
  Nobody chose 31, or 33, or 46. A bar that genuinely fits no rung (the request detail's identity row
  wraps to two lines, so it measures 46–59) stays content-sized and says so in a comment, so the next
  audit does not re-flag it.
- **A control's height comes from `DSControlHeight` and a line weight from `DSStroke`**, for the same
  reason and after the same failure. The rule above about controls sharing a row was being kept by
  hand: `DSButtonSize`, `DSTextField`, `DSFilterField`, `RequestLogDrawerView`'s `HeaderControl` and
  `EndpointEditorView`'s `EditorField` each declared the same 20/22/28 ladder and
  the same 3pt inset privately — two of them across a module boundary, one with a comment promising
  it matched `DSFilterField` "so a panel that later adopts that component does not change shape on
  the way in". Five copies, and nothing checked that the promise held. The line weights were worse:
  twenty-three bare literals — eleven strokes, eight more hand-drawing the closing rule
  `DSDivider` exists to draw, three private constants, and `DSDividerStyle` itself.
  **Every geometry ladder in `DesignSystem` is now pinned by value, not by ordering**, across three
  tests in `Tests/DesignSystemTests/DSComponentRenderingTests.swift`: `laddersArePinned` takes
  `DSBarHeight`, `DSControlHeight` and `DSStroke`, `glyphLadderIsPinned` takes `DSGlyph` and its
  floor, and `tokenValuesStayConsistent` takes `DSSpacing` and `DSCornerRadius`. A chain of `<` cannot
  catch `DSSpacing.md` going from 12 to 10 — every comparison stays true and every panel in the window
  moves — and that sentence used to be this bullet's argument *for* value-pinning while `DSSpacing`
  was the one ladder still held by the chain.

  Two relationships are asserted alongside the values, because both are claims the tokens' own
  comments make: `DSBarHeight.controlRow == DSControlHeight.row + DSSpacing.sm * 2`, and
  `DSControlHeight.verticalPadding == DSSpacing.sm / 2`. `DSAnimation` is deliberately left ordered —
  its rungs are durations, nothing lines up against them, and 0.06 against 0.07 is not a number
  anybody could defend either way.
- **A bar inside a pane takes `DSColors.band`; a panel's own header takes `DSColors.secondary`.**
  Column-header strips, section headers and the jump bar are the first kind. `band` is a tint, not the
  separator — the 0.5pt `DSColors.separator` rule each of them closes with does the separating, at
  ΔL\* ~10 against the band's 1.4–7.3. That is what Xcode's jump bar and AppKit's own table header do,
  and it is why the band being subtle in light mode is not a bug. Never wash the panel surface with a
  fraction of *itself*: `secondary.opacity(0.6)` over `secondary` is `secondary`, which is how the
  request log's column strip spent months being exactly the colour it was trying to differ from.
- **A panel's own controls are not part of its content.** The sidebar's search field used to be the
  first row *inside* the scrolling list, so it scrolled away exactly when a long list made it useful.
  Chrome is pinned above the scroll view.
- **The header stays when the content is empty.** Chrome that disappears with its content reads as a
  rendering glitch, and it made panels align differently depending on what was selected.
- **A panel with nothing to show earns its space or gives it back.** The inspector shows
  `InspectorOverview` — server state, counts, active journey, unmatched traffic — rather than 280pt
  reserved for the words "No selection".
- **Detail belongs in the tall panel, not the short one.** The request log used to split itself when
  you selected a row, which left the detail 74pt — about 11pt of readable body once its own chrome was
  paid for — and cost the list half its rows at the moment you most needed context. Request detail
  goes to the inspector (`InspectorPanelView.Mode`, precedence: request → endpoint → overview) and the
  drawer stays a list. A panel whose height is a user preference cannot also be the place a payload is
  read.
- **Panel geometry is a preference.** Sizes and visibility go through `PanelLayoutStore`, which takes
  an injected `UserDefaults` so a UI test run cannot overwrite a real window arrangement. Never reach
  for `@AppStorage` here: it binds to `.standard` and would do exactly that.
- **Anything a user drags is an `NSSplitViewItem`.** All three resizable panels are now split-view
  panes: the navigator via `NavigationSplitView`, the inspector via `.inspector`, and the request log
  via `DSSplitPane`. They match because they are the same mechanism, not because three sets of numbers
  were matched by hand — which is what the window used to do, and why one divider lit up blue on hover
  while the other two did nothing, one restored a default on double-click while the other two did not,
  and one forgot your size every time you dragged it shut.

  Do not resize a panel with a `DragGesture` writing a `@Binding<CGFloat>` into a `.frame`. That is a
  control loop — the gesture writes state, the state changes layout, the layout re-measures what the
  gesture reads — and SwiftUI promises no ordering between those steps. The old request-log divider
  crashed inside it (`NSInternalInconsistencyException` out of `_postWindowNeedsUpdateConstraints`,
  with the mouse still down), and rewriting it to use absolute pointer position made the loop
  idempotent without removing it.

  Three things `DSSplitPane` documents at length, because each one costs a day if you meet it cold: a
  SwiftUI pane claims every point of its own bounds, so a 1pt divider has no grab target left and will
  not drag at all; a pane holding its thickness above priority 490 outranks AppKit's own drag; and a
  custom `NSSplitView` installed from `loadView` needs `splitView(_:shouldHideDividerAt:)` guarded or
  the app will not launch.

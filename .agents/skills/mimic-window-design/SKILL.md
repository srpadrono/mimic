---
name: mimic-window-design
description: Mimic's visual standard — the window is measured against Xcode. Covers sentence case versus the menu bar, label/value rows, hover states, the `DSGlyph`/`DSBarHeight`/`DSControlHeight`/`DSStroke` geometry ladders, and the SwiftUI layout traps (fixed frames around empty `@ViewBuilder`s, `.fixedSize()` clipping). Use when writing or reviewing any view in `AppFeatures` or `DesignSystem`, adding a `DS*` component, or picking a size, colour, weight or capitalization.
---

# Visual standard

The window is measured against Xcode. Not as a style preference — Xcode is the app this one sits
beside all day, and a mock server that looks like a different generation of software next to it reads
as unfinished. When something here is ambiguous, open Xcode and look at how it solves the same
problem.

- **Sentence case inside the window; Title Case in the menu bar.** "Response headers", never
  "RESPONSE HEADERS"; "New scenario", never "New Scenario". No `.textCase(.uppercase)` in the
  codebase. Two exceptions, both deliberate:
  - `DSMethodBadge` — `GET` and `POST` are uppercase tokens, not shouted prose.
  - **The menu bar.** `MimicScene`'s `CommandMenu` items are Title Case, and that is correct.
    Apple's HIG specifies title-style capitalization for menu items, and Xcode does exactly that —
    its View menu reads "Show Code Review", "Pin Editor Tab", "Change Editor Orientation", "Enter
    Full Screen". Since this app is measured against Xcode, sentence-casing the menu bar would move
    *away* from parity, not toward it. Do not "fix" it.

  Everything drawn inside the window — buttons, alerts, context menus, section headers, empty-state
  copy — stays sentence case. That is the house style, applied consistently, and it is where modern
  Apple practice has moved.
- **Label/value rows put the label right-aligned in a fixed column and the value flush left**, so
  every value in a panel starts at the same x. Two columns pinned to opposite edges with a `Spacer`
  between them is what this replaced, and it read as a spec sheet. The column is sized to the panel's
  own longest label — see `InspectorRowMetrics`, which carries a different width per panel because
  the overview and the request detail are never on screen together.
- **Controls sharing a row share their geometry.** Height, corner radius, border weight and vertical
  padding come from one place, not from four independently written call sites — see the private
  `HeaderControl` enum and `headerControlWell` in `RequestLogDrawerView`. The row there used to carry
  four controls in three shapes at three heights.
- **Every interactive control answers the pointer.** A control that looks identical whether or not the
  pointer is on it is a control you find by trial. This is the defect that recurred most: the server
  toggle — the app's primary action — had no hover state at all, and so did the three copy buttons in
  the request detail, which are the ones a user hunts for. Reach for an existing component before
  hand-drawing one: `DSButton(.ghost, .small)` *is* accent text at 20pt with an `accentSubtle` well,
  and three call sites were spelling it out by hand, each leaving out the hover.
- **A menu needs a disclosure indicator at rest.** `DSFilterField`'s scope control was a bare glyph in
  the position a search field's magnifier occupies, so nothing said it opened anything. 8pt
  `chevron.up.chevron.down` beside the glyph is the idiom here, matching `BreadcrumbJumpBar`'s crumbs.
- **A filled colour swatch is for something that needs attention.** Status codes in the traffic list
  are coloured text; only 4xx and 5xx get a fill. A column of filled pills is a wall of colour that
  says nothing, because everything in it is shouting equally.
- **Nothing a user must read sits at `labelTertiary`.** It is 36% alpha — right for a timestamp or a
  separator, wrong for a control's own label. Unselected tab icons live at `labelSecondary` for this
  reason.
- **No glyph below 8pt, and the size comes from `DSGlyph`.** The ladder is `indicator` 8,
  `inlineSmall` 9, `inline` 10, `control` 11, `controlLarge` 12, `controlProminent` 13, with
  `minimum` 8 as the floor. A 7pt chevron is decoration that happens to be load-bearing.
  `AppFeatures` used to name none of these — two dozen `.font(.system(size: N))` literals instead —
  and now names all but two, both on the welcome window and both commented at the call site with why
  they sit off the ladder. `grep -rn '\.font(\.system(size: [0-9]' Sources` prints exactly those two;
  a third means somebody hand-wrote a rung.
- **A fixed frame around a `@ViewBuilder` that can produce nothing does not reserve its space.** A
  stack drops an `EmptyView` *together with the `.frame(width:)` wrapped around it*, so the column
  silently collapses and every sibling after it shifts by that width. The import review's flag column
  is 92pt and empty on most rows: those rows handed 92pt to the flexible path column that the header,
  whose `Text("")` is a real view, never gave its own — so Name, Status and Size each rendered about
  ninety points right of the title naming them, while Method and Path, being *before* the flexible
  column, lined up perfectly. It reads as the header being wrong rather than the row.

  **A conditional cell in a table needs an `else` that draws something** — `Color.clear` is enough.
  Audit for this by finding every `@ViewBuilder` containing an `if` with no `else`, then checking
  whether its call site wraps it in a fixed frame; that pair is the whole bug.
- **`.fixedSize()` on a string in a row is a latent clipping bug.** It makes the row demand more width
  than its container has, and an `HStack` resolves that by pushing its *leading* edge out of view —
  `DSPanelHeader` rendered "narios" instead of "Scenarios" for exactly this reason. Long strings get
  `.lineLimit(1)` and a truncation mode. Note also that `.layoutPriority(-1)` is not the fix: a
  `Spacer` claims slack at default priority, so a negative one makes the text vanish entirely.

## Panel chrome

The three panels around the centre pane — sidebar, request log, inspector — follow one set of rules,
including the geometry ladders every `DS*` token is pinned to. Read
[`references/panel-chrome.md`](references/panel-chrome.md) before changing a panel header, a bar
height, a divider, a band colour, or anything a user drags.

## See also

`swiftui-pro` governs the SwiftUI API surface itself — modern modifiers, data flow, accessibility
and performance. This skill governs what the window is supposed to *look* like; load both when
writing a view.

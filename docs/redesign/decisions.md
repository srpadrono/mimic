# Redesign decisions

The questions the design handoff left open, and what was decided. Recorded here because the
redesign lands on a long-lived branch: an implementer picking up an issue three weeks from now
needs the answer without reconstructing the argument.

Each section names the issue that owns it. Where a decision overturns something `AGENTS.md` says,
the amended wording is in [§4](#4-agentsmd-rules-ratified-or-amended-9) and has already landed in
that file.

---

## 1. Panel and column width policy (#6)

The design was drawn once at 1487 × 944 and never resized. Three of its centrepiece elements are
wider than the containers they will live in on a normal laptop.

All figures below are **measured**, not estimated — SF Pro and SF Mono advances read back from
AppKit at the specified sizes and weights, not derived from average character widths.

### 1.1 The numbers

**Inspector mode rail** (12pt semibold, 9pt horizontal padding per item):

| Item | Text | With padding |
|---|---|---|
| Request | 48.4 | 66.4 |
| Scenarios | 58.4 | 76.4 |
| Overview | 55.0 | 73.0 |

Plus the active-mode dot (5 + 4 gap), two inter-item gaps (8), the pin (22 + 4) and
`DSPanelHeader`'s horizontal insets (24) — **282.7pt** against a
`PanelLayoutStore.Bounds.minimumInspectorWidth` of **220**. It overflows by 62.7pt, on the first
inward drag, not at some pathological size.

**Request log header**, at the design's stated sizes: title 69.8 · count 27.2 · method popup 86.1 ·
unmatched toggle 102.7 · Clear 43.5, plus dividers, gaps and insets — **394.3pt incompressible**
before the filter field. With the design's fixed 270pt field that is 664.3pt, which saturates the
centre pane at a **1284pt** window. With a flexible field at its 160pt floor it is 554.3pt, which
saturates at **1174pt**.

**Request log row**, with the Latency column cut (see [§2](#2-latency-is-cut-7-20-22-35-45)):
Method 50 + Answered by 120 + Scenario 78 + Status 44 + Time 56 + insets 32 = **380pt fixed**,
down from the 500pt the design specified.

**Navigator path column** at the design's 300pt width, 8pt insets, 44pt method badge, 9pt gap:

| Trailing slot cap | Path gets | `/api/v1/orders/{id}` needs 146.8pt |
|---|---|---|
| 60pt | 163.0pt | fits |
| 90pt | 133.0pt | truncates |
| 120pt | 103.0pt | truncates |

### 1.2 The decisions

**Minimum window content width: 1140pt.** Two independent constraints converge near there — the log
header saturates at 1174 with a flexible filter, and the row's fixed columns plus a readable path
need 1120. 1140 clears both with the inspector at its new floor. Enforced in `MimicScene` (#27), so
the collapsed state is unreachable rather than merely untested.

**`minimumInspectorWidth` rises 220 → 260**, and the pin is deferred (#36). Without the pin the rail
measures 256.7pt, which 260 clears. Raising a floor strands every user whose persisted width sits
between the old and new value, so `PanelLayoutStore` **clamps on read** — with a `PersistenceTests`
case for a stored width below the floor.

Rejected alternative: compacting the rail to icons. `DSTabStrip` already documents why icon-only
works for a two-tab navigator and words do not; the inverse holds here, where three modes need
naming and the panel is the one that changes identity under you.

**Column yield order: Scenario → Answered by → Time.** Method and Path never yield. Path keeps a
**180pt minimum**, which fits `/api/v1/orders/{id}` at 146.8pt with margin.

**Surplus, when a panel is hidden, goes to Path.** Hiding the inspector returns 320pt; every other
column stays at its drawn width. The design's rule that `Answered by` "must never be the one that
truncates" is not implementable as a fixed 120pt column — it is implementable as *last to yield*,
which is what the order above says.

**Header collapse order: Clear label → method popup label → count → filter field to its 160pt
floor.** The filter field is `minWidth: 160, ideal: 270, maxWidth: 320` and stays the sole flexible
control. The design's fixed 270pt is a direct reversal of a documented fix and is not adopted.

**Navigator default 300pt, trailing slot capped at 60pt.** At 90 or 120 the path truncates on
ordinary routes. Where an endpoint has a GraphQL operation, the operation wins the slot over the
scenario name — without it a GraphQL project is a column of identical rows.

---

## 2. Latency is cut (#7, #20, #22, #35, #45)

The Latency column, `DSLatencyBar`, the p95 scale, the inspector's latency row, the Overview card's
median and `mimic log stats` all read a field that does not exist: `RequestLog` has no duration,
`rg -ni latenc Sources/` returns zero hits tree-wide, and `VaporConfigurator.makeLog` measures no
interval.

Adding it is a five-module change — Domain model, engine measurement point, GRDB migration,
control-plane wire format, `redactingCredentials()` — and on a mock server the honest reading is
either the delay the user configured or 1–5ms of in-process Vapor overhead. The design's own
reference mockup shows five of six rows with an empty track.

**Decision: cut, not deferred-with-a-stub.** Five issues closed as *not planned* with the reasoning
attached. Reopen if record mode (#51) ever lands, since that is the only thing that would produce
timings worth charting.

Consequence: the row's fixed columns drop 500 → 380pt, which is what makes a 1140pt window viable.

---

## 3. Liquid Glass (#10)

**The OS owns the chrome it already owns.** Glass on the toolbar and the navigator; opaque
everywhere the user actually works — centre editor, request log, inspector body.

This is what the handoff's own `3c` recommends and what Xcode does on Tahoe. It is also the only
path that is actually supported: on macOS 26 the toolbar and sidebar take the material on recompile
whether or not the app opts in, so "flat opaque `surfaceSidebar`" is a fight with the framework
rather than a design choice.

| Surface | Treatment |
|---|---|
| Toolbar | system material |
| Navigator | system material (sidebar split item) |
| Centre editor | opaque `surfaceContent` |
| Request log | opaque `surfaceContent` |
| Inspector body | opaque `surfaceSidebar` |
| Panel headers | see [§4](#4-agentsmd-rules-ratified-or-amended-9) — rule only on a material host |

**`surfaceSidebar` is therefore not a flat hex for the navigator.** It stays a flat fill for the
inspector body, which is not a sidebar split item.

**Consequence for contrast (#17):** any ratio computed against the navigator's background is an
approximation against the material's substrate, not a measurement. `ContrastTests` must state that
assumption for those pairings rather than asserting a fixed number.

**Consequence for the toolbar (#29):** much cheaper than scoped. There is no flat-colour bleed to
engineer and no `titlebarAppearsTransparent` workaround — the handoff's claim that the bleed "comes
free" from that API is stale, it is the pre-Big-Sur mechanism. Risk re-rated high → medium. Still
open: whether a content-region-centred title is reachable at all; if not, fall back to
window-centred and say so.

---

## 4. AGENTS.md rules, ratified or amended (#9)

**Amended — the band rule.** Was: *"A bar inside a pane takes `DSColors.band`; a panel's own header
takes `DSColors.secondary`."* The handoff deletes `band` and puts every header on
`surfacePanelHeader`. Measured, that puts `#F0F0F2` on `#F1F1F3` — **ΔL\* 0.30**, five times fainter
than the faintest case the current token was ever allowed, and it lands on the navigator's header,
the inspector's header and `DSSectionHeader`.

Resolution: **a panel header on a material or sidebar host takes no fill — the 0.5pt rule below it
does the separating, and the tab or mode pills carry the weight.** `surfacePanelHeader` still
applies where the host is `surfaceContent`. This is what AppKit's own `NSTableHeaderView` does.

**Upheld — the navigator's `DSTabStrip` exception.** Not a contradiction on inspection: the
handoff's navigator header is still a tab row with no title, which is exactly what the rule
describes. The component stays; only the tabs' own styling is in scope (#28).

**Upheld — "detail belongs in the tall panel; the log never splits."** The handoff holds it.

**Amended — `DSBarHeight`.** The rung ladder gains `listRow` 30, `logRow` 28 and `groupHeader` 18 in
a sibling `DSRowHeight` enum, because those are row metrics and not chrome heights, and
`journeyRunBar` 38 as a named value rather than a literal. `secondaryBar` survives with
`DSSectionHeader` as its sole consumer, taking it as a floor.

**Superseded — "every pane's first row starts at y = 52."** Restated as *"whatever the realised
toolbar measures"*, pending #29's prototype. Nobody has configured an `NSToolbar` in this app; 52 is
the design's number, not a measured one.

---

## 5. Handoff contradictions resolved (#8)

- **Header control height: 22pt.** The handoff says 21 twice and 22 six times. `DSPanelHeaderButton`
  is already 22.
- **Colour tiebreak authority: `Sources/DesignSystem/Tokens/DSColors.swift`.** The handoff cites a
  `tokens.json` and an original brief package that are not in the repository or the bundle. For
  method, syntax, ink and line, the source file is the authority and the handoff is annotated as
  describing it rather than superseding it.
- **Spacing and corner radius are *not* unchanged**, contrary to the handoff. It uses three radii,
  seven spacing values and eight type sizes that do not exist in the token files. Owned by #13 and
  #14.
- **The journey progress bar is not "filled up to the cursor."** Under the default
  `orderedPerEndpoint` match mode `JourneyResolver` scans forward, so step 4 can be exhausted while
  the cursor sits on step 2 — the handoff's own `3b` caption is that exact case and would draw one
  segment of four. It reads per-step `isExhausted`.
- **There are four journey behaviour settings, not three.** `autoAdvance` is absent from the handoff
  entirely and is the only one that is a run control rather than a definition; it stays inline in the
  run bar (#44).
- **"De-purple the journeys" is a no-op.** There is no purple. Journeys are already blue at eleven
  call sites; the two purples in the codebase are the PATCH badge and the JSON key colour, both of
  which the handoff preserves. Struck from the build order.

### Wrong about today's app

Corrected so nobody goes looking for code that is not there:

- The request log's context menu has **two** items, not the four the handoff lists. There is no
  "copy as cURL" item (it is in the inspector's copy bar) and no "clear" item (it is a trash button
  in the log header).
- Log selection is **not** single today, and must not become single: capture-into-a-journey acts on
  the whole selection.
- The request log **has** sortable columns. The handoff neither keeps nor removes them; they stay.
- The inspector has a fourth thing the three-mode rail has no room for — the endpoint **Traffic**
  tab, 398 lines. Retired in favour of a count plus a one-click jump into the filtered log (#37).
- `BreadcrumbJumpBar` is never named in 780 lines and was silently deleted along with its group,
  sibling and journey navigation. Handled explicitly in #25.

---

## 6. Landing strategy and funded scope (#12)

**One long-lived branch: `redesign/workspace`.** Merged to `main` when the redesign is complete and
the UI suite is green.

This was not the recommendation — incremental on `main` was — so the tradeoffs are recorded here to
be managed rather than discovered:

| Risk | Mitigation |
|---|---|
| The test migration arrives as one large diff | `docs/redesign/test-inventory.md` landed first; each issue's test edits stay in their own commit |
| The branch drifts from `main` | Rebase weekly; keep bug-fix work on `main` out of the branch |
| CI is not a per-PR gate here | Ignored on this branch by decision; the full suite runs once at the end |

**Testing loop while the branch is live:** unit suites in full per issue; **only the UI tests that
issue affects**, looked up in the test inventory; the entire XCUITest suite once, when every issue
is complete.

### Funded scope

All 43 redesign issues except the latency chain and the sparkline — six closed as *not planned*.
The three capability items (#49 command palette, #50 dynamic responses, #51 record mode) are a
separate epic with no dependency on this work.

### Effort roll-up

| Milestone | Issues | XS | S | M | L |
|---|---|---|---|---|---|
| 0 — Decisions | 6 | 2 | 4 | — | — |
| 1 — Foundations | 10 | — | 6 | 3 | 1 |
| 2 — Chrome & panels | 7 | 1 | 2 | 2 | 2 |
| 3 — Request log | 2 | — | — | 2 | — |
| 4 — Inspector | 3 | — | — | 3 | — |
| 5 — Editor & scenarios | 2 | — | 1 | — | 1 |
| 6 — Journeys | 4 | — | 1 | 2 | 1 |
| 7 — Commands | 1 | — | — | 1 | — |
| 8 — Verification | 2 | — | 1 | 1 | — |

Two issues carry high risk: #16 (the 19 surface judgement calls) and #29 (the toolbar, now medium
after §3). Deferred items are listed in [ROADMAP.md](../ROADMAP.md).

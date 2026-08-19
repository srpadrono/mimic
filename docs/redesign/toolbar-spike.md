# Toolbar spike (#29)

The redesign draws a 52pt unified toolbar with the project title **centred within the content
region** — that is, centred over the editor, not over the window — so that it does not shift when the
navigator is collapsed. This records what is actually reachable.

## The finding, in one line

**The content-region-centred title is not reachable in SwiftUI, and the reason the handoff gives for
wanting it is the argument for the option it did not pick.**

## What was tried

| | Result |
|---|---|
| `.windowToolbarStyle(.unified)` | **Works.** Produces the tall single-band toolbar. Adopted. |
| `ToolbarItemPlacement.principal` | Centres in the **window**, not the content region. No variant is content-region-relative. |
| `titlebarAppearsTransparent` | Not the mechanism any more. It is the pre-Big-Sur approach; the handoff's claim that the sidebar bleed "comes free" from it is stale. On macOS 26 the bleed comes from the toolbar style plus a full-height sidebar split item. |
| Hand-rolled `NSToolbar` with a centred item | Not attempted. It means owning toolbar construction for the whole window to move one label, and it would fight `.inspector`, which installs its own toolbar segmentation. |

## The reasoning the handoff gives is inverted

`README.md:286-287` says the title is centred in the content region *"so that it does not shift when
the navigator is collapsed."*

Content-region centring puts the title at `(W + 300) / 2` with the navigator open and `W / 2` when it
collapses — **a 150pt jump**. Window centring is the option that never moves. The stated reason is an
argument for the choice that was not made.

## Decision

**Window-centred, via the standard title.** It never moves, it is what every other Mac app does, and
it costs nothing.

The redesign's own reference render is a third thing again — measured off `3a`, the title sits at
neither the window centre nor the content-region centre — so there is no drawn intent to honour here
beyond "centred, roughly".

## What was adopted from this issue

- `.windowToolbarStyle(.unified)` — the 52pt band.
- `.defaultSize(width: 1487, height: 944)` — the reference size at first launch.
- The server segment and journey chip in the leading cluster (#30, #42), which is what the toolbar
  was being rebuilt *for*.

## What is deliberately not adopted

- A hand-rolled `NSToolbar`.
- Any attempt to make `surfaceSidebar` a flat fill that bleeds under the titlebar — see
  [decisions.md §3](decisions.md#3-liquid-glass-10). The OS material does this, and fighting it was
  the thing that made this issue high-risk in the first place.

## Still unverified

Nobody has looked at the 52pt toolbar on screen. The display was locked when this landed. Two things
to check: the leading cluster at the minimum 1140pt window with a journey chip present and a long
journey name, and whether the autosave indicator's reserved 54pt still holds its neighbours still at
that width.

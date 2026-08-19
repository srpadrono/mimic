# The workspace redesign, and what became of it

These three documents are a record, not a plan. Read them for the reasoning; do not read them as a
description of the app.

## What happened

A workspace redesign ran on `redesign/workspace` as one long-lived branch, by the branch's own
decision (recorded in [decisions.md §6](decisions.md#6-landing-strategy-and-funded-scope-12)) rather
than incrementally on `main`. That decision carried a stated risk — *"the branch drifts from `main`"*
— with a stated mitigation: rebase weekly. The rebase never happened.

By the time the branch was reviewed, `main` had moved 44,000 lines across 242 files. Forty-eight of
the branch's ninety files had also changed on `main`, and the two trees had independently solved
several of the same problems:

| The branch built | `main` had already built |
|---|---|
| `DSStatusCodeBadge` | `DSStatusPill`, carrying the same 4xx/5xx fill gate |
| `successDeep` / `warningDeep` / `destructiveDeep` | `successText` / `warningText` / `destructiveText` |
| `ContrastTests`, 349 lines | `DSContrastTests`, 1,653 lines |
| literal `0.5` hairlines and `8`pt glyphs | `DSStroke` and `DSGlyph`, which the branch has never seen |

The branch was not merged. What survived was lifted onto `main` piece by piece, on `main`'s design
system rather than the branch's: the two Domain rules (`RequestLogFilter`, `EndpointFromLog`), the
command palette's model, the additive scale rungs, and three components. Each landed as its own
commit saying what it dropped and why.

**The rest is superseded, and the branch is not a backlog.** Anything still wanted from it needs
re-deciding against today's tree, not resurrecting.

## The one document deliberately left behind

`test-inventory.md` mapped every XCUITest query to the issue that changed it. It was scanned against
the branch's working tree, where the UI suite was two files. `main`'s suite is now ten, roughly nine
thousand lines, written against the window the redesign proposed to replace. Every line number, file
map and issue assignment in that document is against a tree that no longer exists, and a stale map is
worse than no map — so it stays on the branch.

## What is still worth reading

- **[decisions.md](decisions.md)** — the measured width policy, why the latency feature was cut, why
  Liquid Glass was declined, and the contradictions in the original design handoff. The measurements
  and the reasoning hold. The issue numbers, the funded scope and the amendments it proposes to
  `AGENTS.md` describe a plan that did not complete — `AGENTS.md` has since been rewritten on `main`
  and is the authority.
- **[toolbar-spike.md](toolbar-spike.md)** — a content-region-centred toolbar title is not reachable
  in SwiftUI, and `titlebarAppearsTransparent` is no longer the mechanism for the sidebar bleed. A
  finding about the framework, so it stays true regardless of the branch.
- **[performance-baseline.md](performance-baseline.md)** — measurements for `RequestLogFilter`, which
  did land, and the correction that the log buffer caps at **1,000** rather than the 10,000 the
  redesign's notes assumed. Any target stated at 10k measures a configuration this app cannot reach.

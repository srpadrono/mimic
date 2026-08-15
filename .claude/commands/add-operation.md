---
description: Add a new operation to the control surface, walking the Definition of Done across all seven places it must land.
argument-hint: [what the operation should do, e.g. "duplicate a scenario"]
---

Add a new operation to Mimic's control surface: **$ARGUMENTS**

This is the repository's most spread-out change — one operation touches `ControlCommand`,
`CommandKind`, `scope`, an executor or the host, two sample lists, `CommandCatalog`, and the CLI.
Missing a place does not always break the build, so work from the checklist rather than from memory.

## Before you write anything

**Load the `mimic-control-surface` skill and follow its Definition of Done.** It is the authority for
this task; everything below is orchestration around it. Read its `references/one-host.md` too if the
operation is host-scoped.

Then answer one question, because it decides half the work: **is this operation a pure function of
the open project, or is it stateful?** Endpoints, scenarios, journeys and project metadata are
`.project` and belong in `ProjectCommandExecutor`. Server lifecycle, project selection, the live
journey cursor and the request log are `.host` and belong in `AppControlHost`. Getting this wrong
means implementing it in the wrong file and having a sweep test tell you so.

Check first whether the operation already exists under another name — `CommandCatalog.descriptors`
is the discoverable list, and 47 operations is enough that near-duplicates are easy to add by
accident.

## Working order

The compiler will drive the first three steps for you: add the `ControlCommand` case, and the build
stays broken until `CommandKind` and `CommandKind.scope` both have it. Follow the errors.

After that the compiler goes quiet and **the tests are what force the remaining work** — both
dispatch switches end in a `default:` that throws at runtime rather than failing to compile. Add the
sample in `HostCommandSweepTests.sample(for:)` (a switch with no `default`, so `MimicTests` will not
compile without it) and in `ControlCommandSamples.all`, then let the sweeps in `DomainTests` and
`MimicTests` tell you what is still unimplemented.

Finish with the `CommandCatalog` descriptor, the CLI subcommand, and a parse test in
`MimicCLICoreTests`. Parse enum-valued options with `try`, never `try?`.

## Before calling it done

- Run the suites: `DomainTests`, `MimicTests` and `MimicCLICoreTests` are the three that cover this
  change. Use `/gates` for the toolchain-free checks — `catalogCoversTheSurface` and the count in
  `check_doc_counts.py` both move when an operation is added.
- **The operation count is written into several documents** and `check_doc_counts.py` reads all of
  them. Adding a command makes every one stale at once; the script prints the new number and names
  each document to change, so run it rather than hunting for them. Update the prose, not the checker.
- Document the verb in [docs/CLI.md](../../docs/CLI.md) alongside its neighbours.
- If any part is unverifiable here (no Swift toolchain), say which and leave it to CI rather than
  implying it ran.

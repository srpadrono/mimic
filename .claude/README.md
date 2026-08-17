# `.claude/` — Claude Code configuration

What is here and why. The repository's actual guidance lives in [AGENTS.md](../AGENTS.md) and the
skills it routes to; this directory is the harness around them.

## `skills/`

Ten symlinks into [`.agents/skills/`](../.agents/skills/), so Claude Code and every other agent read
one copy rather than two that drift. Four are repo-specific (`mimic-build-and-test`,
`mimic-window-design`, `mimic-ui-tests`, `mimic-control-surface`) and were carved out of AGENTS.md
when it grew past 800 lines; four are local Swift guidance; `improve-codebase-architecture` and
`teach` are vendored from `mattpocock/skills` and pinned in
[`skills-lock.json`](../skills-lock.json).

`teach` is not guidance for working on Mimic — it is a user-invoked (`disable-model-invocation:
true`) teaching workspace, and it writes its state into whatever directory it runs in. AGENTS.md
says where to run it and why it appears in the routing table anyway.

Adding a skill means adding the directory under `.agents/skills/` **and** the symlink here. A skill
that exists in only one of the two places is invisible to half the agents that work on this repo —
silently, because nothing fails, the rule is simply never read.

[`Scripts/check_skills.py`](../Scripts/check_skills.py) is what makes that impossible to ship. It
runs in `ci.sh` and in the Linux CI job, and it settles three things: the mirror is complete and is
symlinks rather than copies, every `SKILL.md`'s front matter names its own directory, and AGENTS.md's
routing table covers every skill and points only at real ones. It needs no toolchain, so it also
runs in a web session.

## `hooks/session-start.sh`

Reports what the machine can actually verify, and installs nothing.

Mimic is a macOS app: `xcodebuild`, the XCUITest suite, `tuist generate` and the Release gate all
need a Mac with Xcode. A Claude Code on the web session is a Linux container with no Swift toolchain,
and `download.swift.org` sits outside the environment's network policy, so one cannot be added
either.

The hook exists because of how that gap fails rather than the gap itself. Both Definitions of Done
tell an agent to run the suite before calling the work complete; an agent that cannot, and has not
been told so, either reports `command not found` as though the repository were broken, or silently
skips the step, or writes "tests pass" about a suite that never ran. The hook names the constraint
up front and lists the five gates that *do* run without a toolchain — they were written to need only
the Python stdlib and find/awk/grep precisely so that they could.

On a healthy Mac it prints nothing. It speaks up locally only when a tool is missing or the installed
Tuist has drifted from the version `mise.toml` pins, which is a failure CI has already had.

## `settings.json`

Registers the hook and allowlists the commands this repository runs constantly — the five gates,
`ci.sh`, `xcodebuild`, `tuist`, and read-only `git`.

**Two scripts are deliberately not allowlisted.** `run_cli_e2e.sh` launches Mimic and signals
processes by pid, and `package_release.sh` produces a release artifact. Both are fine to run; neither
should run without somebody saying so that time. If you add an entry here, apply the same test: a
gate that only reads is allowlistable, an action with a side effect outside the working tree is not.

## `commands/`

Slash commands for the two workflows worth encoding — see each file's front matter for what it does
and when to reach for it.

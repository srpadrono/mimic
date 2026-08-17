# CLAUDE.md

Repository guidance for all AI assistants — including Claude Code — lives in a single source of
truth, [AGENTS.md](AGENTS.md). It carries what is true on every task — what Mimic is, the build and
test commands, the module map, and the non-negotiable patterns — and routes the depth to ten skills
in [`.agents/skills/`](.agents/skills/), which `.claude/skills/` symlinks so every agent reads one
copy. Its "Where the rules live" table says which skill to load for what you are touching; load it
rather than working from memory of it.

@AGENTS.md

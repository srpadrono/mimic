#!/usr/bin/env python3
"""The skill layout holds together — symlinks, front matter, and the AGENTS.md routing table.

AGENTS.md was reduced to a router when it passed 800 lines: it now carries what is true on every
task and sends everything else to a skill under `.agents/skills/`. That move traded one large file
for three promises, and a promise nothing checks is the thing this repository keeps discovering it
has already broken.

  1. **`.claude/skills/` mirrors `.agents/skills/`.** Claude Code reads the first, other agents read
     the second, and the mirror is symlinks so there is one copy rather than two that drift. A skill
     added to only one of them is invisible to half the agents that work here — and invisible in the
     quietest possible way, because nothing fails, the agent simply never learns the rule.

  2. **A skill's front matter names it correctly.** `name:` is what an agent matches against, and it
     is written by hand in a file whose directory already says the same thing. When they disagree the
     directory usually wins on disk and the front matter wins in the tool, which is a confusing half
     hour for whoever meets it.

  3. **The routing table is complete and points at real skills.** AGENTS.md's "Where the rules live"
     table is now the only thing standing between an agent and a rule it has never been told. A row
     naming a skill that does not exist sends it nowhere; a skill missing from the table is one it
     will not think to load. Both are silent.

None of the three needs a toolchain — this is directory listings and a little text — so it runs in
the Linux job with the other cheap gates, and in a Claude Code on the web session where nothing
Swift can run at all.

Exits non-zero listing every problem, rather than the first, so one run fixes everything.
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
VENDORED = ROOT / ".agents" / "skills"
MIRROR = ROOT / ".claude" / "skills"
AGENTS = ROOT / "AGENTS.md"

# The heading whose table routes work to skills. Matched rather than hard-coded by line number for
# the obvious reason, and named here once so the error messages can quote it back.
ROUTING_HEADING = "## Where the rules live"


def skill_directories():
    """Every skill on disk, by directory name.

    A directory is a skill if it holds a `SKILL.md`. That is the same test the agent tooling
    applies, so a directory that fails it is not "a broken skill" — it is not a skill at all, and
    saying so precisely is the difference between a useful error and a puzzling one.
    """
    if not VENDORED.is_dir():
        sys.exit(f"{VENDORED.relative_to(ROOT)} does not exist — there are no skills to check.")
    return {p.name: p for p in sorted(VENDORED.iterdir())
            if p.is_dir() and (p / "SKILL.md").is_file()}


def front_matter(skill_md):
    """The YAML front matter of a SKILL.md, as a dict, without a YAML parser.

    Stdlib only, like every other gate in this directory — they have to run before anything is
    installed, in a `swift:6.2` container that ships no PyYAML. The front matter here is flat
    `key: value` pairs, so a real parser would buy nothing but a dependency. Values are taken
    verbatim to the end of the line; nothing in these files needs more.
    """
    text = skill_md.read_text(encoding="utf-8")
    if not text.startswith("---"):
        return {}
    end = text.find("\n---", 3)
    if end == -1:
        return {}
    fields = {}
    for line in text[3:end].splitlines():
        if line.startswith((" ", "\t")) or ":" not in line:
            continue  # nested key (metadata:) or a continuation — not a top-level field
        key, _, value = line.partition(":")
        fields[key.strip()] = value.strip()
    return fields


def routed_skills():
    """Skill names the AGENTS.md routing table points at.

    The table writes each one bold in its "Load" column, so this takes every bold token from the
    section's **table rows** — the lines beginning `|` — and not from the prose around them. The
    prose is where the section explains itself, and it emphasises ordinary words: "a new view is
    `mimic-window-design` **and** `swiftui-pro`" reported a skill named `and` when this read the
    whole section. Narrowing to the rows also states the rule exactly, which is that the table is
    what routes; a skill named only in a sentence has not been routed to.
    """
    text = AGENTS.read_text(encoding="utf-8")
    start = text.find(ROUTING_HEADING)
    if start == -1:
        sys.exit(f'AGENTS.md no longer has a "{ROUTING_HEADING}" section — that table is what '
                 "sends an agent to a skill, so its absence means nothing is routed. Restore it, or "
                 "update ROUTING_HEADING here if the section was deliberately renamed.")
    end = text.find("\n## ", start + len(ROUTING_HEADING))
    section = text[start:end if end != -1 else len(text)]
    rows = [line for line in section.splitlines() if line.lstrip().startswith("|")]
    return set(re.findall(r"\*\*([a-z0-9][a-z0-9-]*)\*\*", "\n".join(rows)))


def main():
    skills = skill_directories()
    problems = []

    for name, path in skills.items():
        # 1. The mirror.
        link = MIRROR / name
        if not link.exists() and not link.is_symlink():
            problems.append(
                f"{name}: no symlink at {link.relative_to(ROOT)} — Claude Code reads that directory, "
                f"so this skill is invisible to it. Fix with:\n"
                f"    ln -s ../../.agents/skills/{name} {link.relative_to(ROOT)}")
        elif not link.is_symlink():
            problems.append(
                f"{name}: {link.relative_to(ROOT)} is a real directory, not a symlink — that is a "
                "second copy of the skill, and the two will drift. Replace it with a symlink.")
        elif link.resolve() != path.resolve():
            problems.append(
                f"{name}: {link.relative_to(ROOT)} points at {link.resolve()}, not at "
                f"{path.relative_to(ROOT)}.")

        # 2. The front matter.
        fields = front_matter(path / "SKILL.md")
        if not fields:
            problems.append(f"{name}: SKILL.md has no readable `---` front matter block.")
            continue
        if "name" not in fields:
            problems.append(f"{name}: SKILL.md front matter declares no `name:`.")
        elif fields["name"] != name:
            problems.append(
                f"{name}: SKILL.md front matter says `name: {fields['name']}`, but the directory is "
                f"`{name}`. An agent matches on the front matter and the tooling finds the file by "
                "directory, so a disagreement resolves differently depending on which one asked.")
        if not fields.get("description"):
            problems.append(
                f"{name}: SKILL.md front matter declares no `description:`. That sentence is the "
                "whole basis on which an agent decides whether to load the skill; without it the "
                "skill exists and is never read.")

    # 3. The routing table, in both directions.
    routed = routed_skills()
    for name in sorted(set(skills) - routed):
        problems.append(
            f'{name}: exists but is not named in the AGENTS.md "{ROUTING_HEADING.strip("# ")}" '
            "table, so nothing tells an agent when to load it.")
    for name in sorted(routed - set(skills)):
        problems.append(
            f'AGENTS.md routes work to "{name}", which is not a skill in '
            f"{VENDORED.relative_to(ROOT)}. Either the skill was renamed and the table was not, or "
            "the row is aspirational.")

    orphans = sorted(p.name for p in MIRROR.iterdir()
                     if MIRROR.is_dir() and p.name not in skills) if MIRROR.is_dir() else []
    for name in orphans:
        problems.append(
            f"{name}: {(MIRROR / name).relative_to(ROOT)} has no matching skill in "
            f"{VENDORED.relative_to(ROOT)} — a dangling link, or a skill deleted from one side only.")

    if problems:
        print("The skill layout has come apart:\n")
        for problem in problems:
            print(f"  - {problem}")
        sys.exit(f"\n{len(problems)} problem(s) across {len(skills)} skill(s).")

    print(f"{len(skills)} skills: mirrored into {MIRROR.relative_to(ROOT)}, front matter names each "
          "one, and the AGENTS.md routing table covers them all.")
    for name in sorted(skills):
        print(f"  {name}")


if __name__ == "__main__":
    main()

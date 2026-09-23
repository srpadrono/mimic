#!/usr/bin/env python3
"""Report live test/command counts and check documentation links and test targets.

Public docs deliberately avoid hand-maintained counts. This gate still catches a test
folder that neither manifest builds, a manifest pointing at a missing folder, and
broken local Markdown links. No Swift toolchain is required.
"""

from pathlib import Path
import re
import sys
from urllib.parse import unquote


ROOT = Path(__file__).resolve().parent.parent
TEST_DECLARATION = re.compile(r"^\s*@Test\b", re.MULTILINE)
UI_DECLARATION = re.compile(r"^\s*(?:@MainActor\s+)?func test[A-Za-z0-9_]*\s*\(", re.MULTILINE)
SUITE_PATH = re.compile(r'"Tests/([A-Za-z0-9_]+)(?:/|")')
MARKDOWN_LINK = re.compile(r"\]\((<[^>]+>|[^)\s]+)(?:\s+\"[^\"]*\")?\)")


def suite_problems(folders: set[str], tuist: set[str], swiftpm: set[str]) -> list[str]:
    problems = []
    for name in sorted(folders - tuist):
        problems.append(f"Tests/{name} is absent from Project.swift")
    for name in sorted((tuist | swiftpm) - folders):
        problems.append(f"Tests/{name} is declared but has no folder")
    for name in sorted(swiftpm - tuist):
        problems.append(f"Tests/{name} is in Package.swift but absent from Project.swift")
    return problems


def local_link_problems(document: Path, body: str) -> list[str]:
    problems = []
    for match in MARKDOWN_LINK.finditer(body):
        target = match.group(1).strip("<>").split("#", 1)[0]
        if not target or re.match(r"^[a-z][a-z0-9+.-]*:", target, re.IGNORECASE):
            continue
        path = (document.parent / unquote(target)).resolve()
        if not path.exists():
            problems.append(f"{document.relative_to(ROOT)}:{body.count(chr(10), 0, match.start()) + 1}: missing {target}")
    return problems


def count_tests(folder: Path, pattern: re.Pattern[str]) -> int:
    return sum(len(pattern.findall(path.read_text())) for path in folder.rglob("*.swift"))


def operation_count() -> int:
    source = (ROOT / "Sources/Domain/Control/CommandKind.swift").read_text()
    enum = source.split("public enum CommandKind", 1)[1].split("\n}", 1)[0]
    cases = re.findall(r"^    case (.+)$", enum, re.MULTILINE)
    if not cases or any("," in case for case in cases):
        raise ValueError("CommandKind cases must appear one per line")
    return len(cases)


def self_test() -> None:
    # Literal negative controls: changing the checker must make these fail.
    assert suite_problems({"Alpha"}, {"Alpha"}, {"Alpha"}) == []
    assert suite_problems({"Alpha"}, set(), set()) == ["Tests/Alpha is absent from Project.swift"]
    assert suite_problems(set(), {"Beta"}, set()) == ["Tests/Beta is declared but has no folder"]
    assert suite_problems({"Alpha"}, set(), {"Alpha"}) == [
        "Tests/Alpha is absent from Project.swift",
        "Tests/Alpha is in Package.swift but absent from Project.swift",
    ]
    assert local_link_problems(ROOT / "README.md", "[good](LICENSE) [bad](missing.md)") == [
        "README.md:1: missing missing.md"
    ]
    print("Documentation checker self-test passed.")


def main() -> int:
    if sys.argv[1:] == ["--self-test"]:
        self_test()
        return 0
    if sys.argv[1:]:
        print("Usage: check_doc_counts.py [--self-test]", file=sys.stderr)
        return 2

    folders = {path.name for path in (ROOT / "Tests").iterdir() if path.is_dir()}
    tuist = set(SUITE_PATH.findall((ROOT / "Project.swift").read_text()))
    swiftpm = set(SUITE_PATH.findall((ROOT / "Package.swift").read_text()))
    problems = suite_problems(folders, tuist, swiftpm)

    documents = [ROOT / name for name in
                 ("README.md", "AGENTS.md", "CLAUDE.md", "CONTRIBUTING.md",
                  "SECURITY.md", "CHANGELOG.md")]
    documents += sorted((ROOT / "docs").rglob("*.md"))
    for document in documents:
        problems.extend(local_link_problems(document, document.read_text()))

    total = sum(count_tests(ROOT / "Tests" / name, TEST_DECLARATION) for name in folders)
    total += count_tests(ROOT / "MimicUITests", UI_DECLARATION)
    print(f"Live counts: {total} test declarations, {operation_count()} command kinds, {len(folders)} test folders.")
    if problems:
        print("\nDocumentation or test-target problems:")
        for problem in problems:
            print(f"  {problem}")
        return 1
    print("Local links and test target declarations are valid.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env python3
"""Copy one appearance's captured screenshots out of an exported .xcresult attachment directory.

Called by `Scripts/capture_doc_screenshots.sh` once per appearance. It lives in its own file rather
than in a heredoc inside that script because the extractor is the part with a trap in it, and a trap
worth a comment is worth a file that can be read on its own.

The trap: `xcresulttool export attachments` names files by attachment id and writes `manifest.json`
mapping them back — but it does **not** hand back the name the test set. An attachment named
`workspace-light.png` comes out with `suggestedHumanReadableName` of `workspace-light_0_<uuid>.png`,
so this matches on the stem rather than on equality. Matching exactly finds nothing, and the script
then reports "did not capture" for images it is holding in its hand.
"""

from __future__ import annotations

import json
import pathlib
import shutil
import sys


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        print(f"usage: {argv[0]} <staging-dir> <appearance>", file=sys.stderr)
        return 2

    staging = pathlib.Path(argv[1])
    appearance = argv[2]
    images = pathlib.Path(__file__).resolve().parent.parent / "docs" / "images"

    manifest = json.loads((staging / "manifest.json").read_text())

    wanted = (f"workspace-{appearance}", f"journeys-{appearance}")
    found: dict[str, pathlib.Path] = {}
    for test in manifest:
        for attachment in test.get("attachments", []):
            name = attachment.get("suggestedHumanReadableName") or attachment.get("name") or ""
            for stem in wanted:
                if name.startswith(stem):
                    found[f"{stem}.png"] = staging / attachment["exportedFileName"]

    missing = {f"{stem}.png" for stem in wanted} - set(found)
    if missing:
        print(f"Did not capture: {', '.join(sorted(missing))}", file=sys.stderr)
        return 1

    images.mkdir(parents=True, exist_ok=True)
    for name, source in sorted(found.items()):
        destination = images / name
        shutil.copyfile(source, destination)
        print(f"    docs/images/{name}  ({source.stat().st_size:,} bytes)")

    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))

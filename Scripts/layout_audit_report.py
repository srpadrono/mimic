#!/usr/bin/env python3
"""Turns the layout audit's frames into a contact sheet and a summary.

`LayoutAuditUITests` writes one folder per test under the audit directory: a PNG per frame and a
`frames.jsonl` line per frame with the window's frame, the panes' insets and the findings. This
script reads every `*/frames.jsonl` and writes:

  - `index.html`: every frame as a thumbnail, grouped by test, with each finding drawn as a box on
    the frame (red for errors, amber for warnings) and listed underneath;
  - `summary.md`: counts per rule and the errors, for the CI job summary.

A thumbnail is used when `thumbs/<image>.jpg` exists (CI makes them with `sips`), else the PNG.

Usage: layout_audit_report.py <audit dir>
       layout_audit_report.py --self-test
"""

import html
import json
import sys
import tempfile
from collections import Counter
from pathlib import Path


def load_frames(root):
    frames = []
    for path in sorted(root.glob("*/frames.jsonl")):
        for line in path.read_text(encoding="utf-8").splitlines():
            if line.strip():
                frames.append(json.loads(line))
    frames.sort(key=lambda f: (f["test"], f["index"]))
    return frames


def rect(value):
    """`CGRect` encodes as `[[x, y], [width, height]]`."""
    (x, y), (w, h) = value
    return x, y, w, h


def summary(frames):
    errors = [(f, x) for f in frames for x in f["findings"] if x["severity"] == "error"]
    warnings = [(f, x) for f in frames for x in f["findings"] if x["severity"] == "warning"]
    rules = Counter((x["rule"], x["severity"]) for f in frames for x in f["findings"])
    lines = [
        "### Layout audit",
        "",
        f"**{len(frames)}** frames, **{len(errors)}** errors, **{len(warnings)}** warnings.",
        "",
    ]
    if rules:
        lines += ["| Rule | Severity | Findings |", "| --- | --- | --- |"]
        for (rule, severity), count in sorted(rules.items()):
            lines.append(f"| {rule} | {severity} | {count} |")
        lines.append("")
    if errors:
        lines.append("Errors:")
        lines.append("")
        for frame, finding in errors[:60]:
            lines.append(f"- {label(frame)}: {finding['message']}")
        if len(errors) > 60:
            lines.append(f"- …and {len(errors) - 60} more")
    return "\n".join(lines) + "\n"


def label(frame):
    _, _, w, h = rect(frame["window"])
    return f"{frame['state']} · {frame['size']} {w:g}×{h:g} · {frame['panels']}"


def page(frames, root):
    sections = []
    for test in sorted({f["test"] for f in frames}):
        cards = []
        for frame in (f for f in frames if f["test"] == test):
            wx, wy, ww, wh = rect(frame["window"])
            thumb = Path("thumbs") / (Path(frame["image"]).with_suffix(".jpg"))
            source = thumb.as_posix() if (root / thumb).exists() else frame["image"]
            boxes = []
            items = []
            for finding in frame["findings"]:
                x, y, w, h = rect(finding["rect"])
                if ww > 0 and wh > 0:
                    boxes.append(
                        '<span class="box {}" style="left:{:.2f}%;top:{:.2f}%;width:{:.2f}%;height:{:.2f}%"></span>'.format(
                            finding["severity"],
                            (x - wx) / ww * 100, (y - wy) / wh * 100,
                            max(w, 2) / ww * 100, max(h, 2) / wh * 100,
                        )
                    )
                items.append(
                    f'<li class="{finding["severity"]}"><b>{html.escape(finding["rule"])}</b> '
                    f'{html.escape(finding["message"])}</li>'
                )
            insets = ", ".join(f"{k} {v:g}pt" for k, v in sorted(frame.get("insets", {}).items()))
            errors = sum(1 for x in frame["findings"] if x["severity"] == "error")
            cards.append(
                f'<figure class="{"bad" if errors else ""}">'
                f'<div class="shot"><img loading="lazy" src="{html.escape(source)}" alt="">{"".join(boxes)}</div>'
                f'<figcaption>{html.escape(label(frame))}'
                + (f'<small>Insets: {html.escape(insets)}</small>' if insets else "")
                + (f'<ul>{"".join(items)}</ul>' if items else "")
                + "</figcaption></figure>"
            )
        sections.append(f'<section><h2>{html.escape(test)}</h2><div class="grid">{"".join(cards)}</div></section>')
    errors = sum(1 for f in frames for x in f["findings"] if x["severity"] == "error")
    warnings = sum(1 for f in frames for x in f["findings"] if x["severity"] == "warning")
    return f"""<!doctype html><meta charset="utf-8"><title>Layout audit</title>
<style>
body{{font:13px -apple-system,sans-serif;margin:24px;background:#f4f5f7;color:#1c1e22}}
.grid{{display:grid;grid-template-columns:repeat(auto-fill,minmax(360px,1fr));gap:16px}}
figure{{margin:0;background:#fff;border:1px solid #d9dce1;border-radius:8px;overflow:hidden}}
figure.bad{{border-color:#d33}}
.shot{{position:relative}} .shot img{{display:block;width:100%}}
.box{{position:absolute;border:2px solid}} .box.error{{border-color:#e02424}} .box.warning{{border-color:#d98b00}}
figcaption{{padding:8px 10px}} small{{display:block;color:#666;margin-top:4px}}
ul{{margin:6px 0 0;padding-left:16px}} li.error{{color:#b01c1c}} li.warning{{color:#8a5a00}}
</style>
<h1>Layout audit</h1><p>{len(frames)} frames, {errors} errors, {warnings} warnings.</p>
{"".join(sections)}
"""


def write_report(root):
    frames = load_frames(root)
    (root / "index.html").write_text(page(frames, root), encoding="utf-8")
    (root / "summary.md").write_text(summary(frames), encoding="utf-8")
    return frames


def self_test():
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        (root / "endpoints").mkdir()
        frame = {
            "test": "endpoints", "index": 1, "state": "endpoint editor", "size": "fill",
            "panels": "navigator, inspector, log", "window": [[100, 50], [1000, 700]],
            "image": "endpoints/001-endpoint-editor.png", "insets": {"centerPane": 16},
            "findings": [
                {"rule": "overlap", "severity": "error", "message": "button 'a' and button 'b' overlap",
                 "rect": [[600, 400], [10, 20]]},
                {"rule": "blank-space", "severity": "warning", "message": "The centerPane pane has a blank band",
                 "rect": [[100, 50], [500, 350]]},
            ],
        }
        (root / "endpoints" / "frames.jsonl").write_text(json.dumps(frame) + "\n", encoding="utf-8")
        frames = write_report(root)
        assert len(frames) == 1, frames
        text = (root / "summary.md").read_text(encoding="utf-8")
        assert "**1** frames, **1** errors, **1** warnings." in text, text
        assert "| overlap | error | 1 |" in text, text
        assert "endpoint editor · fill 1000×700 · navigator, inspector, log: button 'a'" in text, text
        page_text = (root / "index.html").read_text(encoding="utf-8")
        # The overlap box sits 50% across and 50% down the 1000×700 window that starts at (100, 50).
        assert "left:50.00%;top:50.00%;width:1.00%;height:2.86%" in page_text, page_text
        assert 'src="endpoints/001-endpoint-editor.png"' in page_text, page_text
        (root / "thumbs" / "endpoints").mkdir(parents=True)
        (root / "thumbs" / "endpoints" / "001-endpoint-editor.jpg").write_bytes(b"")
        write_report(root)
        assert 'src="thumbs/endpoints/001-endpoint-editor.jpg"' in (root / "index.html").read_text(encoding="utf-8")
    print("layout_audit_report self-test passed")


def main(argv):
    if argv[1:] == ["--self-test"]:
        self_test()
        return 0
    if len(argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    root = Path(argv[1])
    frames = write_report(root)
    print(f"Wrote {root / 'index.html'} and {root / 'summary.md'} for {len(frames)} frames")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

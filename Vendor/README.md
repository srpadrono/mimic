# Vendored packages

Third-party packages kept in this repository, rather than fetched by SwiftPM, because Mimic changes them. Each one keeps its own licence, and every file Mimic changed says so in its header.

## CodeEditorView

- **Upstream:** [mchakravarty/CodeEditorView](https://github.com/mchakravarty/CodeEditorView), tag `0.16.0` (commit `5386056ab53d43363083cb96069715a9608aa048`).
- **Licence:** Apache 2.0, in [CodeEditorView/LICENSE](CodeEditorView/LICENSE).
- **Used by:** `DSJSONEditor` and `DSNativeTextEditor` in `Sources/DesignSystem`.
- **Wired in:** `Tuist/Package.swift` declares it with `.package(path: "../Vendor/CodeEditorView")`. SwiftPM never pins a path dependency, so `Tuist/Package.resolved` has no entry for it. Its own `Rearrange` dependency still comes from GitHub and is pinned there.

### Why it is vendored

The design draws code as SF Mono 12 on a 19 pt line. The line numbers end 12 pt before the code, and the code starts 40 pt into the card (36 pt in the journey step sheet). Release 0.16.0 has no way to set either value:

- The line height is the font's own, 15 pt for SF Mono 12.
- The gutter is always seven characters wide, plus 5 pt of line-fragment padding.

### What changed

Everything is opt-in. With the new values left at their defaults, the editor lays out exactly as upstream does.

- `CodeEditor.swift`: `CodeEditor.LayoutConfiguration` has three new properties, `lineHeight`, `gutterWidth` and `lineNumberTrailingPadding`, and an initialiser that takes them.
  - It now spells out `==` so that equality compares these properties too. `RawRepresentable` would otherwise compare `rawValue`, which still encodes only the two original flags.
- `CodeStorage.swift`: `CodeStorage.lineHeight` sets the minimum and maximum line height of every paragraph style. This covers text that is inserted or restyled later.
- `CodeView.swift`:
  - `tile()` takes the gutter width from `gutterWidth`. That width runs up to where the text starts, so it includes the line-fragment padding.
  - The code view passes `lineHeight` to its code storage when the view is created and again whenever the layout configuration changes.
- `CodeEditor.swift` (macOS): the scroll view sets `autohidesScrollers`, so a legacy scroller is not drawn beside text that fits.
- `GutterView.swift`: line numbers are drawn on the same fixed line height as the code. With a `gutterWidth` set, they end `lineNumberTrailingPadding` before the text.

TextKit puts a fixed line's extra height above the glyphs. `DSJSONEditor` therefore shifts its card padding by 2 pt (8 pt above, 12 pt below) so the text sits where the boards draw it.

### Updating

1. Replace the directory with the new upstream tag.
2. Reapply the changes listed above. Each one is marked `Mimic` in the source.
3. Run `tuist install` and commit `Tuist/Package.resolved`, then run `python3 Scripts/check_lockfiles.py`.

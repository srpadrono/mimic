# Design

The design canvas for Mimic's window, and the images the app is compared against.

- `Canvas/` holds the canvas's artboards (`*.dc.html`) and its layout (`canvas.json`). Each artboard is plain HTML and CSS whose only template value is `{{theme}}`, `dark` or `light`. `WorkspaceLight` is `Main` in the light theme and is not exported separately.
- `Reference/sections.json` names every board, its size in points, its themes, and the rectangle each UI section occupies on it.
- `Reference/*.png` are the boards rendered at 2x by `swift Scripts/export_design_references.swift`, one per board and theme (`Main-dark.png`, `Main-light.png`, `Tokens.png`).

Run the exporter on a Mac after changing an artboard, and commit the images it writes. It uses WebKit so the references are set in SF Pro, like the app. It draws at a true device scale of 2 on any display, and stops without writing anything if a 0.5 px probe line doesn't come out one device pixel high. Pass board names to export only those: `swift Scripts/export_design_references.swift Main Journeys`.

The `MimicGallery` app and `DesignFidelityTests` read these files; see [Working on one section](../docs/ARCHITECTURE.md#working-on-one-section).

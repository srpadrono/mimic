# Window polish screenshot evidence

Captured on 20 September 2026 from the real Mimic app using the isolated, synthetic
Acme Storefront fixture. These are unedited XCUITest window captures, not mockups.
Both images are 960 × 540 pixels in light appearance.

Source: passing focused test
`DocScreenshotTests/testCaptureWorkspaceAndJourneys()` in
`/tmp/mimic-ui-polish-light-20260920.xcresult`. Captured app sources match commit
`2dc9fd8`; no full UI suite or CI checks were run for this evidence update.

## Endpoint workspace

Shows compact toolbar/status controls, grouped sidebar and search, breadcrumb
navigation, endpoint editor, scenario inspector, and populated request log with
its adaptive two-row controls.

![Compact endpoint workspace](workspace-light.png)

## Journey workspace

Shows journey navigation, wrapped behavior controls, active run progress, step
list, populated request log, and the project overview inspector when Journeys is
selected. The fixture has served two journey steps.

![Compact journey workspace](journeys-light.png)

These screenshots document the visible states above. They do not claim coverage
of every dialog, animation, or window size; those checks are described separately
in PR #78.

## Adaptive navigation and taller search fields

The following later capture shows the updated 26-point navigation buttons and
search fields. The navigator uses icons at 240 points and icon-and-title buttons
at 340 points; the panel header keeps its 30-point height in both states.

The focused navigation UI test verifies navigation and button height and captures
the real app window with an isolated synthetic project. The compact/expanded
transition was verified separately in the live app at 240 and 340 points; the
XCUITest pointer drag did not reliably move the native divider, so it is not used
as evidence of resizing. Source result bundle:
`/tmp/mimic-navigation-screenshot-final.xcresult`.

![Updated navigation and taller search](navigation-updated.png)

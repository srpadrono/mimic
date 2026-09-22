# Design-system conformance review

Captured from the Debug macOS app on 2026-09-22 with isolated XCUITest projects. The final focused run passed all 12 UI flows; 75 design-system and import-row contrast tests and all 11 house rules also passed.

An independent design review checked hierarchy, spacing, color meaning, and narrow-window behavior. The follow-up aligned editor and panel headers, navigator rows, form sections, status badges, and request-log controls. It also made pending listener ports and stopped journeys read honestly, and kept Method, Path, Status, and Time visible in the compact log.

## Workspace and navigator

![Welcome empty state](welcome.png)

![Grouped journeys in a compact dark workspace](journeys-narrow-dark.png)

![Journey editor in a wide light workspace](journeys-wide-light.png)

![Journey editor in a compact light workspace](journeys-narrow-light.png)

![Endpoint inspector and compact request log](endpoint-inspector-narrow-light.png)

![Request details in the compact inspector](request-detail-narrow-light.png)

## Editing sheets

![Two-backend server settings](server-settings.png)

![Invalid local port with Apply and Copy URL unavailable](server-settings-invalid-port.png)

![Changed local port pending a server restart](server-settings-pending-restart.png)

![Journey step editor](journey-step-sheet.png)

![HAR import review with a duplicate route](import-review.png)

![Update sheet](update-sheet.png)

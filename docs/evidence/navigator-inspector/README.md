# Navigator and inspector review

Captured on 2026-09-22 from the actual Debug app with isolated XCUITest demo projects. These are screenshots, not mockups.

The navigator uses shared row spacing and icon columns, counts beside group names, native tabs, and persistent bottom filters. The inspector separates journey selection from the active run and preserves traffic scroll position when returning from request details. Wide and narrow layouts were inspected.

Local validation before synchronization with main: Debug build; 240 selected unit tests and 17 distinct focused UI tests passed across verification runs. The final corrective checks passed 12 rendering tests and the narrow-window UI regression. House rules, documentation counts, UI shard coverage, and whitespace checks passed. This is focused local evidence, not a full-suite or release claim.

## Endpoints, wide

![Endpoints, wide](navigator-endpoints-wide.png)

## Endpoints, narrow

![Endpoints, narrow](navigator-endpoints-narrow.png)

## Journeys, wide

![Journeys, wide](navigator-journeys-wide.png)

## Journeys, narrow

![Journeys, narrow](navigator-journeys-narrow.png)

## Selected journey and active run

![Selected journey and active run](inspector-journey-selection-and-run.png)

## Journey inspector, narrow

![Journey inspector, narrow](inspector-journey-narrow.png)

## Traffic list

![Traffic list](inspector-traffic-scrolled.png)

## Request body

![Request body](inspector-request-body-wide.png)

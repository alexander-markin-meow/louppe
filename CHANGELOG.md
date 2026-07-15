# Version History

Every public Louppe update is recorded here. The version and build number used
by the app are defined in `VERSION`; `build_app.sh` verifies that the marketing
version and build number have a matching entry below before it creates a
release bundle.

## 1.5.0 (7) — 2026-07-15

- Expanded filtering with automatic date and exposure ranges, specific capture
  dates, aperture, shutter speed, and ISO controls.
- Added sorting by every available filter facet, with capture date as the
  default.
- Made Specific Dates reveal its checklist immediately, without a redundant
  nested disclosure.
- Added All Photos, Filtered, and Selected scopes for rating-based Clean Up.
- Added a complete multi-selection summary to the Info panel.
- Refined disclosure behavior, toolbar organization, thumbnail rounding, and
  persistent Browser and Grid scrollbars.
- Improved Grid scrolling performance and added confirmation before clearing
  many ratings.
- Added a Cancel Scan toolbar control and Escape shortcut that stop the active
  folder scan, discard partial results, and return to the start screen.
- Added the scanned folder's name, full path, and localized running photo count
  to the scanning window.
- Hardened zero-result filtering so hidden photos cannot receive ratings or be
  passed to selection-based Clean Up, and reduced redundant filter work while
  typing camera-setting ranges or rebuilding folder metadata.

## 1.4.0 (6) — 2026-07-15

- Hardened scanning, filtering, caching, persistence, and Clean Up performance.
- Refined the metadata panel and Clean Up confirmations.
- Renamed the primary views to Gallery and Grid and simplified the toolbar.

## 1.3.0 (5) — 2026-07-14

- Added recoverable Clean Up actions that move files to the macOS Trash.
- Added multi-selection and batch rating.
- Added Undo for ratings and Clean Up operations.

## 1.2.0 (4) — 2026-07-13

- Added photo sorting.
- Added camera and lens filtering.

## 1.1.0 (3) — 2026-07-12

- Added Louppe's purple brand accent throughout the interface.
- Expanded file filtering and polished loading and About behavior.

## 1.0.1 (2) — 2026-07-12

- Replaced the app icon with the glyph-only design on a system-standard
  background.

## 1.0.0 (1) — 2026-07-12

- First public Louppe release.
- Established the native macOS photo-culling workflow and Louppe identity.

# Version History

Every public Louppe update is recorded here. The version and build number used
by the app are defined in `VERSION`; `build_app.sh` verifies that the marketing
version and build number have a matching entry below before it creates a
release bundle.

## 1.7.0 (9) — 2026-07-21

- Clearing all ratings in a large folder is now instant. Previously every
  photo triggered its own full refresh, which could freeze the app for
  seconds and leave stale ✓/✗ badges in the Browser column. The same fix
  speeds up rating a large selection (⌘A then F/D) and undoing such a batch
  with ⌘Z.
- Fixed the Browser column freezing its contents in long sessions: thumbnails
  could keep old ✓/✗ badges (most visibly after Clear All Ratings) and the
  purple current-photo frame could sit on the wrong thumbnail until the view
  was switched to Grid and back. Each strip row now tracks the session
  directly, so badges and the frame always match what's on screen.
- Clicking a thumbnail in the Browser no longer scrolls the strip to center
  that thumbnail — the list stays put under the cursor. Keyboard navigation
  (F/D, arrows, Space) still follows the current photo as before.
- After a long jump (for example F/D advancing to a far-away undecided
  photo), the Browser now lands centered on the current photo reliably
  instead of stopping slightly off-target in big folders.

## 1.6.0 (8) — 2026-07-17

- The toolbar sort menu is now a full popover matching the filter's look, with
  **Sort by**, **Order**, and a new **Groups** section.
- Group division now follows the active sort option: sorting by camera divides
  the photos into camera groups, by subfolder into subfolder groups, and so on
  (Name sorting shows one continuous list). A **Divide into groups** checkbox
  turns the division off entirely.
- Group dividers now carry the group's name: the Grid and the Browser column
  show the date, camera, lens, or other group label at the start of the line,
  with the divider continuing after it.
- All dates and times shown in the app (info panel, selection summary, filter
  day list, group dividers) now follow the Mac's Language & Region settings,
  including the custom **Date format** picker and the 12/24-hour clock.
- Added subfolder support to filtering and sorting: the filter popover lists
  every subfolder of the opened folder (plus **None** for files lying directly
  in it) as checkboxes with photo counts, and the sort menu gains a
  **Subfolder** option between Name and File type.
- The Browser toggle now appears in the toolbar only while the Gallery view is
  showing, and the Q shortcut is ignored in the Grid view — the Browser column
  exists only in the Gallery.
- In the Gallery view, ↓ now steps to the next photo and ↑ to the previous
  one, mirroring the top-to-bottom order of the Browser column. The Grid view
  keeps its row-by-row ↑/↓ movement.
- In the filter popover, **Subfolders** now sits below **File types** and
  starts collapsed.
- Opening a folder is much faster: photo details (EXIF) are now read on
  several CPU cores at once instead of one file at a time — nearly 3× quicker
  in benchmarks, with more expected on large cards.
- The Grid view fills its thumbnails about twice as fast (thumbnails got their
  own decoding lane), and the big Gallery photo no longer waits in line behind
  thumbnail work.
- Removed hidden per-keystroke layout work in the always-visible scrollbars
  and a small group-divider slowdown introduced by the sort update, keeping
  rating and navigation snappy in large sessions.
- Repaired the logic-check script, which had stopped compiling after the sort
  update.

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

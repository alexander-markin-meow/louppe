# Version History

Every public Louppe update is recorded here. The version and build number used
by the app are defined in `VERSION`; `build_app.sh` verifies that the marketing
version and build number have a matching entry below before it creates a
release bundle.

## 1.7.0 (9) — 2026-07-29

- Smoothed fast culling and large-folder opening. Transient key-repeat photos
  no longer immediately start EXIF, histogram, or clipping-warning work;
  Browser row identities are reused between structural changes; known photo
  formats avoid repeated system type detection; and the prepared session index
  reuses the scanner's exact default order instead of sorting the full folder
  a second time on the main UI thread. Rating one photo now updates only its
  tiny per-file decision record instead of copying every photo's scan metadata;
  the 100,000-item performance check dropped from 20.5 ms to about 0.2 ms.

- Added a photo-only luminance histogram to the Info panel, including
  near-black and near-white percentages with red warnings when either exceeds
  10%. Gallery clipping inspection can now be toggled with **X** or the Info
  panel button, painting the matching pixels red in Fit, phone-size, and true
  100% tiled views without allocating a whole full-resolution bitmap. Videos,
  unsupported files, and multi-selections omit the complete histogram section.

- Made the RAW+JPEG switch reproject the current session instead of rescanning
  the source folder. The first split reads metadata only from hidden JPEG
  partners, and subsequent toggles reuse it instantly. Ratings now persist per
  physical file; conflicting RAW/JPEG decisions appear as Mixed, can be
  restored by splitting again, and are protected from rating-based Clean Up
  until the pair is resolved.

- Simplified the File types filter by removing the explanatory line beneath
  **Keep RAW + JPEG together**.

- Made the main review workflow usable without color or pointer-only
  gestures. Browser and Grid items now announce their filename, media type,
  rating, current/selected state, and offer VoiceOver actions to open, rate,
  or select them. Icon-only toolbar controls also announce their purpose and
  changing state explicitly.

- Made **100%** a true source-pixel view on both standard and Retina displays.
  Louppe now keeps its fast preview visible while rendering only the visible
  full-resolution tiles, with a strict 128 MiB tile-cache limit instead of
  decoding an entire very large photo. Panning also follows the same relative
  image position while arrows, rating, Space, or the Browser move between
  files; pressing S again resets the next 100% view to the center.

- Added secure automatic updates. Louppe checks daily, downloads verified
  releases in the background, installs them safely on quit, and offers a
  manual **Check for Updates…** command plus Settings toggles for automatic
  checks and downloads. Both the update feed and archive are cryptographically
  signed, and archives are verified before extraction.

- Made Export safer for RAW+JPEG pairs. Copy and Move now reserve one matching
  collision suffix for both files, partial Copy failures roll back the first
  file, and Copy can be stopped without leaving half a pair. Active copies also
  block Quit, folder changes, and update installation until they finish or
  stop safely. Export now rejects destinations inside the reviewed folder and
  checks write permission and available space before starting.

- Added crash- and power-loss recovery for Copy, Move, Clean Up, and Clean Up
  undo. Each file change now has a durable checkpoint tied to the exact volume
  and file identity. On the next launch Louppe safely removes incomplete copies
  or restores originals before opening a folder, never overwrites an existing
  file, and offers Retry Recovery when a drive is unavailable.

- Adopted Swift 6 language mode with complete concurrency checking. Scanner
  chunk collection, export callbacks, video metadata reads, and playback
  observer cleanup now have explicit thread-safe ownership.

- Made RAW+JPEG pairing deterministic across rescans and preserved distinct
  case-only basenames on case-sensitive volumes.

- Removed the silent five-level scan cutoff. Legitimately deep photo folders
  are now scanned while symbolic-link directories are explicitly skipped to
  prevent loops.

- Corrected Info-panel counts and sizes for RAW+JPEG pairs. Multi-selection
  now distinguishes selected photos/media items from the underlying file
  count, and paired metadata shows both component sizes plus the total.

- Made rating persistence observable and recoverable. Louppe now keeps a
  current Application Support backup, loads whichever valid snapshot is
  newest, warns when a folder is read-only or neither save destination works,
  and offers an inline Retry Saving action. Corrupt, mismatched, unsafe, and
  unsupported-version session files are left untouched instead of silently
  replaced.

- Folder switching, rescanning, pairing-mode changes, Close Session, and Quit
  now wait asynchronously for the newest ratings to reach the folder or
  backup. Quit offers retry/cancel/explicit quit-without-saving choices on a
  total save failure instead of blocking the main thread.

- Added an automatic release-package preflight. Every release build now
  verifies the app and archive signatures, versions, Sparkle framework and
  security keys, feed structure, and archive extraction; publishing mode also
  verifies the feed/archive cryptographically and checks all enclosure data.
- Added a least-privilege macOS 26 GitHub Actions gate for strict Swift 6
  compilation, unit/logic/scrollbar/video checks, and release packaging. It
  requires no private updater key; real Trash round trips remain a local
  release check.

- Added first-class video review using native macOS playback. Videos now use
  their first frame as the thumbnail, always show their duration in the
  Gallery Browser and Grid, open with the full native player in Gallery, and
  play inline in Grid with a single play/pause control.
- Video support follows the movie types and codecs available to AVFoundation
  on the Mac. Recognised movies that macOS cannot decode remain visible,
  rateable, filterable, and exportable with a clear unsupported message.
- Filtering and sorting now understand mixed media: filter Photos/Videos and
  video duration, or sort/group by media type and duration. Video metadata,
  RAW+JPEG pairing, first-frame caching, and one-player-at-a-time behavior are
  covered by focused regression checks.
- Fixed video-player focus intercepting Louppe's review hotkeys. Arrow keys
  always move the current item (including Grid rows), and the Grid play/pause
  control no longer also triggers the tile's rating gesture.
- Space now plays or pauses the current video in Gallery or Grid. It retains
  its previous next-item behavior when the current item is a photo.
- Stabilized Gallery playback controls when moving rapidly between videos.
  Louppe now preserves the native player view and uses AVKit's anchored inline
  control pane instead of rebuilding a floating pane for every selection.
- Fixed the Browser's purple current-item indicator disappearing after the
  selected video was moved to Trash or moved during export. Browser rows now
  follow stable media IDs rather than reusing a removed item's numeric index.

- Clearing all ratings in a large folder is now instant. Previously every
  photo triggered its own full refresh, which could freeze the app for
  seconds and leave stale ✓/✗ badges in the Browser column. The same fix
  speeds up rating a large selection (⌘A then F/D) and undoing such a batch
  with ⌘Z.
- Keyboard navigation, range selection, prefetch, and the toolbar position no
  longer scan the full visible photo list on every step. One cached location
  map is rebuilt with filtering/grouping, keeping those interactions constant
  time in very large folders.
- Moved session sorting, filtering, grouping, and item/location lookup into a
  pure tested index behind the existing app state. Grid groups now retain
  stable identities without allocating an enumerated copy on each render, and
  1k/10k/100k baselines plus Instruments signposts make future performance
  work measurable.
- Moved range, edge, command-click, rubber-band, filter, and rescan selection
  rules into a pure stable-ID state behind the session controller. Expanded
  app-level tests verify selection filtering, anchor movement, batch
  rating/undo, and the zero-match safety boundary.
- Rescanning or rebuilding RAW+JPEG pairing now preserves the exact current
  photo and multi-selection by stable file ID even when array positions
  change. Rating undo also follows the intended photo by ID rather than an old
  numeric position.
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
- The Export dialog now offers two modes: **Copy to…** (the previous
  behavior) and **Move to…**, which transfers the files and removes those
  photos from the session. Moved files stay safe at the chosen destination,
  but a move isn't undoable with ⌘Z — the dialog warns before it happens.
- Export is no longer keepers-only: the Yes / No / Undecided counts in the
  dialog are clickable tiles, so any mix of ratings can be exported. Copy
  with only Yes selected stays the default, and RAW+JPEG pairs still travel
  together.

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

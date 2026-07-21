# Performance architecture

This document records the performance-sensitive boundaries added after the
2026-07-14 code review. Read it before changing scanning, filtering, image
decoding, sidecar persistence, or Clean Up.

## Main-actor rule

`SessionStore` owns UI state and is `@MainActor`. It may create small value
snapshots and apply completed results, but potentially slow encoding and file
operations belong elsewhere:

- `SessionPersistence` is an actor. It serializes JSON encoding, sidecar reads,
  and atomic writes. Save sequence numbers prevent a late older task from
  replacing a newer sidecar. Rescan awaits its final save before reopening;
  app termination briefly waits for the final actor save (including a snapshot
  already queued by Close Session) so the last rating is not lost.
- `CleanUpWorker` receives immutable snapshots and uses a fresh `FileManager`
  inside its detached task. Trash and restore roll back RAW+JPEG pairs after a
  partial failure and explicitly warn if rollback itself fails. `SessionStore`
  applies the returned batch once.
- `ImagePipeline` uses two bounded `OperationQueue`s: full-size decodes stay
  limited to two (peak-memory bound for 4096 px images), while thumbnails get
  their own lane of `min(4, cores/2)` because 320 px decodes are small and a
  fresh Grid fills visibly faster. Requests for the same URL/size are
  coalesced; foreground and prefetch calls share the same in-flight operation,
  and a foreground join promotes utility prefetch work. With separate queues
  the current full image never waits behind tile backlog at all.
- `FolderScanner` reads per-file EXIF on concurrent workers
  (`DispatchQueue.concurrentPerform`, up to 8 chunks) because metadata
  extraction dominates scan time. Chunk slots are single-writer and
  concatenated in order, and the final chronological sort settles ordering, so
  output is identical to a serial pass (verified by order-hash benchmark).
  The `isCancelled` closure is polled from those workers and **must be safe to
  call from any thread** — a bare `{ Task.isCancelled }` silently reads false
  on GCD threads, which is why `SessionStore.openFolder` bridges task
  cancellation through `FolderScanner.CancelFlag` via
  `withTaskCancellationHandler`.

Do not move filesystem loops or JSON encoding back onto `SessionStore`.

## Batched `items` mutations

Combine's `@Published` exposes no in-place accessor, so every element written
through the wrapper (`items[i].rating = …`) copies the entire array and fires
its own `objectWillChange`. A per-element loop is O(N²) with thousands of
publishes — on a large folder that froze the app for seconds and the publish
storm left stale rating badges in the Browser. Any mutation touching more than
one element must go through `SessionStore.updateItems`, which mutates one
local copy and publishes once (verified by the clear-all/batch-rating
performance checks).

## Browser row invalidation

Batching alone did not cure the stale Browser: on macOS 26 a `LazyVStack`'s
diff of already-created rows is not a reliable invalidation path — realized
rows kept old rating badges and the current-photo frame until the view was
recreated (e.g. Grid and back). Each strip row is therefore `BrowserRow` with
its own `@ObservedObject` store reference, so every publish invalidates the
row directly, independent of the container's caching. Two invariants:

- Do not turn `BrowserRow` back into a plain value subtree inside the
  `ForEach` — that reintroduces the freeze.
- The row's `.id(item.id)` must stay: it is the follow-scroll target and it
  resets `ThumbnailView`'s cached `@State` image when Clean Up or its undo
  remaps an absolute index to a different photo.

The fan-out is bounded: only realized rows subscribe, their bodies are a
bounds check plus cache-hit lookups, and multiple publishes in one turn
coalesce into a single update transaction.

## Image cache budgets

- Thumbnails: at most 1,200 objects and 256 MiB decoded cost.
- Full previews: at most 8 objects and 384 MiB decoded cost.
- Disk thumbnails: 512 MiB maximum and 90-day maximum age, pruned on the utility
  queue at startup.

Decoded cost is `bytesPerRow × height`. Thumbnail JPEG encoding/writing happens
after the image is returned to the view. Keep the undersized-embedded-preview
fallback in `ImagePipeline.decode`; it prevents pixelated JPEG previews.
Neighbour prefetch is debounced by 60 ms, and a new full-image view waits 40 ms
before enqueuing a decode so key repeat does not flood the bounded queue with
views that have already disappeared.

Thumbnail cache keys use each file's modification date captured by
`FolderScanner`. Do not put a filesystem metadata lookup back in
`ImagePipeline.cacheKey`: lazy grid cells can be recreated during scrolling,
and synchronous `stat` calls there block the UI thread. Reappearing thumbnail
cells also seed directly from the memory cache to avoid placeholder churn.

## Grid scrolling

The day-grouped Grid view uses sections inside one `LazyVGrid`. Do not nest a
separate lazy grid for each day inside a `LazyVStack`: off-screen day heights
become estimates that SwiftUI corrects during upward scrolling and after tile
resizing, which makes the viewport jump. `gridColumnCount` is deliberately not
published because it is navigation-only state; publishing it causes a second
full grid redraw after each layout change.

The Browser and Grid install the shared `PersistentVerticalScroller` inside
their SwiftUI scroll content. It forces AppKit's `.legacy` vertical-scroller
style with autohiding disabled, so the control remains visible and consumes a
real gutter rather than overlaying thumbnails. Grid column-count calculations
must subtract `PersistentVerticalScroller.gutterWidth` to match the content
width AppKit gives the lazy grid. `configure` runs on every SwiftUI update
pass (every store publish), so it early-returns once the scroll view is fully
configured — keep that guard, otherwise every keystroke and drag tick pays a
redundant `tile()` layout on both scroll views.

## Filtering and derived data

`PhotoItem.searchableText` is locale-folded once during scanning. Capture-day,
aperture, shutter-duration, and ISO values are also cached on `PhotoItem`; do
not reopen files when their filters or sorts change. Group division compares
the cached `captureDay` buckets directly — do not reintroduce
`Calendar.current` calls per adjacent pair in `sameGroup`; a group rebuild
walks every visible photo. Each filter change creates
one `PreparedPhotoFilter`, so query normalization, whole-day date bounds, and
numeric ranges are prepared before walking the photo list. Search typing is
debounced by 150 ms. Camera-setting text edits use the same delay and commit
all valid drafts in one filter assignment, avoiding repeated full-list walks
while a value is being typed.

The date and exposure controls are always visible. Their folder-wide
minimum-to-maximum values are neutral: the corresponding internal filter flag
is set only after a bound is narrowed, so unknown metadata remains visible in
the default state. Re-scan keeps narrowed bounds but expands untouched ranges
to the newly derived folder span.

The multi-selection Info summary is built only from metadata and byte counts
already cached on `PhotoItem`. Do not reopen every selected file to assemble
its camera, lens, date range, size, or type lists.
Before Clean Up presents or resolves targets, it flushes that debounce so the
confirmation and filesystem operation use the filter text currently on screen.
The rating-based Clean Up scope resolves from already-cached folder indices,
visible indices, or the effective selection; changing it must not rescan files.

An active folder scan is cooperatively cancellable from the scanning toolbar
or Escape. Cancellation advances `scanGeneration` before returning to Welcome,
so late progress, persistence reads, or partial scan results cannot re-enter
the session after the user has left the scanning view.

`SessionStore` maintains:

- incremental Yes/No/undecided totals;
- cached type/camera/lens counts and labels;
- cached calendar-day counts and folder-wide aperture/shutter/ISO ranges;
- a sorted index list reused by filter-only changes;
- cached visible day groups and day-start indices.

After any structural replacement of `items`, call `rebuildDerivedData()` and
then `applyFilter()`. Rating-only changes must update the tally through
`transitionRatingCount` or replace the tally deliberately for a batch reset.

## Clean Up lifecycle

Clean Up and its undo have three phases:

1. Main actor resolves indices and snapshots values.
2. `CleanUpWorker` performs Trash/restore I/O and throttles progress updates to
   about 100 ms or 50 files.
3. Main actor applies one result, rebuilds derived data, and snapshots a save.

Each move/restore operation gets a new generation token. Delayed throttled
progress from an earlier move can therefore never overwrite a following undo.

While `isCleaningUp`, rating, navigation, selection mutation, undo, rescan,
folder switching, and export are blocked. Scrolling, metadata inspection, panel
visibility, and view switching remain available. The progress UI is a
non-interactive overlay, not a modal sheet. Quit requests are refused until the
worker finishes, because terminating during a partial RAW+JPEG move would
prevent its rollback from completing.

Restoration uses `mergeRestoredItems` rather than repeated array insertion. It
is O(n+k), retains survivor ordering, and omits only photos whose Trash files
could not be restored.

## Export lifecycle

Export shares Clean Up's three-phase shape: the main actor snapshots the
photos with the chosen ratings, `ExportWorker` runs the copy or move loop
off-main (reusing `ThrottledProgress`), and the main actor applies one
result. Copy never mutates the session. A Move export raises
`isMovingExport`, which blocks folder switching, rescan, undo, Clear All
Ratings, Clean Up, and Quit until the worker finishes; `finishExportMove`
then drops the fully moved photos by id, clears the (now index-stale) undo
stack, rebuilds derived data, re-applies the filter, and snapshots a save.
The modal sheet keeps rating and navigation keys away while export runs.

## Verification checklist

Run after performance-sensitive changes:

1. `./Tests/run_performance_checks.sh` (uses disposable files for a real
   Trash/restore pair round trip and rollback check)
2. `swift build`
3. `./build_app.sh`
4. Replace `/Applications/Louppe.app` with `dist/Louppe.app`.
5. Launch with `open /Applications/Louppe.app --args -openFolder /path/to/photos`.
6. Confirm `.louppe_session.json` appears and parses.
7. On a disposable folder, test rating persistence, Clean Up, progress, and ⌘Z
   round-trip for both a single image and a RAW+JPEG-style pair.
8. For a large disposable folder, scroll during Clean Up and undo; the window
   must remain responsive and file order must be restored.

Never test Clean Up on irreplaceable originals.

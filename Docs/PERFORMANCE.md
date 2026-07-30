# Performance architecture

This document records the performance-sensitive boundaries added after the
2026-07-14 code review. Read it before changing scanning, filtering, image
decoding, sidecar persistence, or Clean Up.

## Main-actor rule

`SessionStore` owns UI state and is `@MainActor`. It may create small value
snapshots and apply completed results, but potentially slow encoding and file
operations belong elsewhere:

- `SessionPersistence` is an actor. It serializes JSON encoding, typed
  sidecar/backup outcomes, schema validation, newest-valid reads, and atomic
  writes. Save sequence numbers prevent a late older task from replacing a
  newer snapshot. Folder switching, rescan, and Close Session await a safe
  result before discarding the live item array. Pairing-mode changes never
  discard it: they reproject the discovered physical-file records in memory.
  App termination uses AppKit's asynchronous terminate-later reply, so it can
  retry/refuse an unsafe Quit without blocking the main actor.
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
- `HistogramPipeline` decodes at most two 1,024-pixel photo previews at once,
  coalesces same-photo requests, and retains only 256 small histogram value
  results. Videos, unsupported files, and multi-selection summaries do not
  enqueue analysis. `ClippingPreviewPipeline` reuses `ImagePipeline`'s
  coalesced full preview and transforms at most two images concurrently.
- `HighResolutionImagePipeline` is the separate 100% lane. It keeps lazy,
  oriented Core Image source recipes for at most four recent photos, renders
  at most two 1,024-source-pixel tiles concurrently, coalesces identical tile
  requests, and discards stale generations before the AppKit viewport can
  display them. The viewport requests only its visible tiles plus one tile of
  margin.
- Video first frames share the bounded thumbnail lane, memory/disk cache, and
  in-flight request coalescing. `AVAssetImageGenerator` is called
  asynchronously from that background operation with exact zero-time
  tolerances; never generate movie frames from a SwiftUI body or main actor.
- `FolderScanner` reads per-file EXIF on concurrent workers
  (`DispatchQueue.concurrentPerform`, up to 8 chunks) because metadata
  extraction dominates scan time. Workers return chunks through a small
  lock-protected `ChunkResults` owner and the chunks are concatenated in index
  order; the final chronological sort settles ordering, so output is identical
  to a serial pass (verified by order-hash benchmark). The `isCancelled`
  closure is `@Sendable` and polled from those workers; a bare
  `{ Task.isCancelled }` silently reads false on GCD threads, which is why
  `SessionStore.openFolder` bridges task cancellation through
  `FolderScanner.CancelFlag` via `withTaskCancellationHandler`.

Do not move filesystem loops or JSON encoding back onto `SessionStore`.

## Shared rating storage

`PhotoItem` is mostly immutable scan metadata. Copying the complete
`@Published [PhotoItem]` array for one F/D decision made rating latency grow
with the folder size: the 100,000-item check measured 20.5 ms for one rating.
Each physical `PhotoFile` therefore keeps only its `Rating`/`ratedAt` pair in a
small shared, lock-protected storage object. `SessionStore` sends one
`objectWillChange`, updates the touched file or RAW+JPEG pair, and adjusts the
cached tally without replacing `items`; the same check is about 0.2 ms.

Value copies of a `PhotoItem` intentionally share that physical-file rating
storage. This preserves independent RAW and JPEG decisions through pairing
projection and gives detached readers an atomic rating/date snapshot. Do not
put the mutable fields back directly into the large value array. Clear All
remains O(N), but it mutates only the small rating records and publishes once;
normal single-photo culling is O(1). The large-session rating, clear-all, batch
rating, pairing, persistence, and undo checks enforce these boundaries.

## Lazy thumbnail invalidation

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

The Grid has the same lazy-container boundary. Each realized `GridCell`
observes `SessionStore` directly and reads its current `PhotoItem` inside
`body`, while the outer lazy grid retains `.id(item.id)` for follow-scroll and
thumbnail-state correctness. This is especially important because the Grid's
interactive rating control must redraw immediately after pointer, keyboard,
Clear All, or undo changes without replacing the large `items` array.
Direct Grid photo and rating-control clicks suppress the next one-shot
follow-scroll because their tile is already rendered under the pointer.
Keyboard navigation and structural current-item changes continue following the
stable media ID.

The fan-out is bounded: only realized rows and cells subscribe, their bodies
are a bounds check plus cache-hit lookups, and multiple publishes in one turn
coalesce into a single update transaction.

## Image cache budgets

- Thumbnails: at most 1,200 objects and 256 MiB decoded cost.
- Full previews: at most 8 objects and 384 MiB decoded cost.
- Clipping-warning previews: at most 2 objects and 128 MiB decoded cost.
- Histograms: at most 256 value-only results; analysis bitmaps are temporary
  and no larger than 1,024 pixels.
- Actual-size tiles: 128 MiB decoded cost across 1,024 × 1,024 source-pixel
  tiles, including both normal and clipping-warning variants. The lazy source
  recipe is not a whole decoded bitmap.
- Disk thumbnails: 512 MiB maximum and 90-day maximum age, pruned on the utility
  queue at startup.

Decoded cost is `bytesPerRow × height`. Thumbnail JPEG encoding/writing happens
after the image is returned to the view. Keep the undersized-embedded-preview
fallback in `ImagePipeline.decodeImage`; it prevents pixelated JPEG previews.
Neighbour prefetch is debounced by 60 ms, and a new full-image view waits 40 ms
before enqueuing a decode so key repeat does not flood the bounded queue with
views that have already disappeared. Fit/phone-size clipping previews share
that same delay, while secondary Info-panel EXIF and histogram work waits
80 ms. Full and clipping-preview memory-cache hits are still immediate.

At 100%, document points are source pixels divided by the window's backing
scale: one image pixel therefore maps to one physical display pixel on both
standard and Retina screens. `ActualSizeViewport` stores the point under the
viewport center as normalized image coordinates and is deliberately not
published; scroll-wheel traffic must not invalidate the rest of the session
UI. The AppKit scroll view survives item changes, clamps the position for each
new aspect ratio, and preserves an unscrollable axis for the next larger
photo. Pressing S or closing/changing folders resets it to center.

Fit and phone-size presentations map a double-click through their actual
letterboxed image rectangle to a normalized source position, request that
position from `ActualSizeViewport`, and only then enter 100%. The clicked point
therefore lands under the 100% viewport center (clamped at image edges), while
double-clicking the 100% image returns to Fit. The surrounding background does
nothing in either mode, and S retains its centered reset behavior.

Clipping warnings use the same 8-bit sRGB luminance thresholds as the Info
panel histogram: 0–5 for shadows and 250–255 for highlights. Fit and
phone-size modes reuse a bounded 4,096-pixel warning preview. At 100%, the
threshold is applied inside the existing two-operation tile lane, keyed by
warning mode, so toggling never constructs a whole source-resolution bitmap.
Changing photos or warning mode advances the viewport generation before stale
tile results can display.

Thumbnail cache keys use each file's modification date captured by
`FolderScanner`. Do not put a filesystem metadata lookup back in
`ImagePipeline.cacheKey`: lazy grid cells can be recreated during scrolling,
and synchronous `stat` calls there block the UI thread. Reappearing thumbnail
cells also seed directly from the memory cache to avoid placeholder churn.
Movie duration, playability, dimensions, codec, and frame rate are likewise
captured once by FolderScanner's bounded metadata workers. Filter, sort, and
Info views must use those values rather than reopening every `AVAsset`.

In paired mode, `FolderScanner` keeps a lightweight record for the hidden JPEG
using filesystem facts already returned by enumeration; it deliberately does
not open that JPEG's EXIF during the common initial scan. The first switch to
separate review enriches only those missing JPEG records on the same bounded
metadata workers while the ready session remains visible. Pairing projections
then reuse the enriched physical-file records, so later toggles neither walk
the folder nor reopen metadata.

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
- stable Browser id/index entries rebuilt only with the visible generation;
- cached visible day groups and day-start indices.
- one visible-location map containing each item index's global position,
  group, and position inside that group. Navigation, range selection,
  prefetch, and toolbar status must use this map rather than scanning
  `visibleIndices` or `visibleGroups` on every key press.
- one `PhotoItem.id` → current item-index map. Stable selected IDs and rating
  undo entries resolve through it only after a structural rebuild. A
  same-folder rescan snapshots current/selected IDs before clearing the old
  arrays, then remaps surviving visible IDs after the new filter/group
  generation is ready.
- one physical-file ID → displayed item-index map. It includes a grouped
  JPEG's hidden ID, allowing file-level ratings and rating undo to survive
  pairing projections without choosing the RAW rating or losing the JPEG
  rating.

`FolderScanner.pairFiles` sorts file paths and group keys before choosing a
RAW/JPEG pair, so filesystem enumeration and Dictionary order cannot change
pair choice between rescans. It folds basename case only on case-insensitive
volumes; case-sensitive volumes keep case-only names as distinct photos.
Folder traversal has no arbitrary depth cutoff; symbolic-link directories and
package descendants are skipped explicitly, so deep archives remain complete
without following loops.

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

## Durable file-operation journal

Copy, Move, Trash, and Trash undo create an immutable plan in
`~/Library/Application Support/Louppe/Operations/` before their first
filesystem change. The plan directory is activated with one atomic rename.
Each file then owns an independent checkpoint under `steps/`; advancing file
9,000 rewrites only that small record, so journal work remains O(1) per file
and O(n) for the complete batch.

Every plan captures source/destination paths plus stable volume/device/inode
identity. Staged and completed checkpoints capture the resulting file's
identity too. Recovery validates identity before removing or moving anything,
never overwrites an existing path, and leaves an unresolved journal retryable
when a volume is disconnected or a same-named replacement is present.

Export files move through operation-owned `.louppe-<operation>-<index>.partial`
paths before their final rename. This makes both crash positions recoverable:
before final rename the journal owns the unique temporary path; afterward the
staged identity still identifies the same inode at the destination. Trash is
the exceptional path because macOS chooses its destination. Its `.started`
checkpoint is written before `trashItem`; if termination happens before the
returned URL can be recorded, recovery searches the correct volume's Trash by
device/inode rather than guessing from the filename.

`SessionStore` runs recovery off-main before honoring a launch folder request.
File operations, folder/session mutation, updater installation, and Quit stay
blocked while it runs. A missing volume or identity conflict keeps the files
untouched and exposes Retry Recovery. After recovery of an operation that may
have moved source files, the current folder is rescanned.

## Export lifecycle

Export shares Clean Up's three-phase shape: the main actor snapshots the
photos with the chosen ratings, `ExportWorker` runs the copy or move loop
off-main (reusing `ThrottledProgress`), and the main actor applies one result.
`ExportWorker.makePlan` reserves every destination name first and chooses one
collision suffix per photo, keeping RAW+JPEG basenames matched. Copy rolls back
members of a partially failed or cancelled pair; photos completed before a
cancel remain at the destination. Move uses the same plan and retains its
source rollback.

`SessionStore.activeFileOperation` is the only in-flight authority for Clean
Up, Copy, and Move. It blocks folder switching, rescan, rating/selection
mutation, undo, Clear All Ratings, conflicting operations, updater
installation, and Quit. `finishExport` clears it for both modes; after Move it
also drops fully moved photos by id, clears the now-index-stale undo stack,
rebuilds derived data, re-applies the filter, and snapshots a save. The modal
sheet keeps rating and navigation keys away while export runs.

Before the worker starts, `ExportDestinationValidator` rejects the source
folder and its descendants after resolving symlinks, checks destination write
permission, and checks available capacity for Copy or a cross-volume Move.
Same-volume Move is a rename and does not need the full media size free.

## Prepared session index

`PreparedSessionIndex` owns the pure item-ID, sort, filter, group, header, and
visible-position maps behind `SessionStore`. `SessionStore` still publishes the
arrays consumed by SwiftUI, but navigation and indexing behavior can now be
tested without constructing a window or observable object.

The index emits Instruments points-of-interest intervals named **Rebuild Item
Index**, **Sort Session**, **Filter Session**, and **Build Visible Groups**.
Use these signposts before changing its algorithms or adding another derived
map.

The deterministic check includes synthetic 1k, 10k, and 100k-item metadata
fixtures. On the 2026-07-26 development build, their conservative unoptimized
baseline was:

| Items | ID map + camera sort | JPEG filter + 25 groups/locations |
|---:|---:|---:|
| 1,000 | 13 ms | 1 ms |
| 10,000 | 117 ms | 8 ms |
| 100,000 | 1,607 ms | 104 ms |

These numbers are a comparison baseline, not hard-coded pass/fail limits;
hosted CI machines vary. Structural counts and every location mapping are
asserted. Grid sections use metadata-derived stable IDs, so filtering a
group's former first member does not make SwiftUI discard and recreate the
remaining section.

`FolderScanner.sortItems` uses the exact `PhotoSort()` comparator. The prepared
index therefore treats the physical item order as the default sorted order and
does not repeat the same O(N log N) localized-name sort on the main actor after
opening a folder or when returning to the default sort. Non-default sort keys
still rebuild their own index order.

## Selection state

`SelectionState` is the pure authority for explicit indices and their stable
item IDs. `SessionStore` publishes its index projection to SwiftUI and remains
responsible for the current item, playback, and prefetch side effects.

The pure state owns range, edge, command-toggle, rubber-band, filter
intersection, and rescan remapping rules. An empty explicit selection still
means “the current visible item”; when a filter has zero matches, the effective
selection is truly empty. Focused logic and app-level XCTest cases protect
these rules so future controller extraction cannot silently rate hidden media
or remap a selection by stale numeric position.

## Verification checklist

Run after performance-sensitive changes:

1. `./Tests/run_performance_checks.sh` (uses disposable files for a real
   Trash/restore pair round trip and rollback check). In a restricted sandbox,
   `LOUPPE_SKIP_REAL_TRASH=1` runs the other 55 checks; this is not a substitute
   for the full 57-check verification before installing a build.
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

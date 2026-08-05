# Performance architecture

This document records the performance-sensitive boundaries added after the
2026-07-14 code review. Read it before changing scanning, filtering, image
decoding, sidecar persistence, or Clean Up.

## Main-actor rule

`SessionStore` owns UI state and is `@MainActor`. It may create small value
snapshots and apply completed results, but potentially slow encoding and file
operations belong elsewhere:

- `SessionPersistence` is an actor. It serializes JSON encoding, typed
  sidecar/backup outcomes, schema validation, newest-valid reads, and durable
  atomic writes. `DurableFileIO` flushes each new snapshot, atomically
  replaces its destination, and flushes the parent directory. Each open
  session carries a stable volume/inode/birth identity for its source folder
  plus the SHA-256 revision of the exact raw sidecar bytes that were read.
  Both are rechecked at the final replacement boundary. Backups and a
  cross-process advisory lock are keyed by that stable folder identity. The
  lock spans exact sidecar and backup revision checks, replacement or fallback
  writing, and local lineage update, so two Louppe processes cannot advance
  from the same snapshot. Actor-assigned snapshot generations—not wall time—
  order current sidecar and backup copies. Save sequence numbers prevent a
  late older task from replacing a newer snapshot. Folder switching, rescan,
  and Close Session await a safe result before discarding the live item array.
  When the exact opened path is absent because its card/drive disconnected,
  saving advances only that stable identity's local backup under the same lock;
  it never recreates the path, and any replacement or ambiguous path failure
  remains a conflict. Post-rename sync errors reconcile only exact destination
  bytes; a reconnect can adopt only the one sidecar revision that the same
  access marked as a possible interrupted commit, never an ordinary rollback
  to an older backup. `SessionStore` tracks a monotonic live-change generation
  against the generation captured by each successful sidecar/backup request.
  The just-opened scan is generation zero and is already a discard-safe
  baseline. Quit first awaits an active checkpoint, starts no new I/O when the
  live generation is already durable, and submits one fresh snapshot only when
  live ratings are newer. Failure of an already-running generation-zero repair
  does not block Quit; failure to secure a newer live generation does.
  Pairing-mode changes never
  discard it: they reproject the discovered physical-file records in memory.
  App termination uses AppKit's asynchronous terminate-later reply, so it can
  retry/refuse an unsafe Quit without blocking the main actor; a dedicated
  termination barrier rejects mutations after the final snapshot boundary.
  Rating saves use a 500 ms trailing delay plus a five-second maximum dirty
  age. While one actor write is slow, repeated maximum-age checkpoints
  coalesce into one replaceable request for the newest live snapshot.
- `CleanUpWorker` receives immutable snapshots and uses a fresh `FileManager`
  inside its detached task. Trash and restore roll back RAW+JPEG pairs after a
  partial failure and explicitly warn if rollback itself fails. `SessionStore`
  applies the returned batch once.
- `XMPMetadataStore` is a non-main actor and the only owner of XMPCore packet
  parsing plus XMP read/merge/CAS/atomic publication. Standalone Metadata
  (XMP) preflight and publication each use exactly three long-lived worker
  tasks with one serial store per worker; they never create one task per photo
  or retain a batch of complete packets. The immutable preflight plan keeps
  only exact paths, metadata snapshots, file revisions, and SHA-256 packet
  fingerprints. Each worker reparses one packet immediately before commit, so
  a change after confirmation becomes a visible conflict. Reads refuse leaf
  symlinks and non-regular
  files, stop at 64 MiB, and retain the exact bytes plus device/inode/time
  revision. The final validation immediately precedes a flushed same-directory
  temporary rename through `DurableFileIO`; creates use an exclusive rename,
  updates compare the live raw bytes and identity, and committed bytes are
  reparsed before success. Exact filesystem bytes remain plan authority.
  `SessionStore` owns the one XMP publication generation and cancellation
  flag separately from `activeFileOperation`: rating/navigation may continue,
  while a second file mutation is blocked. Open/Close Folder, Rescan, and Quit
  request cancellation and await the worker's between-file or completed atomic
  boundary; a late completion is applied only to the same scan/folder token.
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

## Shared review-metadata storage

`PhotoItem` is mostly immutable scan metadata. Copying the complete
`@Published [PhotoItem]` array for one F/D decision made rating latency grow
with the folder size: the 100,000-item check measured 20.5 ms for one rating.
Each physical `PhotoFile` therefore keeps its decision, stars, color, and
change dates in one small shared, lock-protected storage object. A read captures
the complete per-file snapshot. Pair projection, filtering, persistence, and
Export planning therefore cannot combine mutable fields observed at different
moments. `SessionStore` sends one `objectWillChange`, updates the touched file
or RAW+JPEG pair, and adjusts the cached tallies without replacing `items`; the
same check is about 0.2 ms.

Value copies of a `PhotoItem` intentionally share that physical-file metadata
storage. This preserves independent RAW and JPEG metadata through pairing
projection and gives detached readers a coherent snapshot. Do not
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
- Disk thumbnails: 512 MiB maximum and 90-day maximum age. Maintenance runs at
  most daily on the utility queue after a launch delay, so enumerating a large
  cache cannot compete with the first Gallery/Grid switch.

Decoded cost is `bytesPerRow × height`. Thumbnail JPEG encoding/writing happens
after the image is returned to the view. Keep the undersized-embedded-preview
fallback in `ImagePipeline.decodeImage`; it prevents pixelated JPEG previews.
An item with scan-time physical identity never reads identity-less v4 or v3
cache bytes: timestamps alone cannot prove which inode produced them on every
supported filesystem. The one-time cold v5 migration is intentional, happens
on the bounded decode queue, and must not block the Grid's first frame. Only an
older/synthetic item without scanned identity may use the byte-exact v4 cache
or, for unambiguous ASCII paths, v3; even then its cache timestamp must be at
least the captured source timestamp. The validated result is atomically
promoted. A corrupt v5 entry is replaced after a fresh source decode. Keep this
fail-closed boundary: a same-path replacement must never inherit old pixels,
even though a cold RAW decode is much slower than a cached JPEG read.
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
phone-size modes reuse a bounded 4,096-pixel warning preview. Fully
transparent pixels are excluded from histogram totals rather than counted as
black. At 100%, the threshold is applied inside the existing two-operation
tile lane, keyed by
warning mode, so toggling never constructs a whole source-resolution bitmap.
Changing photos or warning mode advances the viewport generation before stale
tile results can display.

Thumbnail cache keys use `PhotoItem.contentRevision`: byte-exact absolute path,
media kind, size, scan-time physical identity, and captured file timestamps.
Async thumbnail, full-preview, metadata, histogram, 100% tile, and video state
must also follow that revision rather than presentation ID alone. A same-folder
rescan deliberately preserves item IDs, so item ID cannot prove that the bytes
are unchanged. Do not put a filesystem metadata lookup back in
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

`SessionView` owns the trailing `MetadataPanel` outside the Gallery/Grid mode
switch. Both modes therefore share one stable panel, and toggling the view does
not restart its debounced EXIF and histogram tasks. Keep secondary inspection
work outside the mutually exclusive media canvases.

`ViewSwitchTests` mounts the real session UI with 106 actual image files,
multiple day groups, and the current item at the lazy Grid's distant tail. It
waits for the Grid scroll view and tail thumbnail, then exercises five warm
Gallery/Grid cycles. Keep those render barriers: timing only a state-enum write
does not protect the user-visible transition.

The day-grouped Grid view uses sections inside one `LazyVGrid`. Do not nest a
separate lazy grid for each day inside a `LazyVStack`: off-screen day heights
become estimates that SwiftUI corrects during upward scrolling and after tile
resizing, which makes the viewport jump. `gridColumnCount` is deliberately not
published because it is navigation-only state; publishing it causes a second
full grid redraw after each layout change.

Grid photo clicks use `GridImmediateClickSurface`, which commits the first
mouse-up synchronously and interprets `clickCount == 2` only on the second
click. Do not restore an exclusive single/double SwiftUI `TapGesture` pair:
the single recognizer waits for the system double-click interval before it can
update selection. The native surface also forwards the exact event modifiers,
rejects drags beyond the Grid's eight-point threshold, and returns keyboard
navigation ownership to the session.

The Browser and Grid install the shared `PersistentVerticalScroller` inside
their SwiftUI scroll content. It forces AppKit's `.legacy` vertical-scroller
style with autohiding disabled, so the control remains visible and consumes a
real gutter rather than overlaying thumbnails. Grid column-count calculations
must subtract `PersistentVerticalScroller.gutterWidth` to match the content
width AppKit gives the lazy grid. Keep AppKit's native `NSScroller`: the former
hand-drawn thumb competed with lazy-cell realization during a fast scroll and
made the indicator visibly step. Once mounted, configuration resolves the
enclosing scroll view synchronously; only the first unresolved mount lookup is
queued and duplicate lookups are coalesced. `configure` still early-returns
once the scroll view is fully configured, otherwise every keystroke and drag
tick pays a redundant `tile()` layout on both scroll views.

## Filtering and derived data

`PhotoItem.searchableText` is locale-folded once during scanning. Capture-day,
aperture, shutter-duration, and ISO values are also cached on `PhotoItem`; do
not reopen files when their filters or sorts change. Group division compares
the cached `captureDay` buckets directly — do not reintroduce
`Calendar.current` calls per adjacent pair in `sameGroup`; a group rebuild
walks every visible photo. Each filter change creates
one `PreparedPhotoFilter`, so query normalization, whole-day date bounds, and
numeric ranges are prepared before walking the photo list. Decision, star, and
color exclusions are evaluated explicitly from one coherent mutable-metadata
snapshot; they are never appended to immutable `searchableText`. Metadata sort
preparation likewise captures one snapshot per item before comparing, avoiding
lock acquisition during every O(N log N) comparison. Search typing is
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
- incremental Unrated/1–5/Mixed star and None/five-color/Mixed totals;
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

`FolderScanner.pairFiles` sorts byte-exact paths and group keys before
projection, so filesystem enumeration and Dictionary order cannot change the
result between rescans. A pair forms only when exactly one RAW and one JPEG
share the filename-stem key across the whole opened folder tree; every
ambiguous group stays separate. This lets a unique RAW in one subfolder pair
with its unique matching JPEG in another, while repeated camera filenames
remain independent. Pair stems use exact filesystem bytes. Only ASCII case is
folded, and only when the volume explicitly reports case-insensitive names;
unknown behavior fails closed. Accents, composed/decomposed Unicode spellings,
and non-ASCII case mappings therefore cannot collapse into one pair.

Physical file IDs are ASCII percent-encoded relative filesystem paths, not
decoded Swift paths. That lossless identity continues through projection
maps, selection, rating sidecars, and image-cache keys. Schema 3 requires the
`percentEncodedFileSystemPath` marker. Both the reader and writer require each
schema-3 ID to be the canonical ASCII encoding of a valid filesystem path and
require every primary and hidden paired-file ID to be globally unique.
Schema-1/2 entries are read only through a raw UTF-8 legacy index, so
canonically equivalent Unicode byte spellings remain independent during
migration; the marker prevents legacy alias fallback from colliding with a
new literal-percent filename.

Schema 4 additionally stores one stable identity per physical file: volume
UUID (with a conservative mount/device fallback), inode, size, birth time, and
nanosecond modification time. A same-path replacement cannot inherit the old
rating or trigger an automatic overwrite of the saved session. Verified file
and folder renames retain ratings, missing originals retain dormant entries
across later saves, and a returning exact file recovers its decision. ctime is
excluded only from persistence matching because Louppe-owned rename/rollback
  changes it without changing the photographed content; live transaction plans
  refresh and then enforce ctime during each operation. The source directory is
  captured before the walk and rechecked after metadata extraction, after the
  session read, and immediately before the scan is applied. Persistence also
  records the exact `lstat` identity of every ancestor in the opened path, so a
  replacement directory or dangling symlink cannot be mistaken for an ejected
  volume and inherit its backup lineage. Device numbers remain strict outside
  the source volume. A fully captured UUID-owned source may legitimately have a
  new device number after remount, but an absent/unreadable final folder keeps
  strict device checks so a different blank card cannot look like an ejected
  original. Every scanned file is likewise restated after metadata work and
  once more after persistence I/O.

Schema 1–3 cannot prove physical identity, but an ordinary legacy session in
its original folder migrates automatically when every saved filename is still
present. If legacy entries are missing, **Open Folder and Forget Missing
Items** explicitly excludes only those unmatched ratings from the new
identity-bound snapshot; Close Folder and Quit leave both legacy copies
untouched. Obsolete path-keyed backups are considered only when both the
sidecar and identity-keyed backup are absent; their legacy entries still use
the explicit confirmation because that backup is not owned by the folder, and
schema-4 entries still require a physical identity match.
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

## Process-crash file-operation journal

Copy, Move, Trash, and Trash undo create an immutable plan in
`~/Library/Application Support/Louppe/Operations/` before their first
filesystem change. The plan directory is activated with one atomic rename.
Each file then owns an independent checkpoint under `steps/`; advancing file
9,000 rewrites only that small record, so journal work remains O(1) per file
and O(n) for the complete batch.

One exclusive advisory lock covers the Operations root for the full lifetime
of every worker or recovery pass. A second process cannot inspect or start a
transaction while the owner is alive; the OS releases the lock on process
exit. The release bundle also prohibits ordinary multiple app instances, but
the lock—not that UI declaration—is the correctness boundary. Under that same
lock, transaction start refuses any older active journal; recovery must finish
before another worker can begin.

Plan v3 stores the exact filesystem bytes for every source, destination,
temporary, and resolved Trash path. Recovery reconstructs those bytes without
normalizing through a Swift string; malformed, relative, noncanonical, or
mismatched raw paths keep the journal retryable. Plan v1 and v2 remain readable
for crash recovery. XMP-aware Copy/Move uses the version-4 extension: each
record explicitly identifies ordinary media, an unchanged application packet,
a generated destination packet, or a fully selected family's retired source
packet. It seals source and prepared-packet SHA-256 digests into the immutable
plan while retaining the same exact-path and identity authority. Version-1,
version-2, and version-3 plans remain readable with their original recovery
semantics. Intentional Trash operations reconcile forward: launch
recovery accepts the current source state and retires their bookkeeping without
restoring or searching for media in macOS's privacy-protected Trash. Explicit
in-session Trash Undo remains the sole restore path. Export preflight resolves
symlinks through the same raw POSIX boundary and passes that exact selected
directory unchanged to Copy or
Move; target construction must not use Foundation path standardization. Plans
are decoded fail closed: every path must be absolute and canonical;
source, destination, and temporary paths must be globally disjoint by exact
bytes and resolved aliases; no destination/temporary inode may alias a source
or another operation-owned path; no manipulated path may enter journal
storage; destination/temporary contracts must match the operation kind; and
temporary names must belong to the recorded operation and step. Distinct
source names may intentionally refer to one hard-linked file during Copy. Move,
Clean Up, and Trash undo reject such a batch before mutation because renaming
one link changes shared inode metadata and would make its sibling's recovery
checkpoint ambiguous. An operation-owned path may never exploit any inode
alias. Mutating operations also reject a single source whose link count is
greater than one, because a pre-checkpoint Trash destination would not identify
one unique directory entry. Committed journals are accepted only when their record repeats
the operation ID and a SHA-256 digest of the immutable raw `plan.json` bytes.
The exact legacy plan-v1 marker, including an authentic empty committed v1
plan, remains readable after the stricter plan validation. A listing or
inspection error is reported as unresolved recovery, never mistaken for an
empty journal root.

Every plan captures source/destination paths plus stable volume/device/inode,
size, birth, modification, and status-change identity. Staged and completed
checkpoints capture the resulting file's identity too. Recovery validates the
relevant identity before removing or moving anything, never overwrites an
existing path, and leaves an unresolved journal retryable when a volume is
disconnected or a source was replaced or rewritten in place. A stable volume
UUID supersedes remount-sensitive mount paths and device numbers. Exact source
checks include status-change time. Operation-created copies deliberately do
not: macOS may attach provenance or other metadata asynchronously after
`copyItem` returns, changing only ctime while the volume, inode, birth time,
size, modification time, and file bytes remain the same.

Export files move through operation-owned `.louppe-<operation>-<index>.partial`
paths before their final rename. This makes both crash positions recoverable:
before final rename the journal owns the unique temporary path; afterward the
staged identity still identifies the same inode at the destination. Trash is
the exceptional path because macOS chooses its destination. Its `.started`
checkpoint is written before `trashItem`; if termination happens before the
returned URL can be recorded, recovery preserves the photographer's Trash
decision and retires the record without searching protected Trash directories.
If durable steps show that a paired Trash action stopped between RAW and JPEG,
the record remains nonblocking attention until Retry or the explicit **Keep
Files As They Are** action; that action retires only journal metadata and never
touches media.

Generated XMP packets use that same planned temporary instead of an untracked
atomic-write filename. Their intended digest replaces the ordinary Copy byte
comparison because the merged destination deliberately differs from its source
packet. A started complete packet can be published only when every byte matches
the sealed digest; an incomplete packet is removed only when its exact inode was
checkpointed. Move recovery removes a checkpointed generated packet when its
family rolls back, preserves it when the entire family completed, restores an
incomplete source-packet retirement, and completes a fully checkpointed
retirement forward. The old canonical packet is not retired until all media,
generated, and application-packet records in that family are complete.

Move currently accepts only destinations on the same known storage volume,
revalidates the planned source immediately before touching it, and performs
both transitions with `renamex_np(..., RENAME_EXCL)`. That syscall either
performs an inode-preserving, non-overwriting rename or fails (including
`EEXIST`/`EXDEV`); it never silently copies and deletes. Copy remains the path
for another drive or card.
Do not re-enable cross-volume Move until it is an explicit
copy/flush/verify/checkpoint/delete transaction with recovery tests.

`DurableFileIO` enforces the power-loss order: write and sync the immutable
plan before activation; sync operation-created copies and every affected
rename/removal directory before advancing a step; then fully sync the
operation-bound commit record before retiring the journal. A cross-directory
rename flushes the destination directory before the source directory so a
power cut prefers two recoverable names over none. The macOS Trash boundary is
the exception: `FileManager.trashItem` owns that system-managed transition, and
Louppe never makes direct open/fsync access to `.Trash` or `.Trashes` a success
condition. A completed journal leaves the active namespace through an
exclusive `.retired` rename and full root sync
before bounded housekeeping can recursively remove it. Journal checkpoints
recapture and compare the exact worker-proven identity before accepting a
path as operation-owned. Copy/Move duplicate cleanup transfers the candidate
to the other plan-owned path, repeats byte comparison under fresh ctime-bound
identities, and only then performs a nonrecursive unlink. Session sidecars
and backups use the same write -> sync -> atomic replace -> directory-sync
boundary. If any flush fails after a filesystem side effect, the worker keeps
the journal and enters conservative recovery instead of claiming success.

`SessionStore` runs recovery off-main. While the pass is actively reconciling
files, conflicting transitions remain blocked. If a journal remains unresolved,
it becomes nonmodal attention: only new Copy, Move, Clean Up/Trash, and Trash
undo wait. Reviewing, rating, navigation, opening/closing/rescanning folders,
saving, updating, and Quit remain available, and a requested launch folder is
still opened. Reconnection is suggested only when the report actually
identifies an unavailable volume. After recovery of an operation that may have
moved source files, only that exact currently open folder is rescanned. Copy
recovery never returns to a destructive pre-export state: identity-verified staged and
completed copies are kept, and a staged temporary is durably published under
its planned destination name without requiring the source drive to remain
mounted. Fully completed Move items likewise stay at their chosen destination;
only an incomplete item or pair uses source-restoring rollback recovery. A
  permanently ambiguous journal can be cleared with **Keep Files As They Are**
  without changing any photo path. That escape accepts only a canonical UUID
  journal name and atomically sets the record aside as `.forgotten`; it never
  deletes the record's contents or adopts an arbitrary `.operation` file.
Only the real `LouppeApp` entry point opts into automatic launch recovery.
Test stores default to no automatic recovery and can inject a disposable
journal directory, preventing test execution from ever reconciling a live
photographer operation.

Session persistence uses a separate identity-keyed advisory lock that still
spans the complete sidecar/backup compare-and-swap transaction. Acquisition is
nonblocking with a short deadline; contention becomes an ordinary retryable save
failure instead of allowing Close, folder changes, or Quit to wait forever.

## Export lifecycle

Export shares Clean Up's three-phase shape: the main actor evaluates one pure
decision + stars + color AND predicate and snapshots matching items plus exact
physical-file counts. `ExportWorker` runs the copy or move loop
off-main (reusing `ThrottledProgress`), and the main actor applies one result.
`ExportWorker.makePlan` reserves every destination name first and chooses one
collision suffix per photo or same-stem XMP family, keeping RAW+JPEG, canonical
XMP, and extension-qualified application-packet basenames matched. When XMP is
enabled, `XMPExportPlanner` resolves the complete live stem family and prepares
merged destination bytes off-main before `FileOperationJournal` activation.
The activated version-4 plan covers every media and XMP source, temporary,
destination, identity, role, and digest before the worker's first filesystem
change. Copy rolls back
members of a partially failed or cancelled pair; photos completed before a
cancel remain at the destination. Once a Copy has been flushed and staged, a
later source-drive disconnect cannot invalidate it; recovery preserves that
copy instead of deleting completed work. Move uses the same plan and retains
its source rollback. A fully selected canonical XMP is transferred only after
its merged destination is durable; a packet shared with an unselected same-stem
member is copied and retained at the source.

`SessionStore.activeFileOperation` is the only in-flight authority for Clean
Up, Copy, and Move. It blocks folder switching, rescan, rating/selection
mutation, undo, Clear All Ratings, conflicting operations, updater
installation, and Quit. The same state retains one `ProcessInfo` activity with
`idleSystemSleepDisabled` for the complete transaction (recovery owns it too),
so automatic system sleep cannot strand removable-media I/O; display sleep is
still allowed. Explicit MacBook lid-close sleep cannot be overridden. After
wake, Copy treats transient missing-device/I/O errors as a remount window: it
waits up to 60 awake seconds for the exact journal-bound source identity and
retries once only when no temporary artifact exists. If `copyItem` leaves a
partial artifact, the worker checkpoints its exact physical identity before
rollback and removes only that inode through the two reserved plan paths. A
crash after a complete copy but before the staged checkpoint is reconciled by
rechecking the planned source identity and comparing every byte; it is then
published instead of discarded. A legacy partial with no recorded identity
remains untouched. `finishExport` clears the in-flight state for both modes; after Move it
also drops fully moved photos by id, clears the now-index-stale undo stack,
rebuilds derived data, re-applies the filter, and snapshots a save. The modal
sheet keeps rating and navigation keys away while export runs.

Before the worker starts, `ExportDestinationValidator` rejects the source
folder and its descendants after resolving symlinks, checks destination write
permission, and checks available capacity for Copy. Same-volume Move is a
rename and does not need the full media size free. Validation returns the
resolved directory that the worker actually receives, so retargeting the
folder-picker symlink cannot redirect a later export. The remaining hardening
step is descriptor-relative source/destination I/O, which would also close the
smaller race where the resolved directory itself is replaced after preflight.
The important-usage capacity API's transient zero is treated as ambiguous and
cross-checked with `statfs`, preventing File Provider-managed destinations from
being falsely reported as full.

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
   `LOUPPE_SKIP_REAL_TRASH=1` runs the other 68 checks; this is not a substitute
   for the full 71-check verification before installing a build.
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

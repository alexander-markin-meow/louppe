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
- `ImagePipeline` uses an `OperationQueue` limited to two decodes. Requests for
  the same URL/size are coalesced; foreground and prefetch calls share the same
  in-flight operation, and a foreground join promotes utility prefetch work.
  The current full image outranks queued thumbnails, which outrank prefetches.

Do not move filesystem loops or JSON encoding back onto `SessionStore`.

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

## Filtering and derived data

`PhotoItem.searchableText` is locale-folded once during scanning. Each filter
change creates one `PreparedPhotoFilter`, so query normalization and whole-day
date bounds do not repeat per photo. Search typing is debounced by 150 ms.
Before Clean Up presents or resolves targets, it flushes that debounce so the
confirmation and filesystem operation use the filter text currently on screen.

`SessionStore` maintains:

- incremental Yes/No/undecided totals;
- cached type/camera/lens counts and labels;
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

# Louppe codebase audit and improvement plan

Audit date: 2026-07-26

This audit covers the complete application source, build and release scripts,
documentation, and test suites. The current app source is about 10,400 lines of
Swift. The audit included release and debug builds, strict-concurrency
diagnostics, all focused test scripts, the XCTest suite, package/signature
inspection, and a real installed-app launch against a disposable photo folder.

This is a plan, not a request to rewrite the app. Louppe's current ownership
boundaries and data-safety invariants are sound. The highest-value work is to
close a few file-operation and persistence gaps first, then improve
testability, concurrency, performance, and accessibility in that order.

## Current baseline

The following checks pass on the audited revision:

- Release app build and strict code-signature verification.
- Installed-app launch, folder scan, RAW+JPEG pairing, and sidecar creation.
- 57/57 performance, persistence, recovery, cleanup, export, and metadata
  checks, including two real macOS Trash/restore checks.
- 9/9 scrollbar behavior checks.
- 18/18 native video checks.
- 9/9 XCTest cases.
- Signed Sparkle feed, signed archive metadata, embedded updater framework,
  and extraction/signature verification of the release zip.

The package now builds in Swift 6 language mode with complete strict
concurrency checking and zero warnings.

## Implementation progress

Completed on 2026-07-26–27 after the audit:

- **P1-1:** Copy and Move share a batch destination plan. One collision suffix
  is reserved for every member of a photo, partial Copy failures roll back, and
  Copy cancellation cannot leave an in-progress half-pair.
- **P1-2:** `SessionStore.activeFileOperation` now covers Clean Up, Copy, and
  Move. Copy blocks Quit, folder/session mutation, conflicting operations, and
  updater installation until it completes or stops safely.
- **P1-3:** Copy, Move, Trash, and Trash undo now write a durable, per-file
  operation journal before touching media. Launch recovery verifies stable
  volume/inode identities, restores the conservative source state, never
  overwrites an existing file, and remains retryable when a volume is absent.
- **P2-1:** Export rejects the source folder and symlink-resolved descendants,
  checks destination writability, and preflights capacity for Copy and
  cross-volume Move.
- **P2-6:** The package now defaults to Swift 6 language mode. Scanner chunk
  collection, export callbacks, AVFoundation metadata reads, and notification
  observer cleanup pass complete strict-concurrency checking.
- **P2-2:** RAW+JPEG grouping now has stable path/group ordering and respects
  the source volume's filename case sensitivity.
- **P2-3:** The silent depth-five cutoff is removed. Deep media is scanned,
  while symbolic-link directories are explicitly skipped and cancellation
  remains active.
- **P2-8:** The Info panel distinguishes selected items from their underlying
  file count, uses “media items” when videos are included, and shows primary,
  paired, and total sizes for a RAW+JPEG pair.
- **P1-4:** Persistence now returns typed folder/backup/failure results,
  maintains a current fallback, chooses the newest valid snapshot, exposes a
  Retry Saving warning, and uses asynchronous Quit coordination.
- **P2-4:** Version, source-folder, relative-path, uniqueness, paired-name, and
  rating values are validated before a session is applied. Unsafe or future
  sidecars are preserved and block automatic replacement.
- **P2-5:** Selection and rating history now use `PhotoItem.id` as their stable
  authority. Rescan snapshots current/selected IDs before clearing the old
  generation, then remaps them through the rebuilt ID→index map.
- **P3-5 (release portion):** Every package build runs a local app/archive/feed
  preflight; publishing mode additionally verifies the feed and archive
  signatures against the owner's Keychain key and checks enclosure metadata.
- **P3-1/P3-2 (prepared-index portion):** A pure `PreparedSessionIndex` now
  owns item-ID, sorting, filtering, stable groups, header, and visible-location
  maps behind the existing `SessionStore` facade. One derived location map serves
  range selection, horizontal/vertical navigation, next-undecided, prefetch,
  and toolbar position lookups in O(1) instead of repeatedly scanning the
  visible list and groups. Grid sections now have metadata-derived stable IDs
  and avoid a render-time enumerated-array allocation.
- **P3-2 (measurement portion):** Instruments signposts cover index rebuild,
  sort, filter, and group phases. Deterministic 1k/10k/100k fixtures record a
  local comparison baseline and validate every visible map.
- **P3-1 (selection portion):** Pure `SelectionState` now owns the explicit
  index/stable-ID projections plus range, edge, command-toggle, rubber-band,
  filter-intersection, and rescan-remapping rules behind `SessionStore`.
- **P2-9 (CI portion):** A least-privilege macOS 26 GitHub Actions workflow
  now gates strict Swift 6 compilation, XCTest, 55 deterministic
  logic/recovery cases, scrollbar/video suites, and the local release-package
  preflight without private updater credentials.
- Thirty new focused regression cases cover pairing and recursive-scan
  determinism, pair-safe export, unsafe destinations, accurate item/file
  metadata, stale-backup precedence, corruption recovery, schema rejection,
  total persistence failure, crash-state recovery, exact file identity,
  recovery idempotency, ID-safe rating undo, rescan identity preservation,
  stable Grid groups, 1k/10k/100k prepared-index structure, selection
  remapping/filtering, batch rating/undo, and zero-match safety.

The highest-value remaining reliability work is broader app-level/CI coverage
(**P2-9**). Updater-key backup and notarization (**P1-5**) remain
owner/release-process work.

## What is already strong

- Originals have a deliberately narrow set of movement paths. Clean Up and
  Move export keep filesystem work off the main actor and attempt pair
  rollback on failure.
- `SessionStore` is a clear single source of truth. Derived data is rebuilt
  explicitly, rating counts are incremental, and defensive index checks
  protect the UI from stale state.
- Thumbnail work is bounded by memory and disk budgets, decoding occurs away
  from the UI, and prefetch requests are deduplicated.
- Session saves are ordered by sequence number and use atomic writes with a
  read-only-folder fallback.
- Scan cancellation, export progress, cleanup progress, and video playback
  already have clear ownership boundaries.
- The custom regression programs test real filesystem behavior without adding
  a large testing dependency.
- The release version and changelog are validated during packaging.
- Updates now use a checksum-pinned Sparkle binary, Ed25519-signed feed and
  archives, daily checks, background downloads, and a documented release
  process.

## Priority guide

- **P1 — protect files and ratings:** address before adding broad new
  features.
- **P2 — correctness and maintainability:** complete in the next reliability
  milestone.
- **P3 — performance and product polish:** implement after measurement or as
  part of the relevant feature.

## Findings

### P1-1 — Completed: pair-transactional Copy and shared collision naming

At the audit baseline, Copy flattened every selected item into an independent
file list and Copy/Move chose collision suffixes per file. A second-member
failure could leave half a pair, while a collision against only `SHOT.NEF`
could produce `SHOT (1).NEF` beside unmatched `SHOT.JPG`.

Implemented:

- `ExportWorker.makePlan` reserves the complete batch before I/O.
- Every member of a `PhotoItem` receives one shared suffix, and later
  same-named items cannot collide with earlier reservations.
- Copy works per photo and removes already-copied members when a later member
  fails.
- Copy and Move use the same plan; neither replaces an existing destination
  file.

Passing acceptance checks:

- A collision against either pair member gives both files the same suffix.
- An injected second-file failure leaves no partial copy in the destination.
- Existing destination files are never replaced.
- A failed photo does not prevent later photos from being attempted.
- Copy and Move share the same tested destination-planning rules.

### P1-2 — Completed: Copy uses the shared active file-operation state

At the audit baseline, Move and Clean Up blocked Quit and session mutations,
but Copy had no in-flight state beyond its modal sheet.

Implemented:

- `SessionStore.activeFileOperation` is the single state for Clean Up, Copy,
  and Move.
- Quit, folder replacement, rescan, rating/selection changes, undo, conflicting
  file operations, and the manual updater are blocked while it is active. The
  application delegate refuses an automatic updater relaunch too.
- Copy has an explicit Stop button. It keeps completed photos and rolls back
  the in-progress pair before clearing the state.

Passing acceptance checks:

- Quit and update installation cannot interrupt a copy between pair members.
- Buttons and menu commands derive their enabled state from one source.
- Cancelling reports the completed file count, keeps completed photos, and
  explains that the in-progress photo was rolled back.
- Moving originals remains available only through the two sanctioned paths.

### P1-3 — Completed: durable, identity-verified file-operation recovery

Implemented:

- `FileOperationJournal` atomically activates one immutable operation plan,
  then writes a small per-file checkpoint. A 10,000-file job updates one tiny
  state record per step rather than repeatedly rewriting a giant journal.
- Export Copy and Move stage files through operation-owned hidden temporary
  paths before the final rename. Trash records the source identity before
  `trashItem` and its system-selected destination immediately afterward.
- Every staged or completed file is tied to its volume, device number, and
  inode. Recovery refuses a same-named replacement and never overwrites an
  existing source.
- Active Copy journals remove only operation-owned partial copies. Active
  Move and Trash journals restore the source state; active Trash undo
  journals finish restoring the source state. A committed marker preserves a
  fully completed operation if the process stopped before journal cleanup.
- Launch recovery runs off the main actor before a requested folder opens.
  Destructive/session-changing actions and Quit remain blocked while it runs.
  Missing volumes or identity conflicts leave the journal and files untouched
  with a persistent Retry Recovery action.

Passing acceptance checks:

- Simulated termination after Copy staging/finalization removes the partial
  copy and leaves the original.
- Simulated termination before or after a Move rename restores the exact
  source file.
- Trash and Trash-undo interruption fixtures recover in the correct direction.
- Recovery is idempotent, committed operations preserve their results, and a
  same-named replacement remains untouched and retryable.
- Journals contain paths, stable identity, and state only—never media contents
  or credentials.

### P1-4 — Completed: observable, ordered session persistence

At the audit baseline, encoding and both write destinations could fail
silently, reads collapsed absence/corruption/permissions into `nil`, the
fallback could become stale, and termination blocked the main thread.

Implemented:

- Save returns typed sidecar, backup-only, total-failure, and superseded
  outcomes with categorized permission, capacity, volume, and encoding causes.
- A successful save refreshes the Application Support snapshot. Reads validate
  both candidates and apply the newest valid `scannedAt` value rather than
  blindly preferring the sidecar.
- `SessionStore` shows a persistent, non-modal Retry Saving banner for
  backup-only or unsafe state. A later successful sidecar save clears it.
- Folder switching, rescan, pairing-mode changes, and Close Session keep the
  live session until the snapshot is safe.
- Quit uses AppKit's terminate-later flow. A total failure offers Retry,
  Cancel Quit, or explicit Quit Without Saving.

Passing acceptance checks:

- Corrupt sidecars recover from the current last-known-good backup.
- A newer backup wins over a stale but valid sidecar.
- Failure of both destinations is a typed failure and retains a retry snapshot.
- No main-thread semaphore remains in the persistence/termination path.

### P1-5 — Updater release signing has a single-key operational risk

The updater itself now verifies a signed feed and signed archives. Existing
updater-enabled copies of Louppe depend on the matching private Ed25519 key,
which is stored in the release owner's Keychain. Loss of that key would make a
normal trusted update path impossible.

Implemented so far:

- `Scripts/verify_release.sh` checks the exact app and archive on every release
  build. `--publishing` also verifies the signed appcast and enclosure archive
  with Sparkle, plus version/build, URL, byte length, minimum macOS, embedded
  framework, and extraction/signature integrity.
- The private signing key remains outside Git and the app bundle.

Remaining owner-operated changes:

- Make an encrypted offline backup of the exported private key and test one
  restore on a separate macOS account.
- Keep `Docs/UPDATES.md` as the release checklist and require its verification
  steps before publishing.
- When practical, use Developer ID signing, hardened runtime, and Apple
  notarization. Sparkle's signature remains necessary; notarization solves
  first-install trust and reduces Gatekeeper friction.

Acceptance checks:

- The backup can sign a disposable feed that the app's public key verifies.
- A release cannot pass preflight with a stale feed or changed archive.
- No private signing material is stored in Git, the app bundle, or build logs.

### P2-1 — Completed: export destination safety and capacity preflight

At the audit baseline, the picker allowed the source folder or a descendant,
which could make copies duplicate on rescan or moved photos reappear under
new IDs.

Implemented:

- Source and destination are standardized and symlinks are resolved.
- The exact source and all descendants are rejected for both modes.
- Destination directory/write permission is checked.
- Available capacity is checked for Copy and cross-volume Move; same-volume
  Move is allowed to use its normal rename path without requiring the full
  media size free.

Passing acceptance checks:

- Symlinked paths cannot bypass the source/descendant check.
- Same-folder Move never becomes an accidental rename.
- The dialog explains why an unsafe destination is unavailable.

### P2-2 — Completed: deterministic, volume-aware RAW+JPEG pairing

At the audit baseline, filesystem enumeration and Dictionary order could
change which unusual duplicate became the chosen pair, while unconditional
lowercasing could merge case-only names on a case-sensitive volume.

Implemented:

- File paths and group keys are sorted before pair choice.
- Pair candidates and leftovers use a stable path order.
- Basenames are case-folded only when the source volume reports
  case-insensitive names.
- Reversed-input and case-sensitive-volume regression fixtures are included.

Passing acceptance checks:

- Repeated scans of the same tree create identical item IDs and pairs.
- Reversing enumerator input order does not change the result.
- Case-sensitive-volume fixtures do not merge distinct photos.

### P2-3 — Completed: complete deep scanning with explicit loop prevention

At the audit baseline, scanning silently stopped below depth five.

Implemented:

- The arbitrary depth cutoff is removed.
- Symbolic-link directories are detected and skipped explicitly.
- Package descendants remain skipped and cooperative cancellation remains
  active.
- A depth-eight fixture with a link back to its root verifies completeness and
  loop prevention.

Passing acceptance checks:

- Deep fixtures are either scanned or produce a visible skipped-folder count.
- Symlink loops and packages do not cause unbounded traversal.
- Cancellation remains responsive on very large trees.

### P2-4 — Completed: explicit session-schema validation

The only supported schema is version 1. Reads now validate that version, the
canonical source folder, unique safe relative filenames, paired basenames, and
rating values. A future-version or different-folder sidecar blocks the session
with a visible explanation even if an older fallback exists, so the current
app never overwrites data it may not understand. Corrupt/invalid data uses a
valid current-folder backup when available; otherwise it is preserved and the
folder is not opened.

Passing acceptance checks:

- Future-version, wrong-folder, malformed-rating, and traversal fixtures are
  rejected without replacement.
- A valid backup can recover a corrupt version-1 sidecar.
- The current policy is conservative: copying/moving a folder requires the
  embedded `sourcePath` to be updated deliberately before ratings are applied.

### P2-5 — Completed: stable identity across item generations

Implemented:

- `SelectionState.itemIDs` is the stable multi-selection authority;
  `selectedIndices` remains the published render-facing projection used by
  the lazy Browser and Grid.
- The derived rebuild creates an `itemIndexByID` map alongside sorted and
  visible locations. Selection remapping and rating undo resolve IDs through
  that current-generation map.
- Rating undo records each `PhotoItem.id` plus its former rating/time, and
  restores the former current photo by ID. It can no longer apply a rating to
  the wrong photo after an index changes.
- A same-folder rescan or pairing rebuild snapshots current and selected IDs
  before `items`/`visibleIndices` are cleared. When the new scan finishes,
  surviving visible IDs are remapped and the former current photo is restored.
- Clean Up, Clean Up undo, and Move export preserve the current item by ID
  when it survives, with the prior same-position successor fallback when the
  current item itself left the folder.

Passing acceptance checks:

- A real asynchronous four-file rescan changes the current photo's array
  position while preserving the exact current ID and two-photo selection.
- A rating undo follows its photo after a forced array reorder and returns the
  current pointer to that same ID.
- Existing Browser/Grid follow-scroll, cleanup successor, filtering, range
  selection, and restoration checks remain unchanged.

### P2-6 — Completed: Swift 6 strict-concurrency migration

At the audit baseline, complete diagnostics found a non-Sendable scanner
cancellation/buffer capture, a detached export callback capture, concurrent
access to one AVFoundation track, and non-Sendable notification tokens in a
nonisolated deinitializer.

Implemented:

- Scanner cancellation is `@Sendable`, and bounded workers publish ordered
  chunks through a lock-protected Sendable owner.
- Export detached work captures Sendable request/result values and returns to
  `MainActor` before invoking session callbacks.
- AVFoundation track properties load sequentially on the existing background
  scanner worker.
- Notification tokens live in lock-protected Sendable owners.
- `Package.swift` now defaults to Swift 6 language mode.

Passing acceptance checks:

- `swift build` and `swift test` produce zero strict-concurrency warnings.
- The package compiles in Swift 6 language mode on the current SDK.
- Scan cancellation, video metadata, and file operations retain their current
  regression coverage and responsiveness.

### P2-7 — “100%” zoom is not guaranteed to mean one image pixel

Full-image decoding is capped at 4,096 pixels, and `FullImageView` uses
representation pixel dimensions as SwiftUI point dimensions. On a Retina
display, points and physical pixels differ. Large camera files are therefore
downsampled and the result may not be a true one-source-pixel-to-one-screen-
pixel view.

Recommended change:

- Define 100% as one source pixel per backing-store pixel.
- Include window backing scale when calculating display size.
- Decode only the visible full-resolution region with ImageIO thumbnail/tile
  requests instead of allocating an entire 45–100 MP image.
- Keep the current fast 4,096-pixel image as the immediate preview while the
  visible high-resolution region arrives.

Acceptance checks:

- A resolution target renders a known pixel grid at exactly 1:1 on standard
  and Retina displays.
- Peak memory stays bounded on a representative 100 MP file.
- Pan/zoom does not block keyboard rating or video playback.

### P2-8 — Correct file-count and size wording — completed

The multi-selection panel now shows both the selected photo/media-item count
and underlying file count. Selections containing video use “media items.”
Single RAW+JPEG metadata shows primary, paired, and combined sizes.

Acceptance checks:

- Pair, unpaired photo, video, and mixed-selection fixtures produce accurate
  counts and totals.
- No destructive confirmation understates the number of filesystem entries.

### P2-9 — CI gate and selection coverage completed; broader UI coverage remains

The focused suites exercise important algorithms, and nine XCTest cases
currently cover app-level behavior.
Important untested seams include updater configuration, more view-level
session failure states, accessibility labels, and the recovery presentation
itself. Pair collision planning, persistence recovery/schema failures, export
preflight, selection across a real rescan, journal crash states, and local
update release packaging now have focused checks.

Implemented:

- `.github/workflows/quality.yml` runs on pull requests, pushes to `main`, and
  manual dispatch using GitHub's native `macos-26` image.
- Repository permission is read-only, concurrent obsolete runs are cancelled,
  and the job has a 30-minute ceiling.
- The job reports its Xcode/Swift/SDK versions, treats strict-concurrency
  warnings as errors, runs XCTest plus deterministic logic, scrollbar, and
  native video suites, then packages and verifies the local release archive.
- CI explicitly skips only the two real Trash/restore cases. Those remain a
  required local pre-install/release gate because hosted Trash behavior is not
  a dependable product signal.
- No private Sparkle key is present or requested. CI performs the same
  structural feed/archive checks as routine local builds; publishing remains
  the owner's separate key-backed step.

Completed:

- Filter/sort/group/location behavior lives behind `PreparedPhotoFilter` and
  `PreparedSessionIndex`; selection behavior lives behind `SelectionState`.
- Four app-level selection cases verify filtering, range/toggle anchors, batch
  rating plus undo, and zero-match safety through `SessionStore`.

Remaining work:

- Add fault-injectable filesystem adapters for persistence and export tests.
- Add app-level assertions for recovery warnings, total save failure, and
  updater configuration/presentation.
- **Completed locally:** package/release preflight extracts `Louppe.zip`,
  verifies signing, checks every required Sparkle key, and validates the
  appcast structure. Publishing mode performs key-backed verification.
- Retain the existing real Trash/restore test locally because CI Trash
  behavior may differ.
- Add a disposable Sparkle signing key test if feed-generation behavior moves
  into CI; never upload the owner's real key.

Acceptance checks:

- Every P1 failure mode has a deterministic regression test.
- CI runs build, XCTest, logic, scrollbar, video, and release-package checks.
- A failed check names the user-visible behavior, not only an implementation
  function.

### P3-1 — Large state/view files slow safe changes

`SessionStore.swift` is about 2,000 lines and `FilterView.swift` about 850.
Both collect several separable responsibilities, which makes unrelated
changes harder to review and test.

Recommended extraction order:

1. **Completed:** `PreparedSessionIndex`: item IDs, filtering, sorting, stable
   groups, headers, and position maps.
2. **Completed:** `SelectionState`: explicit/stable selection, range, edge,
   toggle, rubber-band, filter intersection, and generation remapping.
3. `RatingHistory`: rating mutations, counts, and undo entries.
4. `FileOperationCoordinator`: cleanup/export state and recovery.
5. `SessionRepository`: persistence requests, health, and migrations.
6. `FilterEditorModel`: parsing, active-range rules, and facet selection.
7. Small Filter view sections that bind to the editor model.

Keep `SessionStore` as the main-actor facade passed to views. The goal is not
more observable objects; it is pure, testable components behind the existing
single source of truth.

Acceptance checks:

- No user-visible behavior or hotkey changes during extraction.
- Each extracted component has focused tests before old code is removed.
- `SessionStore` continues to publish UI state only from the main actor.

### P3-2 — Navigation lookup, measurement, and Grid identity completed

At the audit baseline, navigation and status paths repeatedly called
`visibleIndices.firstIndex(of:)`, while vertical movement also searched every
group.

Implemented:

- `rebuildVisibleGroups()` now builds one item-index → global/group location
  map in the same O(n) pass as group titles.
- Range selection, select-to-edge, horizontal and vertical navigation,
  next-undecided, full-image prefetch, filter visibility checks, and the
  toolbar's current position reuse O(1) lookups.
- The map is cleared with other derived session data and rebuilt only when
  filter/sort/group/session inputs invalidate it.
- A 5,000-item fixture verifies map correctness across reverse sorting,
  filtering, group sorting, and disabling group division.
- `PreparedSessionIndex` emits points-of-interest signposts around item-map,
  sort, filter, and group phases.
- Synthetic 1k, 10k, and 100k fixtures now record comparison baselines while
  asserting complete visible-location coverage.
- Groups use metadata-derived IDs that survive filtering their former first
  photo. Grid renders the groups directly without allocating
  `Array(enumerated())` on every body evaluation.

Remaining measurement work:

- Record release-mode CPU and peak-memory baselines with representative real
  folders before changing cache budgets or the lazy layouts.
- Do not replace the lazy Grid or Browser; their bounded rendering is a
  deliberate strength.

Acceptance checks:

- Derived-map correctness stays covered across sort/filter/group changes.
- Arrow-key navigation and selection update remain under one frame at the
  agreed large-folder target once signpost baselines exist.
- Memory growth is measured and documented alongside speed gains.

### P3-3 — Video and image async bridges should become structured

Video metadata and first-frame extraction bridge async AVFoundation APIs with
semaphores and timeouts. They work today but make cancellation and resource
ownership harder to reason about. A pathological batch can leave work
continuing after its caller times out.

Recommended change:

- Convert scanning and media probing to structured async functions with a
  bounded task group.
- Propagate cancellation to AVFoundation tasks and stop scheduling new probes.
- Keep the concurrency ceiling from `Docs/PERFORMANCE.md`.
- Cache explicit failure reasons—unsupported, corrupt, offline, permission,
  or timeout—so the UI can explain them.

Acceptance checks:

- Cancelling a scan rapidly stops new ImageIO/AVFoundation work.
- A batch of corrupt videos cannot create unbounded tasks or threads.
- Existing first-frame and native-playback tests remain green.

### P3-4 — Accessibility needs an intentional pass

The app is efficient from the keyboard, but several icon-only controls and
gesture-driven Grid cells need explicit VoiceOver semantics. Rating state must
not rely on green/red color alone, and drag/range selection needs accessible
alternatives.

Recommended change:

- Audit every toolbar button, thumbnail, rating badge, filter disclosure, and
  progress overlay with Accessibility Inspector and VoiceOver.
- Give each media tile a label, rating value, selection value, and actions for
  open/rate/select.
- Confirm full keyboard traversal and visible focus.
- Verify contrast in increased-contrast mode and motion in Reduce Motion.
- Add targeted accessibility-identifier/value assertions where UI automation
  is stable.

Acceptance checks:

- A photographer can open a folder, rate, filter, export, and check for
  updates with VoiceOver and keyboard only.
- Rating and selection are understandable without color.
- Every icon-only control announces an action and current state.

### P3-5 — Release preflight completed; diagnostics remain minimal

Most failures are currently collapsed into a short UI message or ignored.
There is no structured log for scan duration, cache behavior, persistence,
export, video probing, or updater startup.

Recommended change:

- Add privacy-aware `Logger` categories for session, scan, image cache, video,
  persistence, file operations, and updater.
- Add signposts around scan phases, filter preparation, thumbnail decode, and
  export batches.
- Offer “Copy Diagnostics” with versions, recent non-sensitive error codes,
  and performance counts—never photo paths unless the user explicitly opts in.
- **Completed:** automate release preflight and archive verification while
  keeping the real updater private key local/offline.
- Review Sparkle updates regularly and verify its pinned checksum when bumped.

Acceptance checks:

- A failure report can distinguish permissions, missing volumes, corrupt
  media, and updater/feed errors.
- Normal logs contain no image contents, credentials, or private signing key.
- Release preflight fails before upload when any security/version check is
  inconsistent.

## Recommended execution order

### Milestone 1 — File safety

1. **Completed:** build the shared export destination planner and pair-level
   Copy rollback (`P1-1`).
2. **Completed:** introduce the unified file-operation coordinator and safe
   Copy cancellation (`P1-2`).
3. **Completed:** add a durable Copy/Move/Trash/undo journal and launch
   recovery (`P1-3`).
4. **Completed:** validate export destinations and available space (`P2-1`).

Exit condition: power loss, Quit, collision, or a single-file failure cannot
silently split a pair or overwrite an existing file.

### Milestone 2 — Rating durability

1. **Completed:** return typed persistence results and expose save health
   (`P1-4`).
2. **Completed:** make sidecar/fallback precedence explicit and keep the
   backup current.
3. **Completed for schema v1:** validate the schema and preserve unsupported
   or corrupt data (`P2-4`).
4. **Completed:** replace termination blocking with asynchronous termination
   coordination.

Exit condition: Louppe always tells the photographer whether the latest
ratings are safely stored, and recoverable data is never silently discarded.

### Milestone 3 — Stable model and concurrency

1. **Completed:** scanning is deterministic, volume-aware, complete for deep
   folders, and explicit about loop prevention (`P2-2`, `P2-3`).
2. **Completed:** move selection and rating-history identity from array
   positions to stable IDs (`P2-5`).
3. **Completed:** fix the strict-concurrency warning groups and make Swift 6
   language mode the package default (`P2-6`).
4. **Completed for the current suites:** add a macOS 26 CI gate and extend
   coverage as each seam becomes testable (`P2-9`).

Exit condition: a full Swift 6 language-mode build and every test suite pass
with zero concurrency warnings.

### Milestone 4 — Architecture and measured performance

1. Extract pure prepared-index, selection, rating-history, persistence, and
   filter-editor components (`P3-1`).
2. **Completed for prepared indexing:** add signposts and representative
   1k/10k/100k structural baselines.
3. **Completed:** optimize navigation maps and stable Grid group identity
   without changing the lazy layouts (`P3-2`).
4. Replace semaphore-based media probing with structured async work (`P3-3`).
5. Implement accurate, memory-bounded 100% zoom (`P2-7`).

Exit condition: the measured large-folder targets are documented and met
without increasing UI-thread work or cache budgets unexpectedly.

### Milestone 5 — Release quality and inclusive UX

1. Complete the keyboard and VoiceOver audit (`P3-4`).
2. Add structured diagnostics; release preflight is complete (`P3-5`).
3. Back up and restore-test the updater key; add Developer ID signing and
   notarization when the owner is ready (`P1-5`).

Exit condition: releases are repeatable, first install is trusted by macOS,
and the primary workflow is usable without sight or a pointing device.

## Guardrails for carrying out the plan

- Preserve the bundle identifier, sidecar filename, accent/background rules,
  hotkey documentation, and original-file protections in `AGENTS.md`.
- Treat each milestone as a set of small behavior-preserving changes. Add its
  regression test before or with each change.
- Run the focused logic test first, then all relevant suites, package the app,
  install it, strict-verify it, and perform a real `-openFolder` launch.
- Do not optimize a path until a representative baseline demonstrates the
  problem.
- Do not add a database, networking layer, or broad framework solely to split
  files; the existing SwiftPM/AppKit/SwiftUI design is appropriate.
- Do not automate access to the updater's private key in ordinary builds or
  pull requests.

# Louppe codebase audit and improvement plan

Audit date: 2026-07-26

This audit covers the complete application source, build and release scripts,
documentation, and test suites. The current codebase is about 7,400 lines of
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
- 31/31 performance, persistence, cleanup, and export checks.
- 9/9 scrollbar behavior checks.
- 18/18 native video checks.
- 5/5 XCTest cases.
- Signed Sparkle feed, signed archive metadata, embedded updater framework,
  and extraction/signature verification of the release zip.

A Swift build with complete strict-concurrency diagnostics also succeeds, but
it reports warnings in `FolderScanner`, `ExportManager`, `VideoSupport`, and
`VideoPlaybackController`. Those warnings become compile errors after moving
the package to Swift 6 language mode, so they should be treated as migration
work rather than ignored.

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

### P1-1 — Copy export does not keep a RAW+JPEG pair transactional

`ExportWorker.copy` flattens all selected items into one file list and copies
each file independently. If the first half of a pair copies and the second
fails, the destination contains a partial pair even though Louppe presents the
pair as one photo.

There is a related naming problem in both Copy and Move: collision suffixes
are selected independently for each file. For example, if `SHOT.NEF` already
exists but `SHOT.JPG` does not, a new pair can become `SHOT (1).NEF` and
`SHOT.JPG`. They no longer share a basename and may not pair when the
destination is opened in Louppe.

Recommended change:

1. Add an `ExportPlan` that reserves every destination URL before touching the
   filesystem.
2. Choose one shared suffix per `PhotoItem`, so every member of a pair keeps
   the same basename.
3. Copy one photo at a time. If a member fails, remove the members copied for
   that photo and report one failed photo, not just one failed file.
4. Use a small staging directory inside the destination when it is on the same
   volume, then rename completed files into place.

Acceptance checks:

- A collision against either pair member gives both files the same suffix.
- An injected second-file failure leaves no partial copy in the destination.
- Existing destination files are never replaced.
- A failed photo does not prevent later photos from being attempted.
- Copy and Move share the same tested destination-planning rules.

### P1-2 — Copy export is not represented as an active file operation

`SessionStore.isMovingExport` protects Move export, but there is no equivalent
state for Copy. The export sheet cannot be dismissed while working, yet the
application can still quit or begin an updater-driven relaunch while a long
copy is in progress. That can leave a partial destination with no useful
explanation to the photographer.

Recommended change:

- Replace the separate cleanup/move flags with a single
  `FileOperationCoordinator` whose state describes scanning, copying, moving,
  trashing, or restoring.
- Block Quit, folder replacement, rescan, conflicting commands, and update
  installation for every state that cannot be safely interrupted.
- Add explicit cancellation to Copy. Cancellation should finish or roll back
  the photo currently being copied, retain completed photos, and report the
  exact result.
- Make the updater consult the same coordinator before allowing a relaunch.

Acceptance checks:

- Quit and update installation cannot interrupt a copy between pair members.
- Buttons and menu commands derive their enabled state from one source.
- Cancelling reports completed, skipped, and failed photo/file counts.
- Moving originals remains available only through the two sanctioned paths.

### P1-3 — File-operation rollback is memory-only

Clean Up and Move correctly block normal Quit and roll back a partial pair
when a call fails. A crash, forced quit, power loss, disconnected SD card, or
system restart can still occur between moving the first and second file.
Because rollback data exists only in memory, the next launch cannot explain
or repair that state.

Recommended change:

- Before the first move, atomically write a compact operation journal in
  Application Support. Record operation ID, source and destination paths,
  planned members, and each completed step.
- Flush a step before and after each filesystem move.
- Remove the journal only after the operation and session state are safely
  committed.
- On launch, detect an unfinished journal and offer a plain-language choice:
  restore the source state or complete the operation.
- Never infer that a missing file was intentionally deleted.

Acceptance checks:

- A test process terminated after moving one member can recover on next run.
- Recovery is idempotent; running it twice does not move or overwrite files.
- A disconnected volume pauses recovery and names the missing volume.
- Journals contain paths and state only, never image data or credentials.

### P1-4 — Session persistence failures are invisible

`SessionPersistence.save` silently returns when encoding, sidecar writing, and
fallback writing fail. `read` also treats an unreadable or corrupt session as
if no session existed. The UI therefore cannot tell the photographer that
recent ratings might not have been saved.

The fallback file can also become stale. A later successful sidecar save does
not refresh or remove an older Application Support fallback, so a missing or
corrupt sidecar can resurrect older ratings.

Recommended change:

- Return a typed save result: sidecar saved, fallback saved, retryable failure,
  or permanent failure.
- Publish persistence health in `SessionStore` and show a non-blocking warning
  when ratings are not currently safe.
- Keep a last-known-good backup before replacing a decodable session.
- When the sidecar succeeds, either update the fallback snapshot or remove it.
- Distinguish “no session,” “unsupported version,” “corrupt session,” and
  “permission denied.”
- Use AppKit's asynchronous terminate-later flow instead of blocking the main
  thread with a semaphore for up to three seconds.

Acceptance checks:

- Simulated permission and disk-full errors appear in the UI and can retry.
- A corrupt sidecar never silently overwrites the last-known-good session.
- The newest successful snapshot always wins across sidecar and fallback.
- Quitting after a last-second rating either saves it or clearly refuses Quit.

### P1-5 — Updater release signing has a single-key operational risk

The updater itself now verifies a signed feed and signed archives. Existing
updater-enabled copies of Louppe depend on the matching private Ed25519 key,
which is stored in the release owner's Keychain. Loss of that key would make a
normal trusted update path impossible.

Recommended change:

- Make an encrypted offline backup of the exported private key and test one
  restore on a separate macOS account.
- Keep `Docs/UPDATES.md` as the release checklist and require its verification
  steps before publishing.
- Add a release preflight that verifies version/build, archive signature,
  appcast signature, enclosure URL, minimum macOS version, and that the
  archive has not changed since signing.
- When practical, use Developer ID signing, hardened runtime, and Apple
  notarization. Sparkle's signature remains necessary; notarization solves
  first-install trust and reduces Gatekeeper friction.

Acceptance checks:

- The backup can sign a disposable feed that the app's public key verifies.
- A release cannot pass preflight with a stale feed or changed archive.
- No private signing material is stored in Git, the app bundle, or build logs.

### P2-1 — Export destinations are not validated against the source tree

The folder picker allows the source folder or one of its descendants. Copying
into the source tree can cause duplicates to appear on the next scan. Moving
into a child folder makes photos leave and then reappear under a different
relative path. This is surprising and complicates session ratings.

Recommended change:

- Resolve standardized and file-resource paths for source and destination.
- Reject the exact source folder.
- Warn and require a deliberate second confirmation for a descendant
  destination, or reject descendants entirely for Move.
- Preflight destination writability and available capacity before starting.

Acceptance checks:

- Symlinked paths cannot bypass the source/descendant check.
- Same-folder Move never becomes an accidental rename.
- The dialog explains why an unsafe destination is unavailable.

### P2-2 — RAW+JPEG choice is not deterministic in duplicate-name edge cases

`FolderScanner` groups by a lowercased extensionless path and selects
`raws.first` and `jpegs.first`. Filesystem enumeration and dictionary order
are not an interface guarantee. A folder containing unusual duplicates such
as `.jpg` and `.jpeg`, or case-only filename differences on a case-sensitive
volume, may pair a different combination after a rescan.

Recommended change:

- Sort discovered URLs by standardized relative path before grouping.
- Define and test a stable extension preference when more than one RAW or
  JPEG candidate exists.
- Preserve case-sensitive identities while using a separate normalized key
  only where the volume's behavior permits it.
- Log ambiguous groups and present their leftovers as independent items.

Acceptance checks:

- Repeated scans of the same tree create identical item IDs and pairs.
- Reversing enumerator input order does not change the result.
- Case-sensitive-volume fixtures do not merge distinct photos.

### P2-3 — The fixed scan-depth limit silently omits deep folders

Scanning stops below depth five to avoid pathological trees. The enumerator
already does not follow package descendants, and normal symbolic-link
handling can be made explicit. A photographer with a legitimate deeper
archive receives no notice that media was omitted.

Recommended change:

- Prefer an explicit loop-safe recursive policy using resource identifiers.
- If the limit is retained, count skipped directories and tell the user.
- Add a setting only if real-world measurements show that a configurable
  depth is necessary; do not expose implementation detail by default.

Acceptance checks:

- Deep fixtures are either scanned or produce a visible skipped-folder count.
- Symlink loops and packages do not cause unbounded traversal.
- Cancellation remains responsive on very large trees.

### P2-4 — Session schema fields are written but not validated

The sidecar contains `version` and `sourcePath`, but reads decode and apply it
without an explicit schema-version decision. Future model changes could either
fail silently or interpret data with the wrong assumptions. A copied sidecar
may also describe a different source path.

Recommended change:

- Introduce explicit decoding and migration per supported schema version.
- Reject unknown future versions with a warning while preserving the file.
- Decide and document whether copying a whole folder should intentionally
  carry ratings. If yes, accept the path mismatch but update `sourcePath` on
  the next save; if no, ask before importing.
- Add a `lastSuccessfulSave` value for diagnostics.

Acceptance checks:

- Old fixtures migrate deterministically.
- Future-version and malformed fixtures never get overwritten automatically.
- The source-path policy is covered by tests and visible to the user.

### P2-5 — Selection and navigation rely heavily on array indices

The current model is carefully defended, but `selectedIndices`,
`visibleIndices`, undo snapshots, and navigation positions remain coupled to
the current order of `items`. Every structural mutation must clear or remap
indices correctly. This is the class of state that caused the earlier stale
visible-index crash.

Recommended change:

- Keep `PhotoItem.id` as the stable selection and undo identity.
- Maintain an `id → item index` map rebuilt with other derived data.
- Store visible item IDs or a versioned prepared index whose lifetime is tied
  to the current item generation.
- Preserve current behavior where an empty multi-selection means “current
  photo only,” but give that concept an explicit type.

Acceptance checks:

- Reorder, filter, rescan, cleanup, and restore tests preserve the intended
  current photo and selection by ID.
- No public operation can observe indices created for an older item
  generation.
- Browser and Grid follow-scroll behavior remains unchanged.

### P2-6 — Swift 6 strict-concurrency migration is not complete

The package currently compiles in Swift 5 language mode. Complete diagnostics
identify these concrete migration areas:

- `FolderScanner`: a non-Sendable cancellation closure and a concurrent
  mutable `UnsafeMutableBufferPointer` capture.
- `ExportManager`: a main-actor callback captured by `Task.detached`.
- `VideoSupport`: concurrent `async let` access to the same AVFoundation track.
- `VideoPlaybackController`: non-Sendable notification observer tokens
  accessed from a nonisolated deinitializer.

Recommended change:

- Replace the scanner's buffer mutation with a structured task group returning
  indexed chunks, and make cancellation explicitly `@Sendable`.
- Give export work a Sendable request/result boundary; invoke callbacks only
  after returning to `MainActor`.
- Load AVFoundation track properties sequentially unless measurement proves
  the tiny parallel gain matters.
- Own observer cleanup on the main actor or use token wrappers with an
  explicit isolation policy.
- Enable strict-concurrency warnings in the normal build immediately, then
  switch the language mode only after the warnings reach zero.

Acceptance checks:

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

### P2-8 — Some file-count and size labels are misleading

The multi-selection panel says “files selected,” but its count is the number
of `PhotoItem` values. A RAW+JPEG pair counts as one selected item while
representing two files. Single-item metadata also reports the primary file's
size rather than the pair's combined size.

Recommended change:

- Say “photos selected” or “items selected.”
- When useful, show both counts: “12 photos · 19 files.”
- Show primary and paired sizes separately plus their total.
- Use “media items” when a selection contains video.

Acceptance checks:

- Pair, unpaired photo, video, and mixed-selection fixtures produce accurate
  wording and totals.
- No destructive confirmation understates the number of filesystem entries.

### P2-9 — Automated coverage is useful but narrow

The focused suites exercise important algorithms, yet only five XCTest cases
currently cover app-level behavior. There is no repository CI workflow.
Important untested seams include updater configuration, session failure
states, filter combinations, selection across structural changes, export
preflight, pair collision planning, update release packaging, and
accessibility labels.

Recommended change:

- Move pure filter/sort/selection logic behind small types that XCTest can
  instantiate without a window.
- Add fault-injectable filesystem adapters for persistence and export tests.
- Add a package/release test that extracts `Louppe.zip`, verifies signing,
  checks every required Sparkle key, and verifies the appcast.
- Add GitHub Actions using the current macOS/Xcode image. PR builds require no
  private updater key; signing-feed tests use a disposable key.
- Retain the existing real Trash/restore test locally because CI Trash
  behavior may differ.

Acceptance checks:

- Every P1 failure mode has a deterministic regression test.
- CI runs build, XCTest, logic, scrollbar, video, and release-package checks.
- A failed check names the user-visible behavior, not only an implementation
  function.

### P3-1 — Large state/view files slow safe changes

`SessionStore.swift` is about 1,500 lines and `FilterView.swift` about 850.
Both collect several separable responsibilities, which makes unrelated
changes harder to review and test.

Recommended extraction order:

1. `PreparedSessionIndex`: filtering, sorting, day groups, position maps.
2. `SelectionState`: current item, explicit selection, range operations.
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

### P3-2 — Navigation has avoidable linear searches

Several navigation and status paths call `visibleIndices.firstIndex(of:)`.
Vertical movement also searches groups. This is acceptable for ordinary
folders, but it becomes repeated O(n) work during keyboard navigation in very
large sessions.

Recommended change:

- First add signposts and baseline folders at 1k, 10k, and 100k items.
- If navigation exceeds one display frame, cache item-index/ID to visible
  position and group/row position as part of `PreparedSessionIndex`.
- Give day groups stable IDs and avoid `Array(enumerated())` allocations in
  every Grid render.
- Do not replace the lazy Grid or Browser; their bounded rendering is a
  deliberate strength.

Acceptance checks:

- Arrow-key navigation and selection update remain under one frame at the
  agreed large-folder target.
- Derived maps rebuild only after inputs that can invalidate them.
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

### P3-5 — Diagnostics and release automation are minimal

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
- Automate release preflight and archive verification while keeping the real
  updater private key local/offline.
- Review Sparkle updates regularly and verify its pinned checksum when bumped.

Acceptance checks:

- A failure report can distinguish permissions, missing volumes, corrupt
  media, and updater/feed errors.
- Normal logs contain no image contents, credentials, or private signing key.
- Release preflight fails before upload when any security/version check is
  inconsistent.

## Recommended execution order

### Milestone 1 — File safety

1. Build the shared export destination planner and pair-level Copy rollback
   (`P1-1`).
2. Introduce the unified file-operation coordinator and safe Copy cancellation
   (`P1-2`).
3. Add a durable move/trash journal and launch recovery (`P1-3`).
4. Validate export destinations and available space (`P2-1`).

Exit condition: power loss, Quit, collision, or a single-file failure cannot
silently split a pair or overwrite an existing file.

### Milestone 2 — Rating durability

1. Return typed persistence results and expose save health (`P1-4`).
2. Make sidecar/fallback precedence explicit.
3. Add schema migration and corruption handling (`P2-4`).
4. Replace termination blocking with asynchronous termination coordination.

Exit condition: Louppe always tells the photographer whether the latest
ratings are safely stored, and recoverable data is never silently discarded.

### Milestone 3 — Stable model and concurrency

1. Make scanning and pair choice deterministic (`P2-2`, `P2-3`).
2. Move selection/navigation identity from array positions to stable IDs
   (`P2-5`).
3. Fix the strict-concurrency warning groups and enable them in normal builds
   (`P2-6`).
4. Add coverage and CI as each seam becomes testable (`P2-9`).

Exit condition: a full Swift 6 language-mode build and every test suite pass
with zero concurrency warnings.

### Milestone 4 — Architecture and measured performance

1. Extract pure prepared-index, selection, rating-history, persistence, and
   filter-editor components (`P3-1`).
2. Add signposts and representative 1k/10k/100k baselines.
3. Optimize navigation maps and stable Grid group identity only where the
   measurements justify it (`P3-2`).
4. Replace semaphore-based media probing with structured async work (`P3-3`).
5. Implement accurate, memory-bounded 100% zoom (`P2-7`).

Exit condition: the measured large-folder targets are documented and met
without increasing UI-thread work or cache budgets unexpectedly.

### Milestone 5 — Release quality and inclusive UX

1. Correct file/item wording and paired size display (`P2-8`).
2. Complete the keyboard and VoiceOver audit (`P3-4`).
3. Add structured diagnostics and release preflight (`P3-5`).
4. Back up and restore-test the updater key; add Developer ID signing and
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

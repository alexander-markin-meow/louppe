# Louppe — guidance for AI assistants

Native macOS photo-culling app. Swift/SwiftUI, plain SwiftPM executable —
**no Xcode project**. Apple Command Line Tools 26.6 are selected; full Xcode
26.6 is also installed but is not required. Both currently expose Swift 6.3.3
and the macOS 26.5 SDK.

The owner is a photographer, not a programmer: do the technical work for him,
explain results in plain language, and always verify the app actually launches
after changes.

## Build & install

```sh
./build_app.sh                          # release build → dist/Louppe.app
cp -R dist/Louppe.app /Applications/    # install (remove old copy first)
xattr -cr /Applications/Louppe.app      # copy can attach Finder metadata
codesign --verify --deep --strict /Applications/Louppe.app
swift build                             # quick debug check with the selected Xcode toolchain
```

`build_app.sh` bundles the binary + icon + Info.plist in `/private/tmp`, strips
extended attributes, ad-hoc signs, verifies there, then copies the result to
`dist/`. Staging outside the File Provider-managed workspace is required:
Finder metadata may otherwise reappear between signing and verification. Still
run `xattr -cr` after copying into `/Applications`.

`VERSION` is the source of truth for the About-panel marketing version and
build number. Every shipped release or update must use a new version/build pair
with a matching entry in `CHANGELOG.md`; development changes stay in the
current unreleased entry until it ships. `build_app.sh` deliberately refuses
to package a pair missing from the history. History headings use
`## <MARKETING_VERSION> (<BUILD_NUMBER>) — <DATE>`. Keep release tags in the
form `v<MARKETING_VERSION>`.

Always build against the current macOS SDK. Do not work around toolchain errors
with an older SDK: doing so compiles out current SwiftUI features such as macOS
26 liquid-glass toolbar styling.

## Testing a build

Run the focused logic tests first, then verify by launching with a folder:

```sh
./Tests/run_performance_checks.sh
```

The last two checks use disposable files for a real Trash/restore round trip.
In a restricted agent sandbox, rerun the script with permission to access the
macOS Trash if those checks report that the paired photo could not move.

```sh
open /Applications/Louppe.app --args -openFolder /path/to/photos
```

**Never pass a bare path argument** (`--args /path`): macOS treats it as a
document-open request, and because the app declares no document types the
system suppresses the app's default window — the app runs headless and
appears broken. The `-openFolder` flag form avoids this entirely.

The app writes `.louppe_session.json` into the opened folder within a few
seconds; inspect it from the CLI to confirm scanning/pairing/rating logic
without seeing the screen. Screen capture is NOT available for verification
(no Screen Recording permission) — ask the user to look, or check the sidecar.

## Architecture

One `SessionStore` (a `@MainActor ObservableObject`) is the single source of
truth, created in `LouppeApp` and passed to every view.

| File | Responsibility |
|---|---|
| `Sources/Louppe/LouppeApp.swift` | `@main`, window scene, menu-bar commands |
| `Sources/Louppe/SessionStore.swift` | Main-actor session state: ratings/cached counts, undo, navigation, selection, prepared filtering + cached sort/day groups, clean-up orchestration, persistence snapshots, recents |
| `Sources/Louppe/SessionPersistence.swift` | Actor that serializes sidecar JSON encoding, reading, and atomic/fallback writes off-main |
| `Sources/Louppe/CleanUpWorker.swift` | Background Trash/restore file loops, progress throttling, pair rollback, O(n+k) restoration merge |
| `Sources/Louppe/FolderScanner.swift` | Recursive folder scan, RAW+JPEG pairing, chronological sort |
| `Sources/Louppe/ImagePipeline.swift` | ImageIO decoding, thumbnail memory+disk caches, prefetching |
| `Sources/Louppe/MetadataExtractor.swift` | EXIF reading for capture dates + info panel |
| `Sources/Louppe/ExportManager.swift` | Copies keepers to a destination, collision-suffixing |
| `Sources/Louppe/Models.swift` | `PhotoItem`, `Rating`, `PhotoFilter`, sidecar codables |
| `Sources/Louppe/Views/RootView.swift` | Phase switch (welcome/scanning/session), `Color.appBackground` |
| `Sources/Louppe/Views/WelcomeView.swift` | Start screen + cancellable scanning progress |
| `Sources/Louppe/Views/SessionView.swift` | Toolbar (incl. sort menu), export sheet, **all single-key hotkeys** (`handleKey`) |
| `Sources/Louppe/Views/FilterView.swift` | Toolbar filter popover: metadata search, date range, subfolder / file-type / camera / lens toggles |
| `Sources/Louppe/Views/GalleryView.swift` | Gallery layout: Browser / photo / info panel |
| `Sources/Louppe/Views/BrowserView.swift` | Optional vertical thumbnail Browser with day separators |
| `Sources/Louppe/Views/GridView.swift` | Grid view, day-grouped rows, click-to-rate, rubber-band selection |
| `Sources/Louppe/Views/MetadataPanel.swift` | Info panel (filename header, camera, exposure row, fields) |
| `Sources/Louppe/Views/ThumbnailView.swift` | Async thumbnail tile + rating badge |
| `Sources/Louppe/Views/FullImageView.swift` | Large photo with fit / 100% / phone-size zoom |
| `Sources/Louppe/Views/ExportView.swift` | Export dialog (summary → progress → done) |
| `Tests/PerformanceChecks/main.swift` | Dependency-free search, ordered persistence, and restoration-merge regression checks |

See `Docs/PERFORMANCE.md` before changing concurrency, caching, filtering, or
Clean Up. It records ownership boundaries, cache budgets, and verification.

## Invariants — do not change

- **Bundle identifier** `com.alexandermarkin.louppe` and **sidecar filename**
  `.louppe_session.json`. (Renamed from the original "loupe" spellings on
  2026-07-12 with the owner's consent — old sessions and folder permissions
  were intentionally abandoned. Don't rename again without asking: it resets
  saved ratings and macOS folder permissions.)
- **Originals are never modified, moved, or deleted.** Export only copies.
  The single sanctioned exception (added 2026-07-13 at the owner's request) is
  Clean Up in `SessionStore`: it moves rejected files to the macOS Trash via
  `FileManager.trashItem` — never a permanent delete — behind a confirmation
  dialog, and ⌘Z restores the whole batch. Keep it that way: no hard deletes,
  no moves anywhere but the Trash, and no *single-key* hotkey for it (⌘⌫
  trashing the selection without a dialog is the one sanctioned shortcut,
  added 2026-07-13 at the owner's request — Finder parallel, ⌘Z restores).
- The hotkey map lives in `SessionView.handleKey` and is documented in
  README's shortcut table — keep the two in sync when changing keys.
- One background gray everywhere: `Color.appBackground`. Don't introduce
  other panel shades; use `Divider()` lines to separate regions.
- One accent color everywhere: `Color.louppeAccent`, the brand purple
  #9853A6 (defined in RootView.swift, applied as a global `.tint` and used
  for the app-icon glyph). Green/red stay reserved for yes/no ratings; don't
  use blue or `Color.accentColor` for anything.

## Known gotchas

- Toolbar Liquid Glass groups follow the owner's arrangement in
  `SessionView.toolbarContent` and use Apple's native fixed `ToolbarSpacer`.
  macOS 26 may show little or no extra separation in the `.navigation`
  placement and wider trailing gaps; the owner explicitly prefers that native
  result to custom equal-width spacing. Do not add custom spacer views.

- **`visibleIndices` must never outlive `items`**: any place that replaces or
  empties `items` must reset/recompute `visibleIndices` in the same turn
  (see `openFolder`) — stale indices crashed the app on re-scan once.
  `visibleItems` bounds-checks as a backstop; keep it that way.
- **ImageIO embedded thumbnails**: many JPEGs embed a tiny (~160px) preview.
  `ImagePipeline.decode` asks for the fast embedded path first and falls back
  to a full decode when the result is undersized — removing that fallback
  brings back blurry/pixelated previews.
- **Derived session data is explicit**: rating counts update incrementally;
  filter facets and sorted indices rebuild after structural `items` changes.
  Any new code that inserts/removes/replaces photos must call
  `rebuildDerivedData()` before `applyFilter()`.
- **Clean Up has a three-phase boundary**: snapshot on `SessionStore`, file I/O
  in `CleanUpWorker`, apply on `SessionStore`. Do not put `trashItem`/`moveItem`
  loops back on the main actor. While `isCleaningUp`, keep item-index mutations
  blocked, folder switching disabled, and Quit refused so pair rollback and ⌘Z
  remain exact.
- `RootView` owns the persistent window's phase-aware content layout through
  `WindowContentLayout`: Welcome/Scanning use `.fullSizeContentView`, while
  Ready removes it so photos cannot scroll behind the liquid-glass toolbar.
  This flag does not choose the window radius. Welcome and Scanning include a
  real unified toolbar (`LaunchToolbarTitle`) so macOS 26 supplies its larger
  native toolbar-window corners; never fake them with a custom window mask.
- Thumbnails letterbox (`fit`) inside square tiles on purpose — fill-mode
  cropping both hid parts of the photo and let portrait images overflow
  their tiles.
- **Multi-selection model**: `selectedIndices` empty = "just the current
  photo" (`effectiveSelection` handles both cases). Anything that mutates or
  reorders `items` (open/re-scan, clean-up, undo) must clear the selection;
  `applyFilter` intersects it with `visibleIndices`. The Grid-view rubber
  band hit-tests tile frames collected via a `PreferenceKey`, so only
  *rendered* (on-screen) lazy-grid tiles can be caught by the rectangle —
  fine in practice, but don't "fix" it by de-lazifying the grid.
- If the app ever launches with no window visible, suspect corrupted window
  restoration state: `defaults delete com.alexandermarkin.louppe` and
  `rm -rf ~/Library/Saved\ Application\ State/com.alexandermarkin.louppe.savedState`.

## Repo conventions

- GitHub: `alexander-markin-meow/louppe` (public). Commit/push only when the
  owner asks; he reviews PRs via the GitHub UI "Merge" button or asks here.
- **Use `main` only.** Do not create or retain local or remote feature branches
  unless the owner explicitly asks for one. Commit directly to `main` only when
  asked; after any exceptional branch is merged, delete it both locally and on
  GitHub.
- `dist/` and `.build/` are gitignored build products; `AppIcon/` holds the
  source glyph and the built `.icns` (both tracked).

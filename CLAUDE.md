# Louppe — guidance for AI assistants

Native macOS photo-culling app. Swift/SwiftUI, plain SwiftPM executable —
**no Xcode project**. Only Apple Command Line Tools are installed on this
machine (no full Xcode).

The owner is a photographer, not a programmer: do the technical work for him,
explain results in plain language, and always verify the app actually launches
after changes.

## Build & install

```sh
./build_app.sh                          # release build → dist/Louppe.app
cp -R dist/Louppe.app /Applications/    # install (remove old copy first)
swift build                             # quick compile check (debug)
```

`build_app.sh` bundles the binary + icon + Info.plist, strips extended
attributes (`xattr -cr` — REQUIRED, or codesign fails with a "detritus"
error), and ad-hoc codesigns.

## Testing a build

There are no automated tests. Verify by launching with a folder:

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
| `Sources/Louppe/SessionStore.swift` | Session state: ratings, undo (batched), navigation, filtering (`visibleIndices`), sidecar persistence, recents |
| `Sources/Louppe/FolderScanner.swift` | Recursive folder scan, RAW+JPEG pairing, chronological sort |
| `Sources/Louppe/ImagePipeline.swift` | ImageIO decoding, thumbnail memory+disk caches, prefetching |
| `Sources/Louppe/MetadataExtractor.swift` | EXIF reading for capture dates + info panel |
| `Sources/Louppe/ExportManager.swift` | Copies keepers to a destination, collision-suffixing |
| `Sources/Louppe/Models.swift` | `PhotoItem`, `Rating`, `PhotoFilter`, sidecar codables |
| `Sources/Louppe/Views/RootView.swift` | Phase switch (welcome/scanning/session), `Color.appBackground` |
| `Sources/Louppe/Views/WelcomeView.swift` | Start screen + scanning progress |
| `Sources/Louppe/Views/SessionView.swift` | Toolbar, export sheet, **all single-key hotkeys** (`handleKey`) |
| `Sources/Louppe/Views/FilterView.swift` | Toolbar filter popover: metadata search, date range, file-type toggles |
| `Sources/Louppe/Views/CullingView.swift` | Single-photo layout: filmstrip / photo / info panel |
| `Sources/Louppe/Views/FilmstripView.swift` | Vertical thumbnail browser with day separators |
| `Sources/Louppe/Views/LightTableView.swift` | Grid view, day-grouped rows, click-to-rate |
| `Sources/Louppe/Views/MetadataPanel.swift` | Info panel (filename header, camera, exposure row, fields) |
| `Sources/Louppe/Views/ThumbnailView.swift` | Async thumbnail tile + rating badge |
| `Sources/Louppe/Views/FullImageView.swift` | Large photo with fit / 100% / phone-size zoom |
| `Sources/Louppe/Views/ExportView.swift` | Export dialog (summary → progress → done) |

## Invariants — do not change

- **Bundle identifier** `com.alexandermarkin.louppe` and **sidecar filename**
  `.louppe_session.json`. (Renamed from the original "loupe" spellings on
  2026-07-12 with the owner's consent — old sessions and folder permissions
  were intentionally abandoned. Don't rename again without asking: it resets
  saved ratings and macOS folder permissions.)
- **Originals are never modified, moved, or deleted.** Export only copies.
- The hotkey map lives in `SessionView.handleKey` and is documented in
  README's shortcut table — keep the two in sync when changing keys.
- One background gray everywhere: `Color.appBackground`. Don't introduce
  other panel shades; use `Divider()` lines to separate regions.
- One accent color everywhere: `Color.louppeAccent`, the brand purple
  #9853A6 (defined in RootView.swift, applied as a global `.tint` and used
  for the app-icon glyph). Green/red stay reserved for yes/no ratings; don't
  use blue or `Color.accentColor` for anything.

## Known gotchas

- **`visibleIndices` must never outlive `items`**: any place that replaces or
  empties `items` must reset/recompute `visibleIndices` in the same turn
  (see `openFolder`) — stale indices crashed the app on re-scan once.
  `visibleItems` bounds-checks as a backstop; keep it that way.
- **ImageIO embedded thumbnails**: many JPEGs embed a tiny (~160px) preview.
  `ImagePipeline.decode` asks for the fast embedded path first and falls back
  to a full decode when the result is undersized — removing that fallback
  brings back blurry/pixelated previews.
- The window content is deliberately laid out *below* the liquid-glass
  toolbar (`BelowToolbarLayout` removes `.fullSizeContentView`) so thumbnails
  can't scroll behind it.
- Thumbnails letterbox (`fit`) inside square tiles on purpose — fill-mode
  cropping both hid parts of the photo and let portrait images overflow
  their tiles.
- If the app ever launches with no window visible, suspect corrupted window
  restoration state: `defaults delete com.alexandermarkin.louppe` and
  `rm -rf ~/Library/Saved\ Application\ State/com.alexandermarkin.louppe.savedState`.

## Repo conventions

- GitHub: `alexander-markin-meow/louppe` (public). Commit/push only when the
  owner asks; he reviews PRs via the GitHub UI "Merge" button or asks here.
- `dist/` and `.build/` are gitignored build products; `AppIcon/` holds the
  source glyph and the built `.icns` (both tracked).

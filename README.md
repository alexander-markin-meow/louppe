# Louppe: Photo Culling App

Fast, keyboard-driven macOS app for reviewing a folder of photos and marking
each one **Yes** (keep) or **No** (reject), then exporting the keepers to a new
folder. Originals are never modified, moved, or deleted.

## Using the app

The finished app is installed at **/Applications/Louppe.app** — open it like any
other app. Pick a folder (an SD card works), review, then press **⌘E** to export.

### Keyboard shortcuts

| Key | Action |
|---|---|
| → | Next photo |
| ← | Previous photo |
| Space | Next photo without rating |
| F | Mark Yes, jump to next undecided |
| D | Mark No, jump to next undecided |
| S | Toggle 100% zoom / fit |
| A | Toggle phone-sized preview / fit |
| Tab / G | Switch Main ↔ Light Table view |
| E | Export |
| Q | Show/hide the browser (thumbnail column) |
| W | Show/hide the info panel |
| R | Clear all ratings (one ⌘Z brings them all back) |
| ⌘R | Re-scan folder for new photos |
| ⌘+ / ⌘− | Bigger / smaller thumbnails in the Light Table |
| ⌘Z | Undo last rating |
| ⌘E | Export |
| ⌘O | Open a different folder |

In the **Light Table** grid: single-click a photo to cycle its rating
(undecided → yes → no), double-click to open it big in the main view.

### Where things are stored

- Ratings: a hidden `.loupe_session.json` file inside the photo folder
  (or in `~/Library/Application Support/Loupe/Sessions/` if the folder is
  read-only, e.g. a locked SD card). Reopening a folder resumes the session.
- Thumbnails cache: `~/Library/Caches/Loupe/` (safe to delete anytime).

## Rebuilding from source

Requires Apple's Command Line Tools (already installed). From this folder:

```
./build_app.sh
```

The fresh app appears at `dist/Louppe.app`. Copy it to `/Applications` to install.

## Source layout

- `Sources/Loupe/LoupeApp.swift` — app entry point, menu commands
- `Sources/Loupe/SessionStore.swift` — folder scanning, RAW+JPEG pairing, ratings, undo, session persistence
- `Sources/Loupe/ImagePipeline.swift` — image decoding (ImageIO embedded previews), thumbnail cache, prefetching
- `Sources/Loupe/Metadata.swift` — EXIF extraction for the info panel
- `Sources/Loupe/ExportManager.swift` — copying keepers, filename collision handling
- `Sources/Loupe/ContentView.swift` — welcome screen, keyboard handling, toolbar
- `Sources/Loupe/MainCullingView.swift` — big image + filmstrip + info panel
- `Sources/Loupe/LightTableView.swift` — grid view
- `Sources/Loupe/ExportView.swift` — export dialog

Supported formats: `.NEF`, `.RAF`, `.JPG`, `.JPEG`, `.TIF`, `.TIFF`.

# Louppe: Photo Culling App

Fast, keyboard-driven open source macOS app for reviewing a folder of photos and marking
each one **Yes** (keep) or **No** (reject), then exporting the keepers to a new
folder. Originals are never modified, moved, or deleted.

## Download

Grab the latest build from **[Releases](https://github.com/alexander-markin-meow/louppe/releases/latest)** — download `Louppe.zip`, unzip, drag `Louppe.app` into Applications.

This app isn't notarized by Apple, so on first launch macOS will warn it can't verify the developer. Right-click the app → **Open** → **Open** again in the dialog. That's a one-time step; it opens normally after that.

## Using the app

Pick a folder (an SD card works), review, then press **⌘E** to export.

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

- Ratings: a hidden `.louppe_session.json` file inside the photo folder
  (or in `~/Library/Application Support/Louppe/Sessions/` if the folder is
  read-only, e.g. a locked SD card). Reopening a folder resumes the session.
- Thumbnails cache: `~/Library/Caches/Louppe/` (safe to delete anytime).

## Rebuilding from source

Requires Apple's Command Line Tools (already installed). From this folder:

```
./build_app.sh
```

The fresh app appears at `dist/Louppe.app`. Copy it to `/Applications` to install.

## Source layout

Core logic in `Sources/Louppe/`, one screen per file in `Sources/Louppe/Views/`:

- `LouppeApp.swift` — app entry point, menu commands
- `SessionStore.swift` — ratings, undo, navigation, session persistence
- `FolderScanner.swift` — recursive folder scan, RAW+JPEG pairing, sorting
- `ImagePipeline.swift` — image decoding (ImageIO), thumbnail caches, prefetching
- `MetadataExtractor.swift` — EXIF extraction (capture dates, info panel fields)
- `ExportManager.swift` — copying keepers, filename collision handling
- `Models.swift` — the photo item and session file formats
- `Views/` — welcome screen, session toolbar + hotkeys, culling view, filmstrip,
  light table, info panel, thumbnails, export dialog

See `CLAUDE.md` for a full architecture map, build/verify instructions, and
project invariants (useful for both humans and AI assistants).

Supported formats:

- **RAW** — Nikon `.NEF`/`.NRW`, Fujifilm `.RAF`, Adobe `.DNG`, Canon
  `.CR2`/`.CR3`/`.CRW`, Sony `.ARW`/`.SR2`/`.SRF`, Olympus `.ORF`, Panasonic
  `.RW2`/`.RAW`, Pentax `.PEF`, Samsung `.SRW`, Hasselblad `.3FR`/`.FFF`,
  Leica `.RWL`, Phase One `.IIQ`, Leaf `.MOS`, Kodak `.DCR`, Konica Minolta
  `.MRW`, Epson `.ERF`
- **Images** — `.JPG`/`.JPEG`, `.TIF`/`.TIFF`, `.PNG`, `.HEIC`/`.HEIF`/`.HIF`,
  `.WEBP`, `.AVIF`, `.JXL`, `.GIF`, `.BMP`, `.PSD`, `.TGA`, `.JP2`, `.ICO`

Other visual files (videos, a few rare RAW formats) still appear in the
session as a grey "file isn't supported" placeholder, so nothing on the card
is silently hidden — you can rate and export them like any other file.

## License

Louppe is free and open source under the [MIT License](LICENSE) — you're free
to use, modify, and redistribute it.

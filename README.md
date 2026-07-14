# Louppe: Photo Culling App

Fast, keyboard-driven open source macOS app for reviewing a folder of photos and marking
each one **Yes** (keep) or **No** (reject), then exporting the keepers to a new
folder. Originals are never modified or deleted — the only thing that can move
them is the explicit **Clean Up** command, which sends rejects to the macOS
Trash (recoverable, and undoable with ⌘Z).

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
| F | Mark Yes (all selected photos), jump to next undecided |
| D | Mark No (all selected photos), jump to next undecided |
| S | Toggle 100% zoom / fit |
| A | Toggle phone-sized preview / fit |
| Tab / G | Switch Main ↔ Light Table view |
| E | Export |
| Q | Show/hide the browser (thumbnail column) |
| W | Show/hide the info panel |
| R | Clear all ratings (one ⌘Z brings them all back) |
| ⌘R | Re-scan folder for new photos |
| ⌘+ / ⌘− | Bigger / smaller thumbnails in the Light Table |
| Z or ⌘Z | Undo last rating or clean-up |
| ⌘E | Export |
| ⌘O | Open a different folder |
| ⌘A | Select all photos (respects the filter) |
| ⌘⇧← / ⌘⇧→ | Select from the current photo to the first / last |
| Esc | Clear the selection |
| ⌘⌫ | Move selected photo(s) to the Trash — instant, no dialog (⌘Z restores) |

In the **Light Table** grid: single-click a photo to cycle its rating
(undecided → yes → no), double-click to open it big in the main view.

### Selecting several photos

- **⇧-click** a thumbnail (in the browser or the Light Table) to select the
  whole range between the current photo and the clicked one.
- **⌘-click** adds or removes a single photo.
- In the **Light Table**, click and **drag** — every photo touched by the
  selection rectangle gets selected.
- **⌘A** selects everything currently shown (filtered-out photos stay out).
- **⌘⇧← / ⌘⇧→** select everything from the current photo to the first / last.
- With several photos selected, **F** and **D** rate them all at once and jump
  to the next undecided photo — one ⌘Z undoes the whole batch. In the Light
  Table, clicking any photo inside the selection cycles the rating for all of
  them. The toolbar counter shows how many photos are selected.
- **Esc**, a plain click, or an arrow key drops the selection.

### Cleaning up the folder

The trash button in the toolbar (also **File → Clean Up**) tidies the photo
folder itself:

- **Move selected photo(s) to Trash** — exactly the photos you have selected
  (or just the current one) leave the folder. **⌘⌫** does the same instantly,
  without a confirmation — like in Finder — and ⌘Z brings them right back.
- **Move "No" photos to Trash** — rejects leave the folder; "Yes" and unrated
  photos stay.
- **Keep only "Yes" photos** — everything not marked "Yes" (including unrated
  photos) leaves the folder.

Both options ask for confirmation first and show exactly how many files will
move. Files go to the macOS Trash — never deleted permanently — and a
RAW+JPEG pair always moves together. Press **⌘Z** to put everything back in
place, or recover the files from the Trash later.

When a filter is active, a **Limit to Filtered Photos** switch appears in the
clean-up menu. Leave it on (the default) to clean only among the photos the
filter shows; switch it off to consider every photo in the folder, including
hidden ones. Either way, the confirmation message spells out exactly which
photos are affected before anything moves.

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

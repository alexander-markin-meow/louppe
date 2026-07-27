# Louppe: Photo and Video Culling App

Fast, keyboard-driven open source macOS app for reviewing a folder of photos and videos,
marking each one **Yes** (keep) or **No** (reject), then exporting any mix of ratings —
copied to a new folder, or moved there with the export dialog's opt-in
**Move to…** mode. Originals are never modified or deleted — the only things
that can move them are that explicit Move mode and the **Clean Up** command,
which sends rejects to the macOS Trash (recoverable, and undoable with ⌘Z).

## Download

Grab the latest build from **[Releases](https://github.com/alexander-markin-meow/louppe/releases/latest)** — download `Louppe.zip`, unzip, drag `Louppe.app` into Applications.

This app isn't notarized by Apple, so on first launch macOS will warn it can't verify the developer. Right-click the app → **Open** → **Open** again in the dialog. That's a one-time step; it opens normally after that.

After that first install, Louppe checks for signed updates once a day and
downloads them in the background. Updates install safely when Louppe quits.
Use **Louppe → Check for Updates…** at any time, or change automatic checking
and downloading under **Louppe → Settings…**.

## Using the app

Pick a folder (an SD card works), review, then press **⌘E** to copy — or
move — the photos you picked.

RAW+JPEG pairs keep one matching basename at the destination, including when
Louppe adds a collision suffix. If one member cannot be copied, the other is
rolled back so the destination does not retain half a pair. A long Copy can be
stopped safely from its progress view; completed photos remain copied. Louppe
refuses export destinations inside the folder being reviewed.

Copy, Move, Clean Up, and Clean Up undo keep a durable per-file safety record.
If Louppe, the Mac, or a drive stops unexpectedly between file steps, the next
launch verifies the exact files and returns them to a safe source state before
opening a folder. Louppe never overwrites a file during recovery; if a drive is
missing or a file no longer matches, it leaves everything untouched and offers
**Retry Recovery**.

### Keyboard shortcuts

| Key | Action |
|---|---|
| → | Next photo |
| ← | Previous photo |
| ↑ / ↓ | Previous / next photo in the Gallery view; previous / next row in the Grid view |
| Space | Play/pause the current video; on a photo, move to the next item without rating |
| F | Mark Yes (all selected photos), jump to next undecided |
| D | Mark No (all selected photos), jump to next undecided |
| S | Toggle 100% zoom / fit |
| A | Toggle phone-sized preview / fit |
| Tab / G | Switch Gallery ↔ Grid view |
| E or ⌘E | Export |
| Q | Show/hide the browser (thumbnail column; Gallery view only) |
| W | Show/hide the info panel |
| R | Clear all ratings (16+ ratings ask for confirmation; Enter confirms; ⌘Z restores) |
| ⌘R | Re-scan folder for new photos |
| ⌘+ / ⌘− | Bigger / smaller thumbnails in the Grid view |
| Z or ⌘Z | Undo last rating or clean-up |
| ⌘O | Open a different folder |
| ⌘A | Select all photos (respects the filter) |
| ⌘⇧← / ⌘⇧→ | Select from the current photo to the first / last |
| Esc | Cancel scanning, or clear the active photo selection |
| ⌘⌫ | Move selected photo(s) to the Trash — instant, no dialog (⌘Z restores) |

In the **Grid view**: single-click a photo to cycle its rating
(undecided → yes → no), double-click to open it big in the main view.

Videos use their first frame as the thumbnail and show their duration at all
times. Use the play/pause button to preview a video directly in the Grid, or
open it in Gallery for the full native macOS player with timeline, volume,
full-screen, and Picture in Picture controls. Only one video plays at a time.

While a folder is being scanned, Louppe shows its name, full path, and running
photo count. Use **Cancel Scan** in the toolbar or press **Esc** to stop the
scan and return to the start screen; partial scan results are discarded.

### Filtering and sorting

The toolbar filter opens with Date in Range mode and every date/exposure range
set to the folder's full minimum-to-maximum span. That neutral state shows all
photos, including files with missing metadata; narrowing a range activates it.
Date can instead select individual calendar days, with an explicit checkbox
for files whose date is unknown. Aperture, shutter speed, and ISO accept
inclusive typed ranges; shutter values can use photographer notation such as
`1/1000` or `2s`. Subfolder, file type, camera, and lens remain available as
checkbox lists; the subfolder list includes a **None** entry for files lying
directly in the source folder. The **Keep RAW + JPEG together** switch in the
File types section is enabled by default; turn it off when you want same-named
RAW and JPEG files to be reviewed, rated, filtered, exported, or cleaned up as
separate items. RAW+TIFF files are always separate. Different sections combine,
so a date, camera, and ISO range can all be active at once.

Mixed folders add a **Media** section for Photos/Videos and a **Video duration**
range accepting `m:ss` or `h:mm:ss`. Activating a duration range shows matching
videos only; leaving the full range untouched keeps every photo and video visible.

The adjacent sort menu orders visible media by date (the default), name,
subfolder, file type, media type, camera, lens, aperture, shutter speed, ISO,
or video duration. Items
missing the chosen metadata stay at the end in either direction.

### Selecting several photos

- **⇧-click** a thumbnail (in the Browser or Grid view) to select the
  whole range between the current photo and the clicked one.
- **⌘-click** adds or removes a single photo.
- In the **Grid view**, click and **drag** — every photo touched by the
  selection rectangle gets selected.
- **⌘A** selects everything currently shown (filtered-out photos stay out).
- **⌘⇧← / ⌘⇧→** select everything from the current photo to the first / last.
- With several photos selected, **F** and **D** rate them all at once and jump
  to the next undecided photo — one ⌘Z undoes the whole batch. In the Light
  Table, clicking any photo inside the selection cycles the rating for all of
  them. The toolbar counter shows how many items are selected. The Info panel
  switches to a selection summary with the selected item and underlying file
  counts, every camera, lens, capture-date span, combined size, and file type
  represented in the selection. RAW+JPEG details show both files' sizes and
  their total.
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
move. A progress overlay keeps the app responsive during large batches; folder
changes and rating edits are briefly disabled so undo remains exact. Files go
to the macOS Trash — never deleted permanently — and a
RAW+JPEG pair always moves together. Press **⌘Z** to put everything back in
place, or recover the files from the Trash later.

The clean-up menu has an inline **For “No” / “Yes” Actions** choice with live
counts for **All Photos**, **Filtered**, and **Selected**.
**Filtered** is the default; with no active filter it naturally contains
the whole folder. This choice affects only the two rating-based actions — the
top **Move Selected to Trash** command always moves the complete selection.
The confirmation message spells out exactly which photos are considered before
anything moves.

### Where things are stored

- Ratings: a hidden `.louppe_session.json` file inside the photo folder
  (or in `~/Library/Application Support/Louppe/Sessions/` if the folder is
  read-only, e.g. a locked SD card). The newest valid copy wins. Louppe shows
  **Retry Saving** if the folder copy is unavailable or neither location can
  save, and does not silently discard an unsafe session during folder
  switching, rescanning, Close Session, or Quit.
- Thumbnails cache: `~/Library/Caches/Louppe/` (safe to delete anytime).
- Interrupted-operation records:
  `~/Library/Application Support/Louppe/Operations/`. These small path/state
  records normally disappear as soon as an operation finishes; an unresolved
  record remains so recovery can be retried. They never contain photo data or
  credentials.

## Rebuilding from source

Requires Apple's Command Line Tools (already installed). From this folder:

```
./build_app.sh
```

Sparkle is downloaded from its public release using a pinned checksum. The
build script explicitly disables Swift Package Manager's optional Keychain
lookup, so no GitHub login or password is required.

Release versions come from [`VERSION`](VERSION), and the release build verifies
that [`CHANGELOG.md`](CHANGELOG.md) contains the same marketing version and
build number before packaging the app. Every shipped release or update must
have its own version/build pair and history entry; development changes remain
under the current unreleased version until that release actually ships.

The fresh app and its release archive appear at `dist/Louppe.app` and
`dist/Louppe.zip`. Copy the app to `/Applications` to install. Release owners
must also follow [`Docs/UPDATES.md`](Docs/UPDATES.md) to sign the exact archive
and regenerate `appcast.xml` before publishing a GitHub release.
`./Scripts/verify_release.sh` checks a local package without opening Keychain;
its `--publishing` mode performs the key-backed feed and archive verification
required before upload.

Run the focused logic checks with `./Tests/run_performance_checks.sh` and the
native movie checks with `./Tests/run_video_checks.sh`. They use
only Apple Command Line Tools and no external test framework. After any app change, also launch
the installed build with `-openFolder` as described in
[`AGENTS.md`](AGENTS.md); a compile-only check is not enough.

The repository's `Quality` GitHub Actions workflow repeats strict Swift 6,
XCTest, deterministic logic/recovery, scrollbar, video, and local release
package checks on macOS 26. It intentionally skips the two real Trash/restore
checks, which must still pass locally before installing or releasing a build.
The workflow has read-only repository access and never uses the private
Sparkle signing key.

## Source layout

Core logic in `Sources/Louppe/`, one screen per file in `Sources/Louppe/Views/`:

- `LouppeApp.swift` — app entry point, menu commands
- `UpdaterViews.swift` — automatic updater menu and Settings controls
- `SessionStore.swift` — ratings, undo, navigation, session persistence
- `PreparedSessionIndex.swift` — pure item-ID, sort, filter, stable-group, and navigation maps
- `SelectionState.swift` — pure stable-ID selection, range, toggle, filter, and rescan rules
- `SessionPersistence.swift` — typed background sidecar/backup saves, recovery, and schema validation
- `FileOperationJournal.swift` — durable per-file Copy/Move/Trash/undo recovery
- `CleanUpWorker.swift` — background Trash/restore operations and linear merge
- `FolderScanner.swift` — recursive folder scan, RAW+JPEG pairing, sorting
- `ImagePipeline.swift` — image decoding and video first frames, thumbnail caches, prefetching
- `VideoSupport.swift` — native video metadata and duration formatting
- `VideoPlaybackController.swift` — shared native player lifecycle
- `MetadataExtractor.swift` — EXIF extraction (dates, exposure settings, info panel fields)
- `ExportManager.swift` — export dialog orchestration (copy/move, destination prompt)
- `ExportWorker.swift` — background export copy/move loops, collision handling, pair rollback
- `ExportDestinationValidator.swift` — source-tree, permission, and free-space export preflight
- `Models.swift` — the photo item and session file formats
- `Views/` — welcome screen, session toolbar + hotkeys, Gallery view, Browser,
  Grid view, info panel, thumbnails, export dialog

See `AGENTS.md` for a full architecture map, build/verify instructions, and
project invariants (useful for both humans and AI assistants).
See [`Docs/PERFORMANCE.md`](Docs/PERFORMANCE.md) for cache budgets, concurrency
boundaries, derived-data rules, and performance regression checks.
See [`Docs/CODEBASE_AUDIT.md`](Docs/CODEBASE_AUDIT.md) for the prioritized
file-safety, reliability, architecture, performance, accessibility, and
release-quality improvement roadmap.

Supported formats:

- **RAW** — Nikon `.NEF`/`.NRW`, Fujifilm `.RAF`, Adobe `.DNG`, Canon
  `.CR2`/`.CR3`/`.CRW`, Sony `.ARW`/`.SR2`/`.SRF`, Olympus `.ORF`, Panasonic
  `.RW2`/`.RAW`, Pentax `.PEF`, Samsung `.SRW`, Hasselblad `.3FR`/`.FFF`,
  Leica `.RWL`, Phase One `.IIQ`, Leaf `.MOS`, Kodak `.DCR`, Konica Minolta
  `.MRW`, Epson `.ERF`
- **Images** — `.JPG`/`.JPEG`, `.TIF`/`.TIFF`, `.PNG`, `.HEIC`/`.HEIF`/`.HIF`,
  `.WEBP`, `.AVIF`, `.JXL`, `.GIF`, `.BMP`, `.PSD`, `.TGA`, `.JP2`, `.ICO`
- **Videos** — every local movie type and codec supported by macOS AVFoundation,
  normally including QuickTime/MPEG-4 camera and phone footage such as `.MOV`,
  `.MP4`, `.M4V`, `.3GP`, H.264, HEVC, and ProRes. Louppe also recognises
  common `.AVI`, `.MKV`, `.WEBM`, `.MTS`/`.M2TS`, `.MPG`/`.MPEG`, `.WMV`,
  `.FLV`, and `.INSV` files; playback depends on a native decoder being
  available on that Mac.

Other recognised visual files (including a few rare RAW formats and movies
whose codec macOS cannot decode) still appear in the
session as a grey "file isn't supported" placeholder, so nothing on the card
is silently hidden — you can rate and export them like any other file.

## License

Louppe is free and open source under the [MIT License](LICENSE) — you're free
to use, modify, and redistribute it.

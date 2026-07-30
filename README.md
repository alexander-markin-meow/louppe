# Louppe

(˶ᵔ ᵕ ᵔ˶)

**A fast, open-source photo and video culling app for Mac.**

Louppe helps review a folder or memory card, mark the shots you want to
keep, and export them.

Your photos stay in their original quality. Export copies them by default.
Louppe only moves originals when you deliberately choose **Move to…** or send
photos to the macOS Trash. It never permanently deletes a file.

macOS 14 or newer.

## Download

Download `Louppe.zip` from the
[latest release](https://github.com/alexander-markin-meow/louppe/releases/latest),
unzip it, and drag `Louppe.app` into Applications.

Louppe is not notarized by Apple. The first time you open it, macOS may say it
cannot verify the developer. Right-click Louppe, choose **Open**, then choose
**Open** again. You only need to do this once.

## Basics

1. Open a folder or memory card.
2. Press **F** for Yes or **D** for No as you review.
3. Filter, sort, or select several photos when needed.
4. Press **⌘E** to copy your chosen photos to another folder.

Most photo and video formats are supported; support for more file types is
planned. Filters and sorting cover ratings, dates, folders, file types, camera
details, media type, and video length.

Matching RAW+JPEG files are grouped by default; you can separate or regroup
them. RAW and JPEG each keep their own rating.

For close inspection, Gallery offers a fast Fit view, a phone-sized preview
(**A**), and true 100% zoom (**S**). The Info panel includes metadata, a
histogram, and clipping information. Press **X** to mark clipped areas.

## Keyboard shortcuts

### Review and navigation

| Key | What it does |
|---|---|
| **F** | Mark Yes and move to the next undecided item |
| **D** | Mark No and move to the next undecided item |
| **← / →** | Go to the previous / next item |
| **↑ / ↓** | Gallery: previous / next item. Grid: previous / next row |
| **Space** | Play or pause a video. On a photo, go to the next item |
| **S** | Gallery: switch between Fit and true 100% zoom |
| **A** | Gallery: switch between Fit and a phone-sized preview |
| **X** | Gallery: show or hide red clipping warnings on the photo |
| **Tab** or **G** | Switch between Gallery and Grid |
| **Q** | Show or hide the thumbnail browser in Gallery |
| **W** | Show or hide the info panel |
| **⌘+ / ⌘−** | Make Grid thumbnails bigger / smaller |

### Actions and selection

| Key | What it does |
|---|---|
| **E** or **⌘E** | Open Export |
| **R** | Clear all ratings. Large sets ask for confirmation; **Return** confirms |
| **Z** or **⌘Z** | Undo the last rating, rating reset, or Trash action |
| **⌘O** | Open a different folder |
| **⌘R** | Scan the current folder again |
| **⌘A** | Select every item currently shown by the filter |
| **⌘⇧← / ⌘⇧→** | Select from the current item to the first / last |
| **Esc** | Cancel a scan or clear the current selection |
| **⌘⌫** | Move the selection to the Trash immediately, without a dialog. **⌘Z** restores it |

## Mouse and trackpad

- In Grid, click a photo to select it. Click its status circle to change its
  rating. Double-click the photo to open it in Gallery. These actions keep the
  Grid at the same scroll position.
- **Shift-click** selects a range. **Command-click** adds or removes one item.
- Drag across Grid photos to select several of them.
- In Gallery, double-click a point on a photo to inspect that area at true
  100% size. Double-click again to return to Fit.

Louppe also supports VoiceOver. Ratings and controls do not rely on color
alone, so the main review workflow can be completed with the keyboard.

## Keeping your files safe

- Export works with any mix of Yes, No, and Undecided items. It uses
  **Copy to…** by default; **Move to…** is available.
- Export checks the destination before starting. A long copy can be stopped
  safely, and a RAW+JPEG pair never gets left half-copied.
- **Clean Up** sends files to the macOS Trash, never to permanent deletion.
  It asks for confirmation unless you use **⌘⌫**, and **⌘Z** can restore the
  whole batch.
- Matching RAW+JPEG files, if grouped, move or copy together.
- Louppe keeps a small safety record during file operations. If the app, Mac,
  or drive stops unexpectedly, Louppe checks the exact files before recovery
  and never overwrites an existing file.
- Ratings are saved automatically in `.louppe_session.json` inside the opened
  folder, with a local backup when that folder is read-only.

Louppe recognises common camera RAW files, JPEG, TIFF, PNG, HEIC, WebP, AVIF,
and the photo and video formats supported by macOS. An unsupported file still
appears in the review, so it can be rated and exported.

---

For architecture, safety rules, and contributor notes, see
[AGENTS.md](AGENTS.md). Performance details are in
[Docs/PERFORMANCE.md](Docs/PERFORMANCE.md), and release instructions are in
[Docs/UPDATES.md](Docs/UPDATES.md).

---

## License

Louppe is free and open source under the [MIT License](LICENSE).

Created by [Alex Markin](https://alex-markin.com); contact: a@alex-markin.com

# RAW+JPEG Review and XMP Interoperability — Executive Plan

## Implementation handoff for Louppe

| | |
|---|---|
| Status | Implemented and locally verified; real Capture One resolver acceptance remains pending |
| Audience | A coding agent continuing the existing XMP feature branch |
| Written | 2026-08-07 |
| Current branch | `codex/xmp-interoperability-foundation` |
| Baseline commit | `2a516e5` — Add safe XMP interoperability |
| Companion specification | `Docs/XMP_INTEROPERABILITY.md` |

Implementation completed on 2026-08-07. The implemented code now uses separate
RAW/JPEG photos by default, exposes the hidden grouping switch with the exact
approved wording, provides typed and stale-safe conflict resolution for an
unambiguous RAW+JPEG family, applies all chosen winners as one undoable session
mutation, and discards and fully rebuilds the old immutable publication or
Copy/Move preflight plan. The complete 267-test XCTest suite, 73 performance
checks, current-SDK debug build, release package and archive checks, installed
signature verification, and an installed `-openFolder` launch all pass. The
launch sidecar contained two physical entries for one same-stem CR3+JPEG pair,
confirming the packaged app's fresh-session default.

Capture One 16.8.4.13 is installed, but its new end-to-end resolver/reload row
requires visible manual interaction and remains pending. Lightroom Classic,
Bridge, and darktable are not installed and also remain explicitly pending.
No result is inferred from packet tests.

---

## 1. Executive decision

Louppe will change its RAW+JPEG model in two connected ways:

1. **Matching RAW and JPEG files are separate photos by default.**
2. **A same-stem XMP conflict can be resolved explicitly by making one file's
   Louppe metadata authoritative for both members.**

The existing grouping option remains available, but it is intentionally a
secondary setting inside the Filter popover's **File types** section. It is not
shown as a toolbar control, toolbar status pill, or permanent extra indicator.

The exact control label should be:

> **Treat matching RAW + JPEG as one photo**

When enabled, it means more than visual stacking: review actions, selection,
filtering, Copy, Move, and Clean Up operate on the pair as one `PhotoItem`.
That consequence must be explained in help/accessibility text.

The conflict resolver prevents the user from reaching an XMP dead end after
rating the RAW and JPEG differently. It offers an explicit, reversible choice:

- **Use RAW metadata for both**;
- **Use JPEG metadata for both**; or
- **Keep separate and skip this XMP**.

No choice is made silently. The safe initial choice is Skip.

---

## 2. Authority and relationship to the original XMP plan

`Docs/XMP_INTEROPERABILITY.md` remains authoritative for all completed XMP,
file-safety, journal, persistence, merge-ownership, profile-mapping, and
packaging requirements unless this document explicitly changes one.

This document supersedes the original plan only in these areas:

- the default `RawJPEGPairingMode` changes from `.together` to `.separate`;
- the grouping control's product wording and location are fixed here;
- separate RAW/JPEG review becomes the normal path rather than an exception;
- same-stem metadata conflicts gain an explicit resolution workflow;
- verification is extended for the new default, resolver, and Capture One
  handoff.

Do not rewrite, simplify, or bypass the already completed XMP safety core.
In particular, retain:

- exact raw filesystem paths;
- filesystem-aware same-stem resolution;
- immutable preflight plans;
- bounded off-main planning and publication;
- real XMPCore parsing and preservation of foreign metadata;
- raw-byte compare-and-swap before replacement;
- durable temporary write, flush, atomic rename, and directory sync;
- Copy/Move journal activation before the first filesystem change;
- recovery compatibility with old journal plans;
- the rule that original media is never modified;
- the rule that Louppe never edits Capture One `.cos`, Session, or Catalog
  data.

### Side note — why this is an amendment

Phases 1–7 of the original interoperability plan are implemented. Rebuilding
them under a new abstraction would add risk without improving the product.
The next agent should make narrow changes around projection defaults, conflict
data, session mutation, and Export presentation, then reuse the existing
planner/store/worker boundaries.

---

## 3. Current repository baseline

At the time this plan was written:

- the branch is `codex/xmp-interoperability-foundation`;
- the branch contains the committed XMP foundation through Copy/Move journal
  integration and initial Phase 8 verification;
- `main` and `origin/main` point to `6e2444d`;
- the feature branch points to `2a516e5`;
- the handoff commit includes the follow-up changes for Export's star/color
  multi-select menus together with this plan.

That follow-up touched:

- `CHANGELOG.md`;
- `Docs/XMP_INTEROPERABILITY.md`;
- `Sources/Louppe/Models.swift`;
- `Sources/Louppe/Views/ExportView.swift`;
- `Tests/LouppeTests/XMPFilterSortExportTests.swift`;
- `Tests/PerformanceChecks/main.swift`.

The code changes replace synthetic **Any rating/color** choices with true
multi-select menus in which Unrated/None, every concrete value, and Mixed are
all checked initially. They are part of the approved, verified baseline and
must be preserved while layering the RAW+JPEG changes on top.

Do not discard or regress them. Do not create another feature branch unless the
owner explicitly asks; continue the current branch.

---

## 4. What the original interoperability plan has completed

The following work is already implemented and should be treated as production
behavior, not as open design work:

### Native metadata

- independent Yes/No/Undecided decision, 0–5 stars, and five color labels;
- metadata stored per physical file;
- independent Mixed projection for paired items;
- schema-5 persistence with schema 1–4 migration;
- exact batch undo and incremental counts;
- Info-panel, Gallery, Browser, Grid, and VoiceOver presentation;
- 0–5 keyboard shortcuts through `SessionView.handleKey`.

### Filtering, sorting, and Export selection

- normal filter facets for decision, stars, and color;
- metadata sort keys and stable groups;
- prepared AND predicate for Export selection;
- exact item and physical-file counts;
- explicit Mixed handling;
- the approved star/color Export multi-select follow-up currently in the
  worktree.

### XMP core and profiles

- pinned Adobe XMPCore bridge and license packaging;
- Universal, Lightroom Classic, Bridge, Capture One, and darktable mappings;
- private lossless Louppe decision namespace;
- Capture One flat and hierarchical decision keywords;
- preservation of foreign namespaces, edit settings, and unrelated keywords;
- external-label ownership confirmation;
- canonical and extension-qualified sidecar recognition;
- case, Unicode, symlink, unsafe-type, malformed-packet, and external-edit
  defenses.

### Publication and file operations

- standalone **Metadata (XMP)** mode;
- immutable preflight, cancellation, progress, and detailed results;
- conditional **Include XMP sidecars** behavior in Copy/Move;
- merged destination packets without changing Copy sources;
- shared sidecar Copy/Move/retirement behavior;
- versioned journal plan and interruption recovery;
- `.acr` detection and exclusion reporting;
- complete local build, packaging, signature, launch, session, and synthetic
  packet verification recorded in the original plan.

---

## 5. Work still open from the original interoperability plan

The new implementation must carry these unfinished items forward:

1. **Preserve the verified Export multi-select change.**
   Its focused tests, performance checks, full XCTest, debug build, release
   package, and launch verification passed before this handoff was committed.
2. **Real Adobe Bridge acceptance remains pending.**
   Verify stars, five colors, decision keywords, and preservation of Camera Raw
   settings when Bridge is available.
3. **Real Lightroom Classic acceptance remains pending.**
   Verify stars, colors, Pick/Reject/Unflagged behavior, manual metadata reload,
   and custom label-set behavior when Lightroom is available.
4. **Real darktable acceptance remains pending.**
   Verify first-import stem metadata and byte preservation of native
   extension-qualified history sidecars when darktable is available.
5. **Capture One must be rerun for the new conflict workflow.**
   The existing Capture One 16.8.4.13 row passed, but it did not cover default
   separate review followed by explicit RAW/JPEG unification.
6. **The original non-RAW warning remains required.**
   Adobe commonly embeds JPEG/TIFF/DNG metadata; Louppe remains sidecar-only,
   so those formats are best effort and originals remain immutable.

Unavailable third-party applications are not a reason to claim success or
block all locally verifiable work. Leave unavailable matrix rows visibly
pending and record exact versions/settings for every real test that is run.

---

## 6. Product research and the model Louppe is adopting

### 6.1 Adobe Bridge

Bridge treats physical files independently by default. Stacks are optional
presentation/selection groups. A command on a collapsed stack can affect only
the top file or all files depending on selection.

Adobe's normal metadata storage model is:

```text
IMG_0001.NEF  -> IMG_0001.xmp
IMG_0001.JPG  -> metadata embedded in IMG_0001.JPG
```

This avoids a same-stem collision because the RAW and JPEG have separate
metadata stores. Louppe cannot copy that model completely because it must not
modify the JPEG original.

### 6.2 Lightroom Classic

Lightroom exposes a preference that either imports the JPEG as a standalone
photo or treats it as a companion of the RAW. This validates separate-by-
default review as a familiar photographic workflow, while still leaving a
grouped option for photographers who want it.

### 6.3 Capture One

Capture One's **Pair RAWs and JPGs** option mainly coordinates filenames. It
does not itself synchronize ratings, color tags, or keywords. Capture One can
use one same-basename XMP packet as a deliberate synchronization channel for
both files.

This separation of concerns is the most useful model for Louppe:

- pairing controls review/operation behavior;
- metadata synchronization is a separate explicit action;
- a shared XMP is valid only after the user chooses shared values.

### 6.4 Photo Mechanic

Photo Mechanic also makes RAW+JPEG combination an explicit view mode and lets
the photographer choose which member supplies metadata. Its normal storage
preference is a RAW sidecar plus embedded JPEG metadata. This reinforces the
need to expose the winner when a single shared representation is required.

### Side note — what Louppe deliberately does differently

Louppe is more conservative than these products: it never embeds metadata into
the original JPEG, TIFF, DNG, HEIC, PNG, or RAW. That safety promise means
perfect interoperability is impossible for every non-RAW format. The UI must
describe the limitation honestly instead of disguising it with an
extension-qualified filename that Bridge may ignore.

---

## 7. Final RAW+JPEG behavior

### 7.1 Default and lifetime

- Change `SessionStore.rawJPEGPairingMode`'s initial value to `.separate`.
- Change `FolderScanner.scan`'s default argument to `.separate` where a default
  is appropriate; production callers should still pass the mode explicitly.
- A fresh app/session-store instance starts separate.
- Preserve the user's choice while that `SessionStore` remains alive, including
  folder changes, matching current behavior.
- Do not add `UserDefaults`, `@AppStorage`, or a session-schema field in this
  phase. A hidden behavior switch should not unexpectedly survive relaunch.
- Do not bump the session schema for this preference.

### Side note — persistence tradeoff

Capture One remembers its import preference, but Louppe's switch changes far
more than import naming: it changes rating, selection, export, Move, Trash, and
Clean Up scope. Resetting to the safer separate default on relaunch avoids a
rare, deeply located option silently affecting a future job. Persistence can
be reconsidered after observing real use.

### 7.2 Control placement and wording

Keep the toggle only inside:

```text
Filter popover
  File types
    Treat matching RAW + JPEG as one photo
```

Requirements:

- no dedicated toolbar icon;
- no toolbar status capsule;
- no redundant always-visible state indicator;
- keep the existing progress spinner while the projection changes;
- add help/accessibility text:
  “When enabled, ratings, selection, Export, Move, and Clean Up apply to both
  files.”
- keep the control distinct from actual file-type inclusion checkboxes;
- retain the divider between the behavior toggle and file-type values;
- disable it during its current transition and during unsafe file operations.

### 7.3 Projection behavior

When separate:

- RAW and JPEG are individual `PhotoItem` values;
- each has its own decision, stars, color, selection, filter result, and export
  eligibility;
- file-type filtering exposes RAW and JPEG independently;
- Copy/Move/Clean Up may operate on one without the other when explicitly
  selected by the photographer;
- XMP planning still examines the complete same-stem family, including a
  sibling excluded from the Export predicate.

When together:

- the current paired projection remains;
- rating one dimension writes that dimension to both physical files;
- Copy/Move/Trash/Clean Up preserve pair-wide rollback guarantees;
- divergent existing values display Mixed independently per dimension;
- merely enabling grouping must never discard or synchronize metadata.

Disabling grouping must recover the two original per-file metadata snapshots
without rescanning or losing the lazily enriched JPEG metadata.

### 7.4 Mixed remains meaningful

Mixed is retained even though separate becomes the default. It is needed when:

- a previously separate pair is grouped after receiving different values;
- an old schema/session already contains divergent per-file values;
- an external migration creates divergent values before projection;
- Export is opened while grouped.

The approved Export multi-select therefore keeps explicit Mixed choices.

---

## 8. XMP association rules after the default changes

The canonical sidecar rule remains:

```text
IMG_0001.NEF
IMG_0001.JPG
IMG_0001.xmp
```

One canonical stem sidecar can carry only one Louppe decision, one star value,
and one color value. Separate review does not create a second standards-based
namespace for the JPEG.

Rules:

1. Identical per-file published metadata produces one valid shared packet.
2. Divergent metadata produces `sameStemMetadataConflict`.
3. The planner never chooses RAW or JPEG silently.
4. `IMG_0001.JPG.xmp` is not generated as a supposed Bridge solution.
5. Existing extension-qualified application packets remain preserved/copied
   under the original rules and are never used to evade a canonical conflict.
6. A conflict in the canonical packet does not block Copy/Move of media or a
   separately safe application-private packet.
7. Conflict resolution happens before a new immutable publication/export plan
   is confirmed.

### Profile context

- **Capture One:** a shared stem XMP is a useful, documented synchronization
  channel. Explicit unification is the intended resolution.
- **Universal/darktable:** retain the conservative shared-stem rule because a
  consumer may associate the packet with more than one same-name file.
- **Bridge/Lightroom:** proprietary RAW interoperability is strong, but JPEG,
  TIFF, DNG, HEIC, and PNG sidecars remain best effort because Adobe normally
  embeds their metadata. Unifying Louppe values resolves the sidecar conflict;
  it does not promise that Adobe will read a JPEG sidecar.

Do not make the filesystem resolver profile-dependent in this phase. The
current conservative family rule is easier to explain and avoids a JPEG stem
sidecar accidentally changing the same-name RAW in another application.

---

## 9. Explicit same-stem conflict resolution

### 9.1 Entry point

When an XMP preflight contains one or more resolvable
`sameStemMetadataConflict` entries, show an additional secondary action:

> **Resolve RAW + JPEG Conflicts…**

Show it in both places where the immutable XMP plan is confirmed:

- standalone **Metadata (XMP)**;
- Copy or Move when **Include XMP sidecars** is enabled.

The user may always continue without resolving. Conflicted canonical packets
remain skipped and are reported. The feature prevents a dead end; it does not
turn conflict resolution into a mandatory destructive prompt.

### 9.2 Resolver sheet

Suggested structure:

```text
Resolve RAW + JPEG Metadata

These same-name files have different Louppe metadata. Capture One and
other sidecar workflows can store only one set in their shared XMP.

IMG_0001
RAW   IMG_0001.NEF   Yes   5 stars   Green
JPEG  IMG_0001.JPG   Yes   2 stars   Red

( ) Keep separate and skip this XMP
( ) Use RAW metadata for both
( ) Use JPEG metadata for both

[Apply the same choice to all conflicts…]

                         [Cancel] [Apply Resolutions]
```

Requirements:

- list exact filenames and extensions;
- show only dimensions that differ prominently, while allowing all values to
  be inspected;
- use existing decision/star/color visual language;
- default each row to **Keep separate and skip this XMP**;
- provide accessible labels that state source and destination explicitly;
- support multiple conflicts without forcing one global winner;
- optionally provide an “apply to all” convenience, but never default it;
- explain that choosing RAW/JPEG changes Louppe metadata for the other file;
- explain that the action is undoable in Louppe;
- avoid programmer terms such as “stem family” in user-facing copy.

### 9.3 Eligible and ineligible conflicts

The first resolver supports only an unambiguous family containing exactly:

- one recognized RAW photo; and
- one recognized JPEG photo.

Do not offer a winner for:

- two RAW formats with the same basename;
- multiple JPEG siblings;
- case-only or Unicode-normalization filename collisions;
- ambiguous pairing groups;
- videos;
- unsafe paths, symlinks, permissions failures, malformed XMP, external label
  ownership conflicts, destination collisions, or CAS failures.

Those remain ordinary skipped/error categories with their existing details.

### 9.4 Resolution semantics

**Use RAW metadata for both** copies the RAW's current Louppe values to the
JPEG for all three owned dimensions:

- decision;
- stars;
- color.

**Use JPEG metadata for both** performs the inverse.

Because already-equal dimensions remain equal, this is equivalent to changing
only the differing dimensions. For changed destination fields:

- use the normal SessionStore mutation path;
- assign a new change timestamp using the same rules as a direct user edit;
- update counts and prepared projections correctly;
- trigger ordinary safe session persistence;
- never write XMP from the mutation itself.

Do not copy the source file's historical `changedAt` timestamp onto the other
file. The synchronization is a new user action.

### 9.5 One undo step

Applying any number of choices from one resolver sheet is one undoable Louppe
action. The undo payload records the complete prior metadata snapshot of every
changed physical file.

Undo restores Louppe metadata only. If the user has already published XMP,
undo does not rewrite the sidecar automatically; XMP remains an explicit
one-way publication snapshot, consistent with the original design.

### 9.6 Stale-state protection

The resolver must be generation-bound and snapshot-bound.

For every row capture:

- open-session/folder generation;
- stable physical file IDs;
- scan-time file identities already held by the model;
- the exact metadata snapshots shown to the user;
- the conflict/family identifier from preflight.

Before applying:

1. verify that the same session/folder generation is still active;
2. find both physical files by stable ID, not array index;
3. verify their current metadata still equals the displayed snapshots;
4. reject/reload a row that changed while the resolver was open;
5. apply all still-valid chosen rows as one main-actor transaction.

Never overwrite a rating that changed after the sheet opened.

### 9.7 Mandatory replanning

After applying resolutions:

1. discard the old immutable XMP preflight plan;
2. recompute the Export selection snapshot, because copied metadata may change
   which files match the selected decision/star/color filters;
3. rerun exact sidecar resolution and destination collision planning;
4. show the new counts and warnings;
5. require confirmation of the new plan before any filesystem mutation.

For Copy/Move, retain the chosen destination only if it remains valid, but
rerun the complete media/XMP collision plan. Never patch the old journal plan
in place.

### Side note — why resolution updates the session

An export-only “RAW wins this time” policy would leave the authoritative
Louppe session divergent, recreate the conflict on the next export, and make
the published packet disagree with the UI. Updating the session makes the
choice durable, visible, and undoable.

---

## 10. Structured conflict data

The current planner exposes conflict filenames and a display message. The new
UI must not parse those strings. Add a typed descriptor, conceptually:

```swift
struct XMPSameStemConflictDescriptor: Equatable, Sendable, Identifiable {
    let id: String
    let sessionGeneration: UInt64
    let members: [Member]
    let differingDimensions: Set<MetadataDimension>
    let resolutionEligibility: ResolutionEligibility

    struct Member: Equatable, Sendable, Identifiable {
        let id: String              // stable PhotoFile ID
        let exactPath: XMPExactFileSystemPath
        let role: Role              // raw or jpeg
        let metadata: PhotoFileMetadataSnapshot
        let wasSelectedForExport: Bool
    }
}
```

Exact names may differ, but the ownership boundary is required:

- XMP planner identifies the filesystem family and conflict;
- the descriptor carries stable file identity and typed metadata;
- SessionStore owns applying metadata changes and undo;
- ExportView owns draft choices and presentation;
- the old plan is discarded after any applied resolution.

Do not place mutation closures, SwiftUI bindings, or main-actor objects inside
the immutable worker plan.

Use the existing RAW/JPEG classification logic. Do not create a second list of
file extensions in the Export UI.

---

## 11. Behavior matrix

| Area | Separate default | Grouped option |
|---|---|---|
| Browser/Grid | Two photos | One projected item |
| Decision/stars/color | Per physical file | Action writes selected dimension to both |
| Existing divergence | Two ordinary values | Mixed for that dimension |
| File-type filter | RAW and JPEG independently | RAW + JPEG combined type |
| Selection | Either file independently | Pair selected as one item |
| Export predicate | Each file can match independently | Projected pair state, including Mixed |
| Copy/Move | Selected file only | Pair-wide with existing rollback guarantees |
| Clean Up/Trash | Selected physical item only | Pair-wide with existing rollback guarantees |
| XMP family planning | Full same-stem context | Same full same-stem context |
| Divergent XMP | Conflict; resolve or skip | Mixed conflict; resolve, edit pair, or skip |
| Enabling grouping | N/A | Never auto-synchronizes existing metadata |
| Disabling grouping | Values preserved | Returns original per-file values |

### Important selection consequence

Suppose Export currently selects only 5-star files. RAW is 5 stars and JPEG is
2 stars. If the user resolves with **Use JPEG metadata for both**, the RAW
becomes 2 stars and may leave the Export scope. This is why resolution must
recompute selection and require a fresh confirmation.

---

## 12. Detailed implementation phases

### Phase A — stabilize the current worktree

1. Inspect the worktree and preserve any newer user changes.
2. Review the Export star/color multi-select implementation for:
   - all values checked initially;
   - no synthetic Any row;
   - explicit Mixed matching;
   - empty-selection validation;
   - exact AND counts;
   - VoiceOver labels/values;
   - no repeated whole-session scans in SwiftUI rendering.
3. Run `git diff --check`.
4. Run focused `XMPFilterSortExportTests`.
5. Run `Tests/run_performance_checks.sh`.
6. Do not commit the baseline separately unless that separation is useful for
   review; the owner has authorized the completed implementation to be
   committed and pushed after all phases pass verification.

Exit criterion: the existing worktree is a known-good base and no user edits
were lost.

### Phase B — change the default and clarify the hidden setting

1. Change production defaults from `.together` to `.separate`.
2. Rename the Filter toggle to the exact approved wording.
3. Add help and accessibility consequences.
4. Confirm no pairing icon/status element exists in the toolbar.
5. Update README and changelog wording.
6. Update tests that currently assert grouped is the default; retain explicit
   `.together` tests for grouped behavior.
7. Benchmark initial scans because separate mode may extract metadata for both
   files instead of keeping the JPEG lightweight.

Exit criterion: a fresh launch shows RAW and JPEG separately, and enabling the
deep setting reconstructs the previous safe grouped behavior without data
loss.

### Phase C — add typed resolution descriptors

1. Extend metadata-conflict preflight entries with structured member data.
2. Identify unambiguous one-RAW/one-JPEG eligibility using existing scanner
   classification.
3. Preserve current category/count/message behavior for existing callers.
4. Add pure tests for eligible and ineligible families.
5. Keep exact filesystem paths and stable IDs distinct: paths identify the XMP
   family; stable IDs identify SessionStore records.

Exit criterion: the UI can render every choice without parsing filenames or
messages, and ambiguous collisions cannot be offered a destructive winner.

### Phase D — implement the SessionStore resolution transaction

1. Add a typed batch resolution request.
2. Validate session generation, stable IDs, and displayed metadata snapshots.
3. Copy the chosen source values to the destination physical file.
4. Apply every chosen row as one undo step.
5. Reuse incremental count, filtering, selection, and save-generation logic.
6. Leave skipped rows unchanged.
7. Return typed applied/stale/ineligible outcomes.

Exit criterion: resolving several pairs is atomic at the in-memory user-action
level, undo restores every prior value, and a concurrent rating change is
never overwritten.

### Phase E — build the resolver UI and state transition

1. Add **Resolve RAW + JPEG Conflicts…** when eligible conflicts exist.
2. Implement the resolver sheet with per-family choices and safe Skip defaults.
3. Add optional apply-to-all convenience without preselecting it.
4. Present exact values and filenames accessibly.
5. Apply through SessionStore.
6. Dismiss the old confirmation, recompute Export selection, and rerun
   preflight.
7. Surface stale rows and let the user review refreshed values.

Exit criterion: the user can reach a conflict-free plan without leaving
Export, while retaining an obvious path to skip and continue.

### Phase F — preserve Copy/Move/recovery guarantees

1. Confirm no filesystem work occurs during resolution itself.
2. Confirm no journal is created until the replacement preflight is confirmed.
3. Rerun destination collision planning after resolution.
4. Verify media can still Copy/Move when a conflict is skipped.
5. Verify application-private packets still transfer independently.
6. Run interruption tests for the resulting generated/updated canonical packet
   through every existing plan-v4 checkpoint.
7. Do not add a journal version unless the actual on-disk plan changes.

Exit criterion: the new workflow feeds an ordinary valid immutable plan into
the existing worker; recovery semantics are unchanged.

### Phase G — application acceptance

For Capture One, test at least:

1. Fresh Louppe launch shows a RAW/JPEG capture separately.
2. Give the two files different stars/colors/decision.
3. Capture One preflight reports one same-stem conflict.
4. Choose **Use RAW metadata for both**.
5. Verify the Louppe UI now shows identical values and Undo is available.
6. Publish the Capture One profile.
7. Reload metadata in Capture One.
8. Verify stars, color, flat decision keyword, and hierarchical decision
   keyword on both variants.
9. Repeat with **Use JPEG metadata for both**.
10. Repeat with Skip and verify no canonical XMP is changed.
11. Verify unrelated Capture One metadata and `.cos` files remain untouched.

Carry forward the pending Bridge, Lightroom, and darktable rows from section 5
when those applications are available.

Exit criterion: the Capture One workflow used by the owner is proven end to
end, and unavailable applications remain honestly marked pending.

### Phase H — complete repository and app verification

Run in order:

```sh
./Tests/run_performance_checks.sh
swift build --disable-keychain
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --disable-keychain
./build_app.sh
```

Then install a test build using the name requested for that implementation
task, clear copied extended attributes, verify its signature, and launch with:

```sh
open "/Applications/<test name>.app" --args -openFolder /path/to/photos
```

Never pass a bare folder path. Confirm the app visibly launches and inspect
the disposable folder's `.louppe_session.json` plus generated XMP.

Before changing `VERSION` or opening another changelog section, check the
latest GitHub release. Follow the one-version-bump-per-release-cycle rule.

---

## 13. Required tests

### Default and projection

- fresh `SessionStore` defaults to `.separate`;
- default scan exposes RAW and JPEG as two items;
- explicit `.together` scan produces one pair;
- toggle together -> separate -> together preserves physical metadata;
- current item and multi-selection remap by stable file IDs;
- filter file-type exclusions reset safely during reprojection;
- rapid toggles cannot apply an obsolete projection;
- folder change during reprojection cannot apply stale results;
- transition remains blocked during active file operations;
- separate-mode initial scan remains within performance expectations.

### Grouped semantics retained

- editing one dimension writes only that dimension to both files;
- enabling grouping on divergent files produces independent Mixed states;
- grouped Copy/Move/Clean Up retains pair rollback behavior;
- disabling grouping restores both values exactly;
- Mixed remains selectable in normal Filter and Export multi-selects.

### Conflict descriptor

- exact one RAW + one JPEG is eligible;
- selected RAW plus excluded JPEG still describes both members;
- selected JPEG plus excluded RAW still describes both members;
- more than two members is ineligible;
- two RAW files are ineligible;
- case/Unicode filename collision is ineligible;
- missing/stale stable ID is rejected;
- no user-facing code parses `message` or filename strings.

### Resolution mutation

- RAW winner copies decision, stars, and color to JPEG;
- JPEG winner copies all three to RAW;
- equal dimensions retain their values/timestamps;
- changed dimensions receive a new change timestamp;
- Skip changes nothing;
- several resolutions form one undo step;
- Undo restores exact per-file snapshots;
- counts, visible filter results, current item, and selection remain valid;
- schema-5 persistence saves and restores the unified result;
- stale session generation is rejected;
- changed metadata snapshot is rejected instead of overwritten.

### Replanning

- old preflight ID cannot execute after resolution;
- selection predicate is reapplied after values change;
- a resolved family becomes Create/Update/Already current as appropriate;
- unresolved families remain conflicts;
- destination collisions are recomputed;
- Copy/Move journal activation contains only the replacement plan;
- no media or XMP path is touched before reconfirmation.

### XMP and Capture One

- identical separate files share one canonical packet;
- divergent files conflict before resolution;
- RAW-winner packet contains RAW values and C1 decision keywords;
- JPEG-winner packet contains JPEG values and C1 decision keywords;
- unrelated flat/hierarchical keywords survive;
- external custom labels retain their existing ownership confirmation;
- extension-qualified application packets remain byte-identical;
- Skip leaves an existing canonical packet byte-identical;
- real Capture One reload observes the resolved values on both files.

### Accessibility and copy

- toggle describes its operational scope;
- resolver announces filenames, roles, and differing values;
- radio choices say which file will change;
- Apply is disabled when nothing actionable is selected, unless closing with
  Skip is the intended action;
- stale/ineligible outcomes are explained without technical path language;
- partial Export results still distinguish conflicts, skips, and failures.

---

## 14. Performance and concurrency notes

Changing the default to separate may make the initial scan more expensive:
the current grouped path keeps the JPEG as a lightweight hidden `PhotoFile`
and enriches missing JPEG metadata only on the first split. Measure rather than
guess.

Do not solve a regression by:

- moving metadata extraction to the main actor;
- de-lazifying Grid or Browser;
- storing stale item indices across projection changes;
- duplicating full image/cache entries unnecessarily;
- adding one task per file;
- weakening content-revision identity.

Prefer extending the existing bounded scanner/enrichment path so separate
items can appear promptly and fill nonessential metadata safely. Update
`Docs/PERFORMANCE.md` if ownership, concurrency, or cache behavior changes.

The conflict resolver itself is a small main-actor metadata transaction.
Filesystem preflight and packet parsing remain in existing bounded workers.

---

## 15. Safety invariants

The next implementation must preserve all repository invariants, especially:

- originals are never modified or hard-deleted;
- only the existing sanctioned Clean Up/Trash and explicit Export Move paths
  move originals;
- `activeFileOperation` remains the sole Copy/Move/Trash authority;
- standalone metadata publication keeps its existing separate lifecycle state;
- `visibleIndices` is rebuilt/reset in the same turn as `items` changes;
- `SelectionState.itemIDs` remains the stable selection authority;
- Browser rows continue to observe SessionStore directly;
- rating shortcuts remain solely in `SessionView.handleKey`;
- one `Color.appBackground` and one `Color.louppeAccent` remain;
- existing sidecars are merged, never replaced wholesale;
- foreign metadata is preserved;
- unresolved evidence remains recoverable;
- no filesystem action is inferred from filename alone;
- a stale conflict choice never overwrites newer session metadata.

---

## 16. Explicitly out of scope

Do not expand this work to include:

- automatic XMP import into Louppe;
- continuous/two-way synchronization;
- writing XMP after every rating keystroke;
- embedding metadata into original JPEG/TIFF/DNG/HEIC/PNG files;
- generating `IMG.JPG.xmp` as a promised Adobe-compatible solution;
- editing Capture One `.cos`, Session, or Catalog databases;
- driving Capture One with AppleScript;
- automatically resolving conflicts merely because grouping is enabled;
- silently preferring RAW or JPEG;
- per-dimension winner mixing in the first resolver UI;
- automatic Clean Up of XMP;
- changing private application edit/history data;
- persisting the grouping toggle across app relaunches;
- adding a toolbar pairing button or redundant status element.

### Possible later enhancement

An explicitly named **Embed metadata in exported JPEG copies** option could
produce more Adobe-compatible destination copies while leaving originals
untouched. It would change the copied file's bytes and complicate verification,
so it requires a separate product and safety design.

---

## 17. Acceptance checklist

### Product behavior

- [x] Fresh launch treats RAW and JPEG separately.
- [x] Grouping control exists only under Filter -> File types.
- [x] Exact wording is “Treat matching RAW + JPEG as one photo.”
- [x] No pairing toolbar icon/status element is added.
- [x] Grouping consequences are explained accessibly.
- [x] Enabling grouping never silently synchronizes metadata.
- [x] Separate rating/filter/export/cleanup behavior is correct.
- [x] Grouped pair-wide safety behavior is unchanged.

### Conflict resolution

- [x] Eligible conflicts expose Resolve RAW + JPEG Conflicts.
- [x] Skip is the safe default and publication can continue partially.
- [x] RAW and JPEG winner choices are explicit.
- [x] Applying resolutions changes the Louppe session, not only the packet.
- [x] One resolver apply creates one undo step.
- [x] Stale snapshots/generations are rejected.
- [x] Old immutable plans are discarded.
- [x] Selection and complete preflight are recomputed.
- [x] Ambiguous families never offer a winner.

### Existing XMP work retained

- [x] Export star/color multi-select follow-up is reviewed and passing.
- [x] Existing XMPCore merge and safety tests remain passing.
- [x] Existing profile mappings and keyword ownership remain unchanged.
- [x] Copy/Move journal and recovery tests remain passing.
- [x] Source media and Copy-source XMP bytes remain unchanged.
- [x] Non-RAW best-effort warnings remain visible.

### Verification

- [x] Focused model/filter/export/resolver tests pass.
- [x] Performance checks pass, including separate-mode scan coverage.
- [x] Full XCTest passes with full Xcode.
- [x] Debug build passes with the current SDK.
- [x] Release package and archive verification pass.
- [x] Installed app signature verifies.
- [x] App launches with `-openFolder` and creates/updates its session safely.
- [ ] Capture One end-to-end resolution/reload matrix passes.
- [x] Bridge/Lightroom/darktable rows are completed or explicitly pending.
- [x] README, performance notes if needed, original XMP plan, and changelog
      accurately describe the final behavior.
- [x] `VERSION` is bumped only if the GitHub release state requires it.

---

## 18. Handoff instructions for the next coding agent

1. Read `AGENTS.md`, this document, and `Docs/XMP_INTEROPERABILITY.md` fully.
2. Inspect the worktree before editing; the committed multi-select work is part
   of the baseline, and any newer uncommitted changes belong to the owner.
3. Continue `codex/xmp-interoperability-foundation`; do not silently switch to
   `main` or create another branch.
4. Start with Phase A and establish a passing baseline.
5. Implement phases in order. Do not build the resolver UI on untyped display
   strings.
6. Treat the session mutation and subsequent full replan as the center of the
   feature.
7. Keep all filesystem work behind the existing planner/store/journal
   boundaries.
8. Verify the real app launches after changes, as required by repository
   guidance.
9. After implementation and verification are complete, commit the finished
   work and push **the same `codex/xmp-interoperability-foundation` branch**.
   Do not move the work to `main`, create a replacement branch, or leave the
   final verified changes only in the local worktree.
10. Report unavailable third-party acceptance rows honestly instead of
    inferring them from packet tests.

---

## 19. Primary research references

- [Adobe Camera Raw settings and storage](https://helpx.adobe.com/camera-raw/desktop/get-started/overview-and-setup/camera-raw-settings.html)
- [Adobe Bridge stacks](https://helpx.adobe.com/bridge/desktop/organize-and-find-files/organize-files-and-folders/stack-files.html)
- [Adobe Bridge labels and ratings](https://helpx.adobe.com/bridge/desktop/organize-and-find-files/tag-and-find-files/label-and-rate-files.html)
- [Lightroom Classic RAW+JPEG import preference](https://helpx.adobe.com/lightroom-classic/desktop/import-photos/file-import-formats-settings.html)
- [Capture One RAW/JPEG pairing](https://support.captureone.com/hc/en-us/articles/30110560619165-Pairing-RAW-and-JPG-files-in-Capture-One)
- [Capture One metadata in XMP sidecars](https://support.captureone.com/hc/en-us/articles/360002544898-Metadata-in-XMP-sidecar-files)
- [Photo Mechanic IPTC/XMP preferences](https://docs.camerabits.com/support/solutions/articles/48001146198-iptc-xmp-preferences)

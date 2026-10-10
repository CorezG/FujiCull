# FujiCull — Technical Design (v1)

_Status: **Reviewed**, 2026-10-09. Design questions answered, and ADR-001 to ADR-006 accepted.
Implements [REQUIREMENTS.md](REQUIREMENTS.md). Decisions with lasting consequences are
recorded as ADRs in [decisions/](decisions/). Still open: sample files (Q4) and the SSD format (Q6)._

---

## 1. Summary

FujiCull is a native macOS app made of three Swift Package targets:

- **`FujiCullCore`** is pure Foundation plus CryptoKit. It owns everything that has to be correct: scanning and pairing the card, the cull session and its undo stack, session persistence, and the Apply planner and executor.
- **`FujiCullImaging`** uses ImageIO and CoreGraphics. It handles the card read queue, the three preview tiers and EXIF.
- **`FujiCullApp`** is a SwiftUI shell around AppKit views for the viewer, filmstrip and grid.

Three ideas shape the design:

1. **Read as little of the card as possible.** Thumbnails and EXIF come from the first 64 KB of each JPG. A full JPG is read only when it is about to be shown. Caches live in memory only, so nothing goes to the Mac's nearly full disk. See [ADR-002](decisions/ADR-002-jpeg-first-preview-pipeline.md).
2. **Make Apply boring and provable.** A pure planner produces a list of operations. A journaled executor copies each file, then verifies it by reading it back from disk, then renames it into place without ever overwriting. Deletion is a separate step: it comes after the copies are verified and needs explicit confirmation. See [ADR-003](decisions/ADR-003-journaled-copy-verify-delete.md).
3. **Keep the logic testable without a GUI.** Every rule from the requirements (pairing, decisions, Apply safety) lives in `FujiCullCore` and is tested against temporary directories and injected faults. The app layer handles presentation and input only.

## 2. Constraints that drive the design

| Constraint | Number | Consequence |
|---|---|---|
| Card read speed (measured) | 93–94 MB/s in your chosen reader (66–92 in the first one) | A JPG (11–13 MB at size M, which you shoot today; ~25 MB at size L) takes 130–200 ms just to read, so prefetching is mandatory. Reading the card is the bottleneck, not decoding. See [hardware probe](spikes/2026-10-09-hardware-probe.md). |
| Shoot size | 1,500–2,000 frames, ~150–200 GB | Never import the card; work on it in place. Read files sequentially and keep one card reader. |
| Mac free disk | ≤ 10 GB | No disk preview cache (memory only). Session files only, a few hundred KB at most. |
| Mac memory | 16 GB here; target "comfortable on 8 GB" | A memory budget of ~400 MB peak (§5.4). |
| Toolchain on this Mac | Swift 6.3, **Command Line Tools only (no Xcode)** | SwiftPM plus a Makefile, no `.xcodeproj`. Tests use Swift Testing with explicit framework paths. No XCUITest and no Instruments. See [ADR-001](decisions/ADR-001-native-swift-spm-no-xcodeproj.md). |
| Safety | No deletion before a verified copy | A journaled, resumable Apply. Deletion is gated on verification of every keeper. |

## 3. Design decisions agreed in review

Assumptions A1–A4 in REQUIREMENTS.md are confirmed. These came up during design and were confirmed on 2026-10-09:

- **D1. Frame order is DCIM folder, then filename, not EXIF time.** This amends R3. See [ADR-004](decisions/ADR-004-frame-ordering-folder-filename.md).
- **D2. No disk preview cache.** All caches are in memory (the NFR row is updated).
- **D3. Undo covers decisions only.** That means keep, reject, favourite and reset. Undo does not cover navigation or view toggles. The undo stack lives in memory and doesn't survive a relaunch, but the marks themselves always do. Undo moves the cursor back to the frame it changed.
- **D4. The "Undecided only" filter is live.** When I decide a frame, it leaves the filtered list and the next undecided frame appears. When the filter is on, auto-advance is implied.
- **D5. 100% zoom means one image pixel per device pixel.** On the Air's Retina display, a 7728 × 5152 image therefore spans about 3× the screen width.
- **D6. Rejecting an archived frame removes its archive copy too.** If a frame that an earlier Apply archived is later changed to Reject, the next Apply removes its archive RAF, archive JPG and Google Photos JPG, and deletes it from the card (R26, §5.7).
  - Archive copies are **moved to the SSD's Trash**, so the removal can be recovered until the Trash is emptied. Card files are still deleted permanently. Only files FujiCull itself wrote for this card are eligible (SR9, SR18).
  - A file is removed only if the ledger shows FujiCull wrote it **and** its size and SHA-256 still match what was verified (SR18). Mtime isn't used, because exFAT times can shift with the Mac's time zone. A file that has been edited or replaced is left alone and reported.
  - If an archived frame is changed back to **Undecided**, its archive copy is left as it is, because "undecided" means "don't touch".
- **D7. Each card session remembers its trip folder.** Pre-flight pre-fills it on later runs, so re-runs don't scatter keepers by accident. You can still choose a different folder for **new** keepers, for example if you reused the card for a new trip without formatting. Every verified file records its own destination, so earlier copies are still found (SR9).

## 4. Architecture

```
┌──────────────────────────── FujiCullApp (executable) ─────────────────────────────┐
│ SwiftUI: App, menus (.commands), Settings, Apply sheets, overlay                   │
│ AppKit:  ViewerView (NSView), FilmstripView + GridView (NSCollectionView)          │
│ CullModel (@MainActor @Observable) — wraps CullSession, drives UI, saves session   │
│ VolumeMonitor (NSWorkspace mount/unmount)                                          │
└───────────────┬───────────────────────────────────────────┬───────────────────────┘
                │                                           │
┌───────────────▼──────────────┐            ┌───────────────▼──────────────────────┐
│ FujiCullImaging              │            │ FujiCullCore  (Foundation + CryptoKit) │
│ CardReader (actor, 1 queue)  │──uses──────▶ Scan:     SourceScanner, Frame         │
│ PreviewPipeline (T0/T1/T2)   │            │ Session:  CullSession, Command, Undo   │
│ PreviewCache (memory LRU)    │            │ Persist:  SessionStore, SessionKey    │
│ ExifReader (ImageIO)         │            │ Metadata: JPEG/EXIF/MakerNote/RAF     │
└──────────────────────────────┘            │           byte parsers (pure)         │
                                            │ Apply:    ApplyPlanner, ApplyExecutor,│
                                            │           Ledger, FileSystem protocol │
                                            └───────────────────────────────────────┘
```

Dependencies point one way: App → Imaging → Core, and App → Core. Core imports neither AppKit nor ImageIO.

### 4.1 Capability map

| Module id | Responsibility | Depends on | Requirements |
|---|---|---|---|
| `scan` | Find DCIM files, pair them, order them, flag orphans, ignore junk | — | R1–R5 |
| `session` | Decision states, favourites, undo, cursor, filter | scan | R7–R11 |
| `persist` | Session save, restore and reconcile | session | R19–R21 |
| `imaging` | Card reads, preview tiers, EXIF and film simulation | scan (metadata parsers) | R4, R17, NFR perf |
| `viewer` | Single, grid and filmstrip views, overlay, zoom, keymap, menus | session, imaging | R11–R18 |
| `apply` | Plan, then copy, verify, tag, confirm, delete; resume | session, persist | R6, R22–R25 |

Build order: `scan` → `session` → `persist` → `imaging` → `viewer` → `apply`. The `apply` planner and executor are pure Core code, so they can be built and tested alongside `imaging` and `viewer`. They are wired into the UI last.

## 5. Component design

### 5.1 Scanning and pairing (`scan`)

- **Input** is a root URL: either a volume root or any folder (R1). On a volume with `DCIM/` at its root, the scan covers **the whole volume** apart from hidden and system entries (SR1). Otherwise it covers the chosen folder recursively.
- **Enumeration** uses `FileManager.enumerator` with `[.skipsHiddenFiles]` and pre-fetched keys `fileSize`, `contentModificationDate` and `isRegularFile`. It also explicitly skips `._*`, `.Trashes`, `.Spotlight-V100`, `.fseventsd`, `System Volume Information` and Fuji's own folders (R5). Every remaining regular file goes into exactly one of three buckets:
  - **Frames:** `.JPG`/`.JPEG` and `.RAF` files, compared case-insensitively, then paired (below).
  - **Videos** (R27): `.MOV` and `.MP4` files, as `VideoItem`s.
  - **Other files**: everything else, for example `.HIF` (HEIF) photos or `.WAV` voice memos. They aren't culled or archived in v1, but they're always listed in pre-flight and in the summary (SR13). Pre-flight shows a prominent warning if HEIF files are present, because FujiCull v1 culls JPGs only.
- **Pairing** groups files by `(parent folder, case-folded base name)`.
  - A group with exactly one JPG and one RAF is a paired frame.
  - A group with exactly one of the two is an orphan with `isUnpaired = true` (R4).
  - Any other group, such as duplicates that differ only in case or a `.JPG` next to a `.JPEG`, is split: each file becomes its own orphan frame, and its FrameID keeps the **exact original filename** so no two frames share an identity (SR2).
- **Order** is by folder name, then filename, using a numeric-aware comparison (D1, ADR-004).
- **Frame identity** (SR2):
  - `FrameID` is the path **relative to the volume root** for any source on a removable volume, and relative to the chosen folder otherwise. Examples: `DCIM/102_FUJI/DSCF1234` for a pair, or `DCIM/102_FUJI/DSCF1234.JPG` for a split orphan. A card therefore yields the same FrameIDs however it was opened.
  - A stored decision or ledger record belongs to a frame only if the FrameID **and the exact byte size of every file still present in it** match. Capture time must also match **when both sides have one**.
- **Scan snapshot.** For each file, the scanner records `size` and `mtime`. Apply rescans the card when it starts, so its snapshot is never older than the run (SR16).
- **Performance.** Listing ~4,000 directory entries on an exFAT card takes well under a second. No file contents are read during the scan.

```swift
public struct Frame: Sendable, Hashable, Identifiable {
    public let id: FrameID
    public let jpg: SourceFile?   // nil for RAF-only orphans
    public let raf: SourceFile?   // nil for JPG-only orphans
    public var isUnpaired: Bool { jpg == nil || raf == nil }
}

public struct SourceFile: Sendable, Hashable {
    public let relativePath: String
    public let size: Int64
    public let modified: Date
}
```

### 5.2 Cull session (`session`)

`CullSession` is a value type with a pure `apply(_ command:) -> CullSession` style reducer. This makes every key in §4.3 a unit test.

- **State per frame:** `enum Decision { case undecided, keep, reject }` plus `isFavourite: Bool`. The invariant `isFavourite ⇒ decision == .keep` is enforced inside the reducer (R7, R8):
  - Favouriting an undecided or rejected frame sets it to Keep.
  - Rejecting or resetting a favourite clears the flag.
  - Keeping a favourite leaves it a favourite.
- **Commands:** `keep`, `reject`, `toggleFavourite`, `reset`, `next`, `previous`, `jump(±10)`, `undo`, `toggleUndecidedFilter`. View toggles (zoom, grid, EXIF) are UI state, not session state.
- **Auto-advance** (R11): after `keep` or `reject`, the cursor moves to the next frame in the current list. Turning auto-advance off is a stored preference.
- **Undo** (R10, D3): a stack of `(frameID, previousDecision, previousFavourite)`. Its size is unbounded, but it is tiny: a few bytes per action.
- **Counts** are kept incrementally for the overlay (R16), so the overlay never needs an O(n) recount per keypress.

### 5.3 Persistence (`persist`) — [ADR-005](decisions/ADR-005-session-persistence-json-per-card.md)

_Revised 2026-10-09 after two [doubt-review](reviews/2026-10-09-apply-doubt-review.md) rounds. Rule numbers (SR…) are referenced by the tasks._

- **Location:** for each card key, `~/Library/Application Support/FujiCull/` holds two files:
  - `Sessions/<key>.json` holds the decisions, cursor and filter.
  - `Ledger/<key>.jsonl` is the append-only Apply journal (§5.7).
  - There is **one session per card**; there are never several side by side.
- **Session key** (R20, SR1):
  - A source on a removable volume, whether the volume root or a folder inside it, is keyed by the volume's `volumeUUIDString`.
  - A folder on the internal disk is keyed by its canonical path.
- **Lock** (SR3): while a source is open, FujiCull holds an exclusive lock (`O_EXLOCK` on `Locks/<key>.lock`). A second window or process can't open the same card.
- **Restore** (SR2, SR4):
  1. Match every stored decision to the scan by frame identity (SR2). Frames whose files the ledger shows as deleted don't count.
  2. If every remaining frame matches, restore silently.
  3. If the match is partial, show what matched, for example "1,204 of 1,873 frames match your last session on this card", and ask: **Resume** (keep matching decisions, drop the rest, add new frames as Undecided) or **Start fresh**.
  4. On Start fresh, the old session and ledger move to `Archive/<key>-<date>/`. Their verified archive files stay where they are, and FujiCull never removes them later.
  5. A session with no stored decisions always restores, so there's no divide-by-zero.
- **Contents:** schema version, key, root path hint, decisions (only frames that aren't Undecided, each with its identity), cursor FrameID and filter flag. That's about 100–200 KB for 2,000 frames.
- **Writes** (SR5):
  - All session writes go through one `SessionStore` actor, which always serialises the latest state.
  - Writes are debounced by 300 ms and atomic (temp file, `F_FULLFSYNC`, rename).
  - They are flushed on quit, source close and unmount.
  - The ledger is a separate file.
- **The card is never written** during culling (R21). Only `ApplyExecutor` writes or deletes outside Application Support, which `scripts/check-boundaries.sh` enforces.

### 5.4 Preview pipeline (`imaging`) — [ADR-002](decisions/ADR-002-jpeg-first-preview-pipeline.md)

There are three tiers. Every read goes through one `CardReader` actor that serves requests from a priority queue: current frame, then +1, +2, +3, then −1, then visible thumbnails, then the background metadata pass. Stale requests are cancelled when the cursor moves.

| Tier | Source | Size | Cost from card | Used for |
|---|---|---|---|---|
| **T0** thumbnail + EXIF | First 64 KB of the JPG (APP1 is exactly 65,468 bytes on the X-T50), parsed by **our own** IFD parser. ImageIO can't read truncated files. | 160 × 120 (measured) | 6–13 ms (measured) | Filmstrip, grid, placeholder while scrolling, EXIF line, capture date |
| **T1** display | Whole JPG read, decoded downsampled to the window's pixel size (`kCGImageSourceThumbnailMaxPixelSize`, `CreateThumbnailFromImageAlways`) | ≤ 2560 px long edge | ~200 ms read + ~40 ms decode | Single view (fit) |
| **T2** full | Whole JPG, full decode | 5472 × 3648 at size M (80 MB RGBA); 7728 × 5152 at size L (160 MB) | ~170 ms read + **~45 ms** decode at M (measured) | 100% zoom only |

- **Spike S1 (done):** X-T50 JPGs have **no MPF preview**, so T1 reads the whole JPG. At size M a full decode (≈ 45 ms) is faster than a downsampled one (≈ 90 ms). T5 should measure whether to decode in full and let the layer scale, within the T1 memory budget.
- **RAF-only orphans** (R4): parse the RAF header (the magic is `FUJIFILMCCD-RAW`; a big-endian `UInt32` JPEG offset and length are at bytes 84 and 88). Read only the embedded JPEG and run it through the same T0 and T1 path. T2 isn't available for these; zoom shows the embedded preview at its maximum size.
- **Holding → (key repeat):** the viewer shows T0 instantly and requests T1 only once the key has been released, or after the cursor has rested for 120 ms. The card queue therefore never falls behind a run of 30 frames per second (NFR "never blocks").
- **Zoom and frame changes** (R12, amended): moving to another frame returns to fit and frees the T2 image, so only the current frame's T2 is ever loaded.
- **Background metadata pass:** after open, T0 is read for every frame in order. This fills the filmstrip, the EXIF and the capture dates. That's about 128 MB of small reads, probably 10–30 s, and it never blocks the UI. Apply doesn't need it, since folder names no longer include a date (Q10).
- **Memory budget:**

| Cache | Size |
|---|---|
| T0 (2,000 frames, stored compressed, ~10 KB each) | ~20 MB |
| Decoded T0 LRU (visible strip and grid) | ~30 MB |
| T1 (up to 8 frames at 2736 px, the JPEG ½ decode) | ~160 MB |
| T2 (current frame only) | 80 MB at size M (160 MB at L), only while zoomed |
| **Total** | **~210 MB normally, ~290 MB while zoomed (size M)** |

  All caches are cleared on source close or unmount, and the T2 cache is cleared when zoom is turned off.

### 5.5 Viewer and input (`viewer`) — [ADR-006](decisions/ADR-006-swiftui-shell-appkit-viewer.md)

- **App shell:** a SwiftUI `App` with one `Window` (single source at a time). It provides `.commands` menus (R13), a `Settings` scene (auto-advance, archive root), and sheets for the Apply flow. The dark appearance is forced on the window (R18).
- **`ViewerView` (NSView, layer-backed):**
  - The image is a `CALayer` using `contentsGravity = .resizeAspect`.
  - At 100% zoom, the layer is sized to the image's pixels divided by `backingScaleFactor`. Its position is mapped from the mouse fraction within the view to the image fraction (R12).
  - `keyDown` is overridden directly, which gives reliable `isARepeat` and avoids SwiftUI focus quirks.
- **Single command path:** `KeyMap` maps `(keyCode, modifiers)` to an `AppCommand`. `ViewerView`, the grid and every menu item call the same `CullModel.perform(_:)`. Menu items show the shortcut so it can be discovered. Spike S5 checks whether unmodified arrow keys are routed through the menu or the view, and dispatch is chosen so that each key fires exactly once.
- **Filmstrip and grid:** `NSCollectionView` with a flow layout. The filmstrip is horizontal and the grid wraps. They are virtualised, so 2,000 cells is fine. Each cell shows a T0 image plus a state badge: green Keep, red Reject, ♥, grey Undecided (R14, R15). In the grid, the same keys act on the selected cell.
- **Overlay** (R16, R17): a SwiftUI view in an `NSHostingView` layered over the viewer. It shows the filename, state, progress (`412 / 1,873`), counts, and the optional EXIF line.

### 5.6 Metadata

- Shutter speed, aperture, ISO and focal length come from our own EXIF IFD parser over the T0 bytes, because ImageIO returns nothing for a truncated buffer (S1).
- **Film simulation** (R17): confirmed in S2. ImageIO has no `{MakerFuji}` dictionary for these files, and its `{PictureStyle}` dictionary needs the whole file. A small pure parser in Core reads the Fuji MakerNote from the APP1 bytes. The MakerNote starts with `FUJIFILM` followed by an IFD offset, and is little-endian. The parser reads tag `0x1401` (FilmMode). For monochrome, it reads tag `0x1003` (Saturation), which encodes Acros and B&W variants. The value tables for newer simulations (Reala Ace, Nostalgic Neg) need checking against real files (spike S2). If a value is unknown, the film simulation is omitted from the EXIF line.
- **Capture date:** `DateTimeOriginal`, with `SubSecTimeOriginal` used to break ties, read from the same bytes.

### 5.7 Apply (`apply`) — [ADR-003](decisions/ADR-003-journaled-copy-verify-delete.md)

_Revised 2026-10-09 after two [doubt-review](reviews/2026-10-09-apply-doubt-review.md) rounds. Rule numbers (SR…) are referenced by the tasks. The guiding principle: **FujiCull only ever removes files it can prove it wrote, or files on the card it was asked to delete. When in doubt it stops and asks, and never guesses.**_

**Before planning:**

- **Freeze** (SR6). Apply is modal. From planning until the summary closes, culling commands are disabled.
- **Same card** (SR16). Apply rescans the card. Before every file read and every delete, it checks that the source volume's UUID still equals the session key, and that the file's size and mtime still match the fresh snapshot. A mismatch stops the run. A card swapped mid-session is therefore caught.
- **Archive identity** (SR7):
  - The archive is remembered by **volume UUID**, and its mount point is looked up every run. If it isn't mounted, Apply stops.
  - The executor opens the trip folder **once**, checks the UUID on that descriptor (`fstatfs`), and does every create, rename and unlink relative to it (`openat`, `renameatx_np`, `unlinkat`). Nothing can land on the internal disk.
  - FujiCull only ever creates the trip folder, directly in the volume root, plus its `Google Photos/` and `Videos/` subfolders.
- **Source rules** (SR8):
  - Apply refuses to run if the source and the archive are on the same volume.
  - Permanent deletion happens **only on a camera card**: a removable volume with `DCIM/` at its root.
  - Any other source has its rejects moved to the Trash. If no Trash is available, deletion is refused.
- **Archive lock** (SR3): an exclusive lock on the destination (archive UUID + folder name) is held for the whole run.

**Planner** (pure; does no I/O beyond the listings it's given). It takes the session, the fresh snapshot, metadata, the ledger, the archive listing and the trip folder, and returns an `ApplyPlan`. Everything is planned **per file**. A frame's files are its archive RAF, archive JPG and Google Photos JPG; a video has one file (SR9).

- **Destination** (Q10, D7): `<archive root>/<Trip name>/`, with `Google Photos/` and `Videos/` inside.
  - Existing entries are always addressed by their **exact on-disk name** from the listing.
  - Names are matched case-insensitively, without Unicode normalisation, as exFAT does. If more than one entry matches, Apply stops and asks (SR10).
  - If the folder exists and isn't in this card's ledger, pre-flight asks before adding to it.
  - Trip names are rejected if they:
    - contain control characters or `" * / : < > ? \ |`;
    - start or end with a space or dot;
    - are `.`, `..`, `.Trashes`, `.fseventsd`, `.Spotlight-V100` or `System Volume Information`;
    - are a Windows reserved name (`CON`, `PRN`, `AUX`, `NUL`, `COM1`–`9`, `LPT1`–`9`);
    - are longer than 200 UTF-16 units.
  - Existing folders are never renamed or reorganised.
- **Copies** (SR9):
  - One per Keep-frame archive file or video without a `verified` record whose source identity matches (SR2).
  - A **Google Photos copy** is made only for a frame whose Google Photos file has never been verified. It's made from the archive JPG just verified **in the same run**, re-hashed against the card's SHA-256. `Google Photos/` is a disposable staging folder: once its copy has been verified, FujiCull never recreates it, never requires it, and never complains if it has gone.
- **Names** (SR11):
  - A frame keeps one name across all of its files.
  - If the frame already has a `reserve` for that name, it **reuses** it, provided the name is still free or holds the frame's own reserved file.
  - Otherwise the planner picks the smallest `n ≥ 2` free for all of the frame's remaining files. "Taken" means present in the listing, reserved by **another** frame, or allocated earlier in this plan.
  - If some of a frame's files are verified under a name and another file can't get that name because a foreign file took it, the frame stops with a clear report, and the rest of the run continues.
- **Tags** (SR12):
  - "Favourite" is set on the archive RAF and JPG of every ♥ Keep frame.
  - It's removed **only from files FujiCull tagged** (a `tagged` record), when their frame is Keep without ♥.
  - Undecided frames and the Google Photos copy are never tagged. A file FujiCull creates is given exactly the tags FujiCull intends, which clears anything inherited from an orphaned `._` file.
- **Card deletes:** every Reject frame still present on the card, unless the card is locked (R6).
- **Archive removals** (D6, R26): the archive RAF and JPG of every Reject frame, but **only** files with a `reserve` → `verified` chain in this card's ledger whose source identity matches. Files from someone else, from another card, or from a started-fresh session are never eligible.
  - This runs even when the card is locked. It's recorded, so it's never planned twice.
  - The Google Photos copy is removed too if it's still present and unchanged. If it's missing, the RAF and JPG removal goes ahead regardless.
- **Left on card, not archived** (SR13): Undecided frames and **other files**, listed in pre-flight and in the summary with a warning that formatting the card loses them.
- **Space** (SR14): the bytes still to copy, each file rounded up to the volume's allocation size, plus one allocation unit per file for its `._` companion, plus the Google Photos copies, plus a 1 GB margin.

**Ledger** (SR5, SR15): `Ledger/<key>.jsonl`, an append-only JSON-lines journal with `F_FULLFSYNC` after every record. **One record per file per operation, written immediately after that operation.**

| Record | Holds |
|---|---|
| `destination` | Archive volume UUID, the folder's exact on-disk name |
| `reserve` | Frame or video, file role, destination folder, final name, the partial's name. Written before the file is created. |
| `verified` | As `reserve`, plus the source identity (path, size, mtime, capture time, SHA-256) and the destination's size and SHA-256. Written only after the data **and the rename** are durable. |
| `tagged` / `untagged` | File |
| `trashed` | File, with the `resultingItemURL` |
| `deleted` | Card file |
| `released` | A reservation abandoned during a sweep, so the name is free again |

The **latest** record for a file is authoritative. When a journal is opened, a torn final line is truncated back to the last complete newline, then fsynced. A corrupt line anywhere else stops Apply and asks the user. The journal is never rewritten.

**Executor** (async, cancellable, one file at a time):

1. **Sweep.** Remove `.fujicull-partial` files that the ledger reserved but never verified, and append `released`. Any other `*.fujicull-partial` in the trip folder (a name pattern only FujiCull uses) is listed in pre-flight and removed after confirmation.
2. **Copy and verify** each file:
   1. Append `reserve`.
   2. Create the partial with `O_CREAT | O_EXCL`, with `F_NOCACHE` set on the **write** descriptor.
   3. Stream the source in 8 MB chunks, computing SHA-256 on the fly.
   4. `F_FULLFSYNC` the partial.
   5. Read it back through a new `F_NOCACHE` descriptor and compare hashes.
   6. Set the destination's modification date to the source's.
   7. **Claim the final name** with a zero-length placeholder created via `O_CREAT | O_EXCL`, then rename the partial over it. The rename only ever replaces FujiCull's own placeholder, so nothing else can be overwritten even on exFAT (SR10).
   8. `F_FULLFSYNC` the directory, then `fstat` the final file.
   9. Append `verified`.
   - If the final name already holds a file and the ledger has a `reserve` for it (a crash after the rename), the file is hashed. It's recorded `verified` only if it matches.
   - Any mismatch, I/O error or name conflict stops that frame and the run. Nothing is deleted anywhere.
3. **Tag**, and append `tagged` or `untagged`.
4. **Gate** (SR17). Deletion is offered only if:
   - every Keep frame on the card has a `verified` archive RAF and JPG (for an orphan, the files it has);
   - every video is `verified`;
   - each of those files exists on the archive now, with its recorded size. If a file is missing or changed, Apply doesn't copy it again silently; it lists the file and offers **Copy again** (as a new file) or **Cancel**;
   - if the trip folder itself is missing, Apply offers **Locate folder…** (re-checked by size and hash) or **Cancel**, and never recreates it silently.
   - `Google Photos/` is not part of the gate.
5. **Confirm.** A modal shows the counts, with an expandable list of every file to be deleted from the card or moved to the Trash (R26). Its wording matches the action ("cannot be undone" only for card deletion). **Cancel** is the default button.
6. **Remove archive copies** (D6, SR18).
   - Before each frame, check for cancellation and the archive's identity.
   - Check **all** of the frame's eligible files first: each must exist with its recorded size and re-hash to its recorded SHA-256.
   - Then move each one to the Trash and append `trashed` immediately after each move. Files already `trashed` count as done.
   - If any check fails, skip the frame and report it.
7. **Delete from the card** (SR19).
   - Before each frame, check for cancellation and the identity of both volumes (SR16).
   - Check **all** of the frame's files first: the decision must still be Reject, each file must match the snapshot, and each must be deletable (no `uchg` or read-only flag).
   - Then delete each file and append `deleted` immediately after each one.
   - If the second unlink of a pair fails anyway, the remaining file keeps its Reject decision (identity covers only the files still present) and is reported as "pair split, retry". Completed deletions are reported, never "undone".
8. **Summary:**
   - copied, verified, tagged;
   - removed from the archive (with Trash paths), deleted from the card, skipped (with reasons);
   - left on card, with its warning;
   - "Reveal in Finder";
   - an **Eject C&J Archive** button, recommended before unplugging the SSD (SR20).

**Undo** (SR21): undo entries for frames whose files Apply deleted are dropped, because there's nothing left to undo. All other undo history is kept (R10).

**Interruption** (R23):

- `VolumeMonitor` cancels the executor's `Task` when either volume is about to unmount or unmounts. Any I/O error does the same.
- Cancellation is checked between copy chunks and before every frame in steps 6 and 7.
- A `ProcessInfo` activity assertion stops the Mac from idle-sleeping during Apply.
- **Resume** sweeps (step 1), then replans from the journal.

**Accepted trade-offs:**

- **SR22: single read.** The source is hashed from a single read of the card. A reader that silently returns corrupted bytes, without an I/O error, would yield a "verified" copy of those bad bytes. USB and the SD bus both carry CRCs, so this is very unlikely, and a re-read would cost about 10 minutes per trip. It could become a "double-read" preference later.
- **SR23: lost journal.** If the journal is lost, files already on the archive aren't recognised. A re-run copies them again under `-n` names, which costs duplicates but loses nothing, and they're never eligible for removal.
- **SR24: time-zone change.** If the Mac's time zone changes between the Apply rescan and a delete, the card's mtimes shift and the frames are skipped with the reason "time zone changed; run Apply again". This fails safe.

**Throughput estimate:** keepers are typically about 30% of a 180 GB card, so about 55 GB at about 90 MB/s, which is roughly 10–11 minutes for the copy. The Google Photos copies are SSD to SSD and add about 1 minute.

## 6. Tech stack

- Swift 6.3 in Swift 6 language mode, with strict concurrency.
- SwiftPM tools version 6.0. Platform `.macOS(.v14)`, arm64 only.
- System frameworks only: Foundation, CryptoKit, ImageIO, CoreGraphics, QuartzCore, AppKit, SwiftUI, UniformTypeIdentifiers, os (Logger and signposts).
- **No third-party dependencies.**

## 7. Commands

```
make build      # swift build -c release
make test       # swift test with the CLT Testing.framework search/rpath flags (see ADR-001)
make app        # build + assemble build/FujiCull.app (Info.plist, icon) + codesign --force --sign -
make run        # make app && open build/FujiCull.app
make format     # swift format --in-place --recursive Sources Tests
make lint       # swift format lint --strict --recursive Sources Tests
make clean
```

The `make test` flags were verified on this Mac (Swift 6.3.3, CLT only). Plain `swift test` fails with `no such module 'Testing'` unless the CLT framework directory is passed with `-F` and set as an rpath.

## 8. Project structure

```
Package.swift
Makefile
Resources/Info.plist                 → bundle metadata (LSMinimumSystemVersion 14.0, dark appearance)
Sources/FujiCullCore/
  Scan/       SourceScanner, Frame, FrameID
  Session/    CullSession, Decision, Command, UndoStack
  Persist/    SessionStore, SessionKey, SessionFile (Codable)
  Metadata/   JPEGSegments, ExifIFD, FujiMakerNote, RAFHeader   (pure byte parsers)
  Apply/      ApplyPlanner, ApplyPlan, ApplyExecutor, Ledger, FileSystem (+ LocalFileSystem)
Sources/FujiCullImaging/
  CardReader, PreviewPipeline, PreviewCache, ExifReader
Sources/FujiCullApp/
  FujiCullApp.swift, CullModel, KeyMap, AppCommand, VolumeMonitor
  Viewer/     ViewerView, FilmstripView, GridView, OverlayView
  Apply/      ApplySheet, PreflightView, ProgressView, SummaryView
Tests/FujiCullCoreTests/             → Swift Testing; temp-dir and fault-injection tests
Tests/FujiCullImagingTests/          → fixture-based
Tests/Fixtures/                      → trimmed real X-T50 files (≤ ~2 MB total) + generated trees
docs/  REQUIREMENTS.md, DESIGN.md, decisions/ADR-*.md
tasks/ plan.md, todo.md              → next phase
```

## 9. Code style, testing and boundaries

**Style.** Apply `swift format` with its defaults. Prefer value types and pure functions in Core. Use `actor` for shared mutable I/O state. Put `@MainActor` only on UI types. Avoid force-unwrapping outside tests. Errors are typed enums with user-readable messages. For example:

```swift
public enum ApplyError: Error, Equatable {
    case insufficientSpace(needed: Int64, available: Int64)
    case verificationFailed(file: String)
    case volumeDisappeared(VolumeRole)
    case destinationExists(file: String)
}

public func plan(_ input: ApplyInput) throws(ApplyError) -> ApplyPlan
```

**Testing.**

| Level | What | How |
|---|---|---|
| Unit (Core) | Pairing edge cases (case, orphans, hidden files, counter wrap across folders); every keymap command and the favourite invariant; undo; filter; session reconcile; planner (collisions, re-runs, undecided frames, D6, D7, the R22 gate) | Swift Testing; generated temp-dir trees made of zero-byte or small files |
| Integration (Core) | The executor against real temp directories, using a `FaultyFileSystem` that injects: an I/O error at write N, a corrupted read-back, a vanished volume mid-copy, an EXCL conflict, a crash between rename and ledger write. **Assert that nothing is deleted from the source in any fault case**, and that a re-run converges. | Swift Testing |
| Fixture (Imaging) | T0 extraction, RAF embedded preview, EXIF and film-simulation decoding on real X-T50 samples | Trimmed fixture files |
| Performance | Open time, next-frame latency, zoom latency, measured on a real card with `os_signpost` and logged in a debug overlay | Manual run against the NFR targets |
| Manual end-to-end | A full Apply rehearsal against a **folder copy** of a card on the real SSD, before the first real trip | Checklist in `tasks/` |

Coverage goal: every Apply branch in Core is exercised by at least one test. There's no UI automation, because that needs Xcode.

**Boundaries.**

- *Always:*
  - Run `make test` before committing.
  - Keep `FujiCullCore` free of AppKit and ImageIO.
  - Route every write or delete outside Application Support through `ApplyExecutor`.
  - Update this document or an ADR when the design changes.
- *Ask first:*
  - Adding any dependency.
  - Changing the Apply sequence, the deletion gate or the collision rules.
  - Changing the session file schema (this needs a migration).
  - Amending REQUIREMENTS.md.
- *Never:*
  - Modify or delete source files outside the confirmed delete step.
  - Overwrite a file on the SSD.
  - Remove an archive file that FujiCull didn't write, or that has changed since FujiCull verified it.
  - Use the Trash on the card.
  - Point tests at real volumes.
  - Commit full-size photos.

## 10. Risks, spikes and open questions

### Spikes (each is about 1 hour; run on the Mac with a real card before or during the matching task)

| # | Question | Fallback if the answer is no |
|---|---|---|
| S1 | Is X-T50 APP1 (EXIF + thumbnail + MakerNote) within the first 64 KB? How big is the IFD1 thumbnail? Is there an MPF preview, and at what size? | Read 128 KB. Without MPF, T1 reads the whole JPG (as designed). |
| S2 | Which MakerNote tags and values encode each X-T50 film simulation (including Reala Ace, Nostalgic Neg, Acros variants)? | Show "—" for unknown values. |
| S3 | Does an exFAT SD card report a stable `volumeUUIDString`? Does the SD lock switch mount it read-only (`volumeIsReadOnly`)? | Key the session by the volume identifier, then by FrameID set overlap. Detect write-lock with an access check. |
| S4 | What are the real throughput and decode times (card read MB/s, T1 decode, T2 decode on the M2)? | Raise prefetch depth, or use an MPF T1 if S1 finds one. |
| S5 | Do unmodified arrow and Return keys plus key repeat behave correctly with SwiftUI `.commands` and an AppKit first responder? | Show shortcuts in the menu titles only, without key equivalents, and dispatch only from the view. |
| S6 | What format is the archive SSD? Do Finder tags and `RENAME_EXCL` work on it? | On exFAT, tags create `._` files and EXCL needs a check-then-rename fallback. The recommendation is APFS. |

### Risks

- **Full-resolution decode memory** (~160 MB per frame) while zoomed with prefetch. This is capped at 2 frames and cleared when zoom is turned off.
- **100% zoom under 300 ms** when the frame isn't prefetched: about 200 ms to read plus about 150 ms to decode exceeds the target. It's met only when zoom is already on and the next T2 has been prefetched. If zoom is toggled cold on a new frame, expect about 350 ms. See S4.
- **No Xcode** means no Instruments, no XCUITest and no `.xcodeproj` debugger UI. Mitigations: `os_signpost` logging, `lldb` from the command line, and the manual checklist.
- **Ad-hoc signing.** Gatekeeper is fine for a locally built app. macOS may ask once for access to removable volumes; that permission is granted to the ad-hoc signature, and it may be asked again after a rebuild.

### Questions — answered 2026-10-09

| # | Question | Answer |
|---|---|---|
| Q1 | Order by DCIM folder, then filename? | **Yes.** R3 amended (ADR-004 accepted). |
| Q2 | No disk preview cache? | **Yes.** NFR updated. |
| Q3 | Rejecting an archived frame later? | **Remove the archive copy too.** See D6 and R26. Archive copies go to the SSD's Trash. |
| Q4 | Sample X-T50 files | **Provided** in `Sample Images/` (gitignored). S1 and S2 are done. |
| Q5 | Undo scope | **OK** (D3). |
| Q6 | SSD format | **exFAT** ("C&J Archive", 2 TB, shared with Windows). See the [hardware probe](spikes/2026-10-09-hardware-probe.md). Follow-ups are Q10 and Q11. |
| Q11 | Which copies get the Favourite tag | **Archive RAF and JPG only**, not the Google Photos copy, so a Finder search shows each favourite once. Requirements §4.6 step 4 amended. |
| Q12 | Videos (`.MOV`) and other non-photo files on the card | **Copy videos to `<Trip name>/Videos/`** (R27): verified like photos, never deleted from the card. Other non-photo files are listed as left on card (SR13). |
| Q10 | Archive folder layout | **Flat `<Trip name>/` at the SSD root**, matching the existing archive. Requirements §4.6 step 2 amended; A4 (folder date) superseded. |
| Q7 | Command Line Tools only | **Yes.** |
| Q8 | Undecided filter (D4) | **OK.** |
| Q9 | 100% = 1 image px per device px (D5) | **OK.** |

## 11. Requirements traceability

| Req | Where |
|---|---|
| R1–R5 | §5.1 |
| R6 | §5.7 (gate), S3 |
| R7–R10 | §5.2 |
| R11–R13 | §5.2, §5.5 |
| R14–R18 | §5.5, §5.6 |
| R19–R21 | §5.3 |
| R22–R27 | §5.7 |
| NFR open < 2 s | §5.1 (no content reads in scan), §5.4 (T0 for visible cells first) |
| NFR next < 100 ms, holding → | §5.4 prefetch, key-repeat rule |
| NFR zoom < 300 ms | §5.4, risk noted |
| NFR disk / memory | §5.4 budget, ADR-002 |
| NFR safety | §5.7, ADR-003 |
| NFR platform / size | §6, ADR-001 |

## 12. Next step

The task breakdown is in [tasks/plan.md](../tasks/plan.md) and [tasks/todo.md](../tasks/todo.md).

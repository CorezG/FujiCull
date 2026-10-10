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

- **Input** is a root URL: either a volume root or any folder (R1). On a camera card (§5.7, SR8), the scan covers **the whole volume** apart from hidden and system entries, whichever folder on it was opened (SR1). Otherwise it covers the chosen folder recursively.
- **Enumeration** uses `FileManager.enumerator` with `[.skipsHiddenFiles]` and pre-fetched keys `fileSize`, `contentModificationDate` and `isRegularFile`. It also explicitly skips `._*`, `.Trashes`, `.Spotlight-V100`, `.fseventsd`, and these folders when they sit at the root: `System Volume Information`, `$RECYCLE.BIN`, and the camera's bookkeeping folders `FFDB`, `ACTIVITY` and `UPD` (R5). `DCIM/` and everything in it is always scanned. Files carrying the hidden attribute are skipped too; Apply counts skipped items in its "left on card" warning (SR13). Every remaining regular file goes into exactly one of three buckets:
  - **Frames:** `.JPG`/`.JPEG` and `.RAF` files, compared case-insensitively, then paired (below).
  - **Videos** (R27): `.MOV` and `.MP4` files, as `VideoItem`s.
  - **Other files**: everything else, for example `.HIF` (HEIF) photos or `.WAV` voice memos. They aren't culled or archived in v1, but they're always listed in pre-flight and in the summary (SR13). Pre-flight shows a prominent warning if HEIF files are present, because FujiCull v1 culls JPGs only.
- **Pairing** groups files by `(parent folder, case-folded base name)`.
  - A group with exactly one JPG and one RAF is a paired frame.
  - A group with exactly one of the two is an orphan with `isUnpaired = true` (R4).
  - Any other group, such as duplicates that differ only in case or a `.JPG` next to a `.JPEG`, is split: each file becomes its own orphan frame, and its FrameID keeps the **exact original filename** so no two frames share an identity (SR2).
- **Order** is by folder name, then filename, using a numeric-aware comparison (D1, ADR-004).
- **Frame identity** (SR2):
  - `FrameID` is the path **relative to the volume root** on a camera card, and relative to the chosen folder otherwise. Examples: `DCIM/102_FUJI/DSCF1234` for a pair, or `DCIM/102_FUJI/DSCF1234.JPG` for a split orphan. A card therefore yields the same FrameIDs however it was opened.
  - A stored decision or ledger record **binds** to a frame only if the FrameID, **the exact byte size of every file still present in it**, and the **capture time** all match. Capture time is the EXIF original date and time, with the sub-second part where the camera writes one.
  - A saved **decision** with no capture time on either side doesn't bind: the frame goes back to Undecided. A frame with no capture time is never deleted from the card.
  - A journal record for a file with no capture time on **either** side (a video, or a JPG without EXIF) binds by path, size and the file's own modification date instead. This only ever decides whether to skip a copy, so the worst case is a duplicate; without it such files would be copied again on every run. If one side has a capture time and the other doesn't, nothing binds.
  - A frame all of whose files have `deleted` records is **closed**. Nothing binds to it again; a file that later appears at that path is a new frame. So a card that is formatted and refilled can't inherit an old Reject, whether or not formatting changes the volume UUID.
- **Scan snapshot.** For each file, the scanner records `size` and `mtime`. Apply rescans the card when it starts, so its snapshot is never older than the run (SR16).
- **Performance.** Listing ~4,000 directory entries on an exFAT card takes well under a second. No file contents are read during the scan; capture times arrive with the background metadata pass (about 5 s for a whole card).

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
  - A camera card (§5.7, SR8) is keyed by its `volumeUUIDString`, whichever folder on it was opened. Its FrameIDs are relative to the volume root and the whole card is scanned.
  - A camera card **without a volume UUID** is keyed by its capacity and the wall-clock time it was formatted (`card-<bytes>-<yyyyMMddTHHmmss>`). The X-T50 formats small (FAT32) cards with no volume serial, so macOS reports no UUID and names every such card "NO NAME" (measured 2026-10-10). A format therefore starts a new session for these cards. If the format time is missing too, the key falls back to the path.
  - Any other folder, on the internal disk or on any other drive, is keyed by its canonical path, so two folders on one drive have separate sessions.
- **Lock** (SR3): while a source is open, FujiCull holds an exclusive lock (`O_EXLOCK` on `Locks/<key>.lock`). A second window or process can't open the same card.
- **Restore** (SR2, SR4):
  1. Match every stored decision to the scan by FrameID and file sizes. Frames whose files the ledger shows as `deleting` or `deleted` don't count.
  2. If every remaining frame matches, restore silently.
  3. If the match is partial, show what matched, for example "1,204 of 1,873 frames match your last session on this card", and ask: **Resume** (keep matching decisions, drop the rest, add new frames as Undecided) or **Start fresh**.
  4. On Start fresh, the old session and ledger move to `Archive/<key>-<date>/`. Their verified archive files stay where they are, and FujiCull never removes them later.
  5. A session with no stored decisions always restores, so there's no divide-by-zero.
  6. As the metadata pass reads each frame's capture time, a restored decision whose stored capture time differs, or is missing, is dropped: the frame goes back to Undecided, and a notice says how many decisions from an earlier session didn't match these photos (SR2). Apply never starts before this has finished.
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

_Revised 2026-10-09 after two [doubt-review](reviews/2026-10-09-apply-doubt-review.md) rounds, and 2026-10-10 after a third, with the file-system behaviour it relies on measured in the [exFAT spike](spikes/2026-10-10-exfat-fskit.md). Rule numbers (SR…) are referenced by the tasks. The guiding principle: **FujiCull only ever removes files it can prove it wrote, or files on the card it was asked to delete. When in doubt it stops and asks, and never guesses.**_

**Before planning:**

- **Freeze** (SR6). Apply is modal. From planning until the summary closes, culling commands are disabled.
- **Same card** (SR16). Apply rescans the card and waits for the metadata pass, so every frame's capture time is known (SR2).
  - Before every file read and every delete, it checks that the card's identity, read from the open descriptor, still equals the session key: the volume UUID, or for a card without one its capacity and format time (§5.3). A mismatch **stops the run**. A card swapped mid-session is therefore caught.
  - It also checks that the file's size and mtime still match the fresh snapshot. A mismatch **skips that frame** and reports it; SR24 covers the time-zone case.
- **Archive identity** (SR7):
  - The archive is remembered by **volume UUID**, and its mount point is looked up every run. If it isn't mounted, Apply stops.
  - The executor opens each destination folder **once**, reads the volume UUID from that descriptor with `fgetattrlist(ATTR_VOL_UUID)`, and does every create, rename and unlink relative to it (`openat`, `renameat`, `unlinkat`). Nothing can land on the internal disk.
  - Two operations take a path and can't be descriptor-relative: Finder tags and the move to the Trash. Immediately before each one, the executor re-reads the descriptor's UUID and checks that the path names the same file the descriptor sees (same device and file number). The remaining window is an accepted trade-off (below).
  - FujiCull only ever creates the trip folder, directly in the volume root, plus its `Google Photos/` and `Videos/` subfolders.
- **Source rules** (SR8):
  - Apply refuses to run if the source and the archive are on the same volume.
  - Terms, as measured: a volume is **external** when `volumeIsInternal` is false. A **camera card** is an external volume that reports `volumeIsRemovable` and has `DCIM/` at its root with at least one `NNN_FUJI` folder. The owner's reader reports SD cards as removable; the USB SSD reports not removable.
  - Permanent deletion happens **only on a camera card**.
  - Any other source has its rejects moved to the Trash. If no Trash is available or the move fails, deletion is refused. It never falls back to permanent deletion.
- **Archive lock** (SR3): an exclusive lock on the destination (archive UUID + folder name) is held for the whole run.

**Planner** (pure; does no I/O beyond the listings it's given). It takes the session, the fresh snapshot, metadata, the ledger **after recovery** (executor step 1), the archive listings with each owned file's current tags, and the trip folder, and returns an `ApplyPlan`. Everything is planned **per file**. A frame's files are its archive RAF, archive JPG and Google Photos JPG; a video has one file (SR9).

- **Destinations** (Q10, D7): `<archive root>/<Trip name>/`, with `Google Photos/` and `Videos/` inside.
  - Every `reserve` and `verified` record names its destination: the archive volume UUID and the folder's exact on-disk name. New copies go to the folder chosen in pre-flight. Final checks and archive removals address each file in its **recorded** destination, so keepers filed under an earlier folder are still found.
  - **Pre-flight resolves every destination the plan refers to before anything is copied.** A recorded folder that is missing gets **Locate folder…** (accepted only if the recorded files are there, by size and hash) or **Cancel**. A recorded volume that isn't mounted is named; new keepers can still be copied, but card deletion isn't offered.
  - The chosen folder is created only when the volume says no entry of that name exists: `mkdirat`, and "already exists" means stop and ask. If the folder exists and isn't in this card's ledger, pre-flight asks before adding to it.
  - Trip names are rejected if they:
    - contain control characters or `" * / : < > ? \ |`;
    - start or end with a space or dot;
    - are `.`, `..`, `.Trashes`, `.fseventsd`, `.Spotlight-V100` or `System Volume Information`;
    - are a Windows reserved name (`CON`, `PRN`, `AUX`, `NUL`, `COM1`–`9`, `LPT1`–`9`);
    - are longer than 200 UTF-16 units.
  - Existing folders are never renamed or reorganised.
- **Existing names** (SR10):
  - Existing entries are always addressed by their **exact on-disk name** from the listing.
  - Whether a name is taken is **the volume's answer**, never FujiCull's own folding. The volume treats names that differ in case, or in Unicode composition, as the same name (measured). The planner uses the listing to choose names, comparing the camera's ASCII names case-insensitively; the executor's exclusive create is the authority.
  - If more than one listing entry matches a name, Apply stops and asks.
- **Copies** (SR9):
  - One per Keep-frame archive file or video without a `verified` record that binds to it (SR2).
  - A **Google Photos copy** is planned for a Keep frame whose Google Photos file has no `verified` record newer than its archive JPG's. It's made from the archive JPG. The bytes are hashed as they stream and must equal the SHA-256 recorded from the card; if they don't, no copy is made and the frame is reported.
  - `Google Photos/` is a disposable staging folder: once a copy has been verified, FujiCull never recreates it (unless the frame's archive JPG is itself copied again), never requires it, and never complains if it has gone.
- **Names** (SR11):
  - A frame keeps one name across all of its files.
  - If the frame already has a `reserve` for that name, it **reuses** it, provided the name is still free.
  - Otherwise the planner picks the smallest `n ≥ 2` free for all of the frame's remaining files. "Taken" means present in the listing, reserved by **another** frame, or allocated earlier in this plan.
- **Re-homing** (SR26). A frame can't keep one name when:
  - a foreign file holds a name one of its files needs;
  - one of its archive files is missing or changed and the owner chose **Copy again**; or
  - recovery found a file at its reserved name that isn't its own.

  In each case the **whole frame is copied again under a fresh joint name**. Its earlier files stay where they are and their records are marked `superseded`: the gate doesn't count them, FujiCull never removes them, and the summary lists them as duplicates the owner may want to delete. This costs a duplicate (about 100 MB per frame) and never blocks the run or the card.
- **Tags** (SR12):
  - "Favourite" is set on the archive RAF and JPG of every ♥ Keep frame.
  - It's removed **only from files FujiCull tagged** (a `tagged` record), when their frame is Keep without ♥.
  - A file FujiCull creates is given exactly the tags FujiCull intends **when it is created**, which clears anything inherited from an orphaned `._` file. After that, FujiCull only adds or removes "Favourite" and leaves every other tag alone.
  - Tag operations are planned from each file's actual tags, so a tag lost to an unplug is applied again on the next run.
  - Undecided frames and the Google Photos copy are never tagged.
- **Card deletes:** every Reject frame still present on the card, unless the card is locked (R6). A frame without a capture time is never deleted (SR2); it's listed as "no capture date, not deleted".
- **Archive removals** (D6, R26): the archive RAF and JPG of every Reject frame, but **only** files with a current (not superseded) `reserve` → `verified` chain in this card's ledger that binds to the frame. Files from someone else, from another card, or from a started-fresh session are never eligible.
  - This runs even when the card is locked. It's recorded, so it's never planned twice.
  - The Google Photos copy is removed too if it's still present and unchanged. If it's missing, the RAF and JPG removal goes ahead regardless.
- **Left on card, not archived** (SR13): Undecided frames and **other files**, listed in pre-flight and in the summary with a warning that formatting the card loses them. Hidden and system items that the scan skips are counted in that warning, not listed.
- **Space** (SR14): the bytes still to copy, each file rounded up to the volume's allocation size, plus one allocation unit per file for its `._` companion (measured: every file written gets one), plus the Google Photos copies, plus a 1 GB margin.

**Ledger** (SR5, SR15): `Ledger/<key>.jsonl`, an append-only JSON-lines journal with `F_FULLFSYNC` after every record. **One record per file per operation.** Records of destructive operations come in pairs: the intent before, the outcome after (SR25).

| Record | Holds |
|---|---|
| `destination` | Archive volume UUID, the folder's exact on-disk name |
| `reserve` | Frame or video, file role, destination, final name, the partial's name. Written before the file is created. |
| `verified` | As `reserve`, plus the source identity (path, size, mtime, capture time, SHA-256) and the destination's size and SHA-256. Written only after the data **and the rename** are durable. |
| `released` | A reservation abandoned during recovery |
| `superseded` | A verified file replaced by a re-homed copy (SR26) |
| `tagged` / `untagged` | File |
| `trashing` → `trashed` | File; `trashed` adds the `resultingItemURL` |
| `deleting` → `deleted` | Card file |

- Records fall into three families: a destination file's **state** (`reserve`, `verified`, `released`, `superseded`, `trashing`, `trashed`), its **tag** (`tagged`, `untagged`), and a **card file's** state (`deleting`, `deleted`). A destination file is identified by destination + final name; a card file by its path. The **latest record within a family** is authoritative.
- When a journal is opened, a torn final line is truncated back to the last complete newline, then fsynced. The journal is never rewritten.
- A corrupt line anywhere else stops Apply. The owner can **Start fresh for this card** (the journal is archived; files already on the archive will be copied again as duplicates and are never removed) or **Cancel**.

**Executor** (async, cancellable, one file at a time):

1. **Recover, then sweep** (SR25). This runs before planning, so the planner only ever sees settled state.
   - For every `reserve` with no later state record, in its destination:
     - If the final name holds a **zero-length** file, it's FujiCull's own placeholder from a crash between claiming the name and the rename. Remove it.
     - If the final name holds a non-empty file, the crash came after the rename. Hash that file and the card file. If they match, append `verified`. If they don't, leave the file alone and append `released`; the frame is re-homed (SR26).
     - If the partial is still there, remove it, and append `released` unless the file was just verified.
   - `trashing` without `trashed`: if the archive file is gone, append `trashed` (location not recorded); if it's still there, leave it to the planner.
   - `deleting` without `deleted`: if the card file is gone, append `deleted`; if it's still there, leave it to the planner.
   - Any other `*.fujicull-partial` in a destination folder (a name pattern only FujiCull uses) is listed in pre-flight and removed after confirmation.
2. **Copy and verify** each file:
   1. Append `reserve`.
   2. Create the partial with `O_CREAT | O_EXCL`, with `F_NOCACHE` set on the **write** descriptor. This is what makes step 5 real: data written this way isn't in the cache, so the read-back comes from the device (measured; `F_NOCACHE` on the read side alone does not bypass the cache).
   3. Stream the source in 8 MB chunks, computing SHA-256 on the fly.
   4. `F_FULLFSYNC` the partial. An error here fails the copy; it's never downgraded to a plain `fsync`.
   5. Read it back through a new descriptor, as the first read of that file, and compare hashes.
   6. Set the destination's modification date to the source's.
   7. **Claim the final name** with a zero-length placeholder created via `O_CREAT | O_EXCL`, then rename the partial over it. The rename only ever replaces FujiCull's own placeholder, so nothing else can be overwritten (SR10). An exclusive rename isn't available on this driver (measured). "Already exists" at the claim is a name conflict.
   8. `F_FULLFSYNC` the directory, then `fstat` the final file and check its size.
   9. Append `verified`.
   - An I/O error or a hash mismatch **stops the run**. A name conflict **re-homes that frame** (SR26) and the run continues. Nothing is deleted anywhere.
3. **Tag**, and append `tagged` or `untagged`.
4. **Final check** (SR28). This always runs, even when nothing is to be deleted and when the card is locked. Every Keep frame's and video's current archive files are looked up in their recorded destinations: each must exist with its recorded size. The summary's "on the archive" numbers come from this check, never from the journal alone. Anything missing or changed is listed, with **Copy again** (SR26) or **Leave**.
5. **Gate** (SR17). Archive removal and card deletion are offered only if:
   - the final check passed for every Keep frame and every video on the card (for an orphan, the files it has);
   - every one of those files that was verified in an **earlier** run re-hashes to its recorded SHA-256 now (this run's files were hashed from the device minutes ago);
   - every destination was reachable.

   Card deletion also needs the card not to be read-only. Archive removal doesn't. `Google Photos/` is not part of the gate.
6. **Confirm.** A modal shows the counts, with an expandable list of every file to be deleted from the card or moved to the Trash (R26). Its wording matches the action ("cannot be undone" only for card deletion). **Cancel** is the default button.
7. **Remove archive copies** (D6, SR18).
   - Before each frame, check for cancellation and the archive's identity.
   - Check **all** of the frame's eligible files first: each must exist with its recorded size and re-hash to its recorded SHA-256.
   - Then, for each file: append `trashing`, move it to the Trash with `FileManager.trashItem` (measured: the same volume's Trash, a unique name on collision, tags kept), and append `trashed`. Files already `trashed` count as done.
   - If a check or a move fails, skip the frame and report it. A file is never unlinked instead.
8. **Delete from the card** (SR19).
   - Before each frame, check for cancellation and the identity of both volumes (SR16).
   - Check **all** of the frame's files first: the decision must still be Reject, the frame must have a capture time, each file must match the snapshot, and each must be deletable (no `uchg` or read-only flag).
   - Then, for each file: append `deleting`, `unlinkat`, and append `deleted`.
   - If the second unlink of a pair fails anyway, the remaining file keeps its Reject decision (identity covers only the files still present) and is reported as "pair split, retry". Completed deletions are reported, never "undone".
   - **Card durability** (SR27): `F_FULLFSYNC` the card folder's descriptor after each folder's deletions and at least every 100 files, so an unplug or sleep can only affect the last few directory updates.
9. **Summary:**
   - copied, and on the archive now (from the final check); tagged;
   - removed from the archive (with Trash paths), deleted from the card, skipped (with reasons);
   - duplicates left by re-homing;
   - left on card, with its warning;
   - "Reveal in Finder";
   - **Eject** buttons for the card and for C&J Archive, with "eject before unplugging" (SR20).

**Undo** (SR21): undo entries for frames whose files Apply deleted are dropped, because there's nothing left to undo. All other undo history is kept (R10).

**Interruption** (R23):

- `VolumeMonitor` cancels the executor's `Task` when either volume is about to unmount or unmounts. Any I/O error does the same.
- Cancellation is checked between copy chunks and before every frame in steps 7 and 8.
- A `ProcessInfo` activity assertion stops the Mac from idle-sleeping during Apply. Closing the lid can't be prevented; the journal's intent records and the card syncs (SR25, SR27) keep that case resumable.
- **Resume** recovers and sweeps (step 1), then replans from the journal.

**Accepted trade-offs:**

- **SR22: single read.** The source is hashed from a single read of the card. A reader that silently returns corrupted bytes, without an I/O error, would yield a "verified" copy of those bad bytes. USB and the SD bus both carry CRCs, so this is very unlikely, and a re-read would cost about 10 minutes per trip. It could become a "double-read" preference later.
- **SR23: lost journal.** If the journal is lost, files already on the archive aren't recognised. A re-run copies them again under `-n` names, which costs duplicates but loses nothing, and they're never eligible for removal.
- **SR24: time-zone change.** If the Mac's time zone changes between the Apply rescan and a delete, the card's mtimes shift and the frames are skipped with the reason "time zone changed; run Apply again". This fails safe.
- **Flush honesty.** `F_FULLFSYNC` returning success means the driver has written the data and the directory entry (measured). A USB bridge that acknowledges a flush it hasn't performed could still lose a just-verified file if it's unplugged at once. The Eject button and the next run's final check (SR28) cover this.
- **Interrupted rename.** exFAT has no journal, so a rename cut off by power loss can leave the volume needing repair. Recovery never accepts a file at a reserved name without hashing all of it.
- **Path-based tag and Trash calls.** Between the identity check and the call there is a window of well under a millisecond in which the volume would have to be swapped for another one holding a file at the same path.

**Throughput estimate:** keepers are typically about 30% of a 180 GB card, so about 55 GB at about 90 MB/s, which is roughly 10–11 minutes for the copy. The Google Photos copies are SSD to SSD and add about 1 minute. On a re-run with rejects to delete, re-hashing earlier keepers for the gate reads the same 55 GB from the SSD, a few minutes.

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

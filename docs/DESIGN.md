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
  - Archive copies are **moved to the SSD's Trash**, so the removal can be recovered until the Trash is emptied. Card files are still deleted permanently.
  - A file is removed only if the ledger shows FujiCull wrote it **and** its size and modification date still match what was verified. A file that has been edited or replaced is left alone and reported.
  - If an archived frame is changed back to **Undecided**, its archive copy is left as it is, because "undecided" means "don't touch".
- **D7. The trip name and archive folder are fixed after the first Apply on a card.** Later runs reuse them, so a re-run can't scatter keepers across two folders.

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

- **Input** is a root URL: either a volume root or any folder (R1). If `<root>/DCIM` exists, scan only `DCIM/*` subfolders recursively. Otherwise scan the chosen folder recursively.
- **Enumeration** uses `FileManager.enumerator` with `[.skipsHiddenFiles]` and pre-fetched keys `fileSize`, `contentModificationDate` and `isRegularFile`. It also explicitly skips `._*`, `.Trashes`, `.Spotlight-V100` and `.fseventsd` (R5). Only `.JPG`/`.JPEG` and `.RAF` files are kept, compared case-insensitively.
- **Pairing** groups files by `(parent folder, uppercased base name)`. A group with one JPG and one RAF is a paired frame. A group with only one of the two is an orphan with `isUnpaired = true` (R4). If a group has duplicates that differ only in case (for example `a.jpg` and `A.JPG`), that is treated as a scan warning and both are surfaced as orphans. Unlikely on a camera card, but it's handled deterministically.
- **Order** is by folder name, then filename, using a numeric-aware comparison (D1, ADR-004).
- **Frame identity** is `FrameID = "<path relative to root>/<BASENAME>"`, for example `DCIM/102_FUJI/DSCF1234`. It stays stable across remounts and is the key for decisions and the ledger.
- **Scan snapshot.** For each file, the scanner records `size` and `mtime`. Apply rechecks these before deleting (§5.7).
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

- **Location:** `~/Library/Application Support/FujiCull/Sessions/<sessionID>.json`, with one file per card or folder.
- **Session key** (R20):
  - For a volume root: `volumeUUIDString`, or the volume identifier if there is no UUID. This needs checking on exFAT (spike S3).
  - For a folder: the canonical path.
  - Each session also stores a **file-list fingerprint**: the set of FrameIDs.
- **Restore rule:** if the key matches and at least 50% of the stored FrameIDs are still present, restore. Missing frames are dropped. They are expected after Apply, because rejects were deleted. New frames are added as Undecided. If fewer than 50% are present, the card was probably reformatted, so start a new session and keep the old file.
- **Contents:** the schema version, key, root path hint, decisions (only frames that aren't Undecided), cursor FrameID, filter flag, and the Apply ledger (§5.7). For 2,000 frames this is about 100–200 KB of JSON. That is more than the "a few KB" in R19, but still negligible.
- **Writes** are debounced by 300 ms after a change and are atomic (`Data.write(options: .atomic)`). They are flushed immediately on quit, on source close and on unmount. Ledger updates during Apply are written synchronously with `fsync` (§5.7).
- **The card is never written** during culling (R21). The `FileSystem` protocol used by Apply is the only code path with write or delete operations against the source.

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
- **Zoom across frames** (R12): when zoom is on, the prefetcher asks for T2 of +1 as well. Only one extra T2 is held, to stay within budget.
- **Background metadata pass:** after open, T0 is read for every frame in order. This fills the filmstrip, the EXIF and the capture dates. That's about 128 MB of small reads, probably 10–30 s, and it never blocks the UI. Apply doesn't need it, since folder names no longer include a date (Q10).
- **Memory budget:**

| Cache | Size |
|---|---|
| T0 (2,000 frames, stored compressed, ~10 KB each) | ~20 MB |
| Decoded T0 LRU (visible strip and grid) | ~30 MB |
| T1 (5 frames at 2560 px) | ~90 MB |
| T2 (current + next) | ~320 MB peak, only while zoomed |
| **Total** | **~140 MB normally, ~460 MB while zoomed** |

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

**Planner** (pure function). It takes the session, scan snapshot, metadata, ledger, archive root, trip name, and a listing of the destination folders. It returns an `ApplyPlan`:

- **Destination:** `<SSD root>/<Trip name>/`, plus `Google Photos/` inside it, matching your existing flat archive (Q10). After the first run, the destination is fixed in the ledger (D7). If the folder already exists and isn't in this card's ledger, for example your own `Japan 2024/`, pre-flight asks before adding to it; the never-overwrite collision rule still applies inside it. The trip name is checked against exFAT's forbidden characters (`" * / : < > ? \ |`, and no trailing space or dot).
- **Copy operations** are for every Keep frame that doesn't have a verified ledger entry. Each copies the RAF and JPG to the archive folder, and the JPG to `Google Photos/`. The Google Photos copy is made from the *verified archive copy*, not the card, so the card is read only once.
- **Collision naming:** if `DSCF1234.JPG` or `DSCF1234.RAF` already exists in either destination folder, the planner picks the smallest `n ≥ 2` for which `DSCF1234-n.JPG`, `DSCF1234-n.RAF` and `Google Photos/DSCF1234-n.JPG` are all free. The pair always keeps matching names. The chosen names go into the ledger before copying, so a resumed run reuses them.
- **Tag operations:** add the Finder tag "Favourite" to the archive RAF and JPG of a ♥ frame. The `Google Photos/` copy is never tagged (Q11). Remove the tag from files whose frame is no longer a favourite (R25).
- **Delete operations:** every Reject frame that is still present on the card.
- **Archive-removal operations** (D6): for every Reject frame that has `verified` ledger entries, remove its archive RAF, archive JPG and Google Photos JPG.
- **Pre-flight facts:**
  - Bytes needed: unverified keeper RAF + JPG, plus the Google Photos JPGs, plus a 1 GB margin.
  - Counts for keep, ♥, reject and undecided.
  - How many rejected frames will also be removed from the archive.
  - A read-only flag if the card is locked (R6).

**Executor** (async, cancellable, sequential: one file at a time, because the card is the bottleneck):

1. **Copy and verify** each file:
   1. Stream the source in 8 MB chunks while computing SHA-256 (CryptoKit) on the fly.
   2. Write to `.<name>.fujicull-partial` in the destination folder, then `F_FULLFSYNC`.
   3. Reopen the copy with `F_NOCACHE`, read it back, and hash it. The hashes must match (R22, step 3).
   4. Set the destination's modification date to the source's.
   5. Rename to the final name exclusively (`renamex_np(…, RENAME_EXCL)`), so an existing file is never overwritten.
   6. Append `verified(frameID, role, dstName, size, sha256)` to the ledger and `fsync` it.
   7. A mismatch, an I/O error or an EXCL failure stops the run. The partial file is deleted, and nothing is deleted from the card.
2. **Tag** with `NSURL.setResourceValue(_:forKey: .tagNamesKey)`, merging with any existing tags. This is recorded in the ledger.
3. **Gate.** Deletion is offered only if *every* Keep frame on the card has verified archive copies for both of its files and a verified Google Photos copy (R22). This includes frames verified in earlier runs. If the card is read-only, deletion is skipped and a notice is shown (R6).
4. **Confirm.** A modal shows the frame count, file count and bytes, and says the deletion can't be undone. If any archive copies will also be removed, it adds a second line, for example "…and move 12 previously archived frames (36 files) from the archive to the SSD's Trash." **Cancel** is the default button. If the card is read-only, the modal covers archive removal only.
5. **Remove archive copies** (D6). For each archive file of a rejected frame, check that its size and mtime still match the ledger's `verified` entry (otherwise skip it and report it). Then move it to the Trash with `FileManager.trashItem` and record it in the ledger. This happens *before* the card deletion, so the card copy still exists if anything fails here.
6. **Delete from the card.** For each reject file, recheck that its `size` and `mtime` still match the scan snapshot (otherwise skip it and report it), then `unlink` it. Card files are never moved to the Trash. Each deletion is recorded in the ledger.
7. **Summary:** copied, verified, tagged, removed from the archive, deleted, skipped and left on the card, with "Reveal in Finder" for the archive and Google Photos folders.

**Interruption** (R23):

- `VolumeMonitor` listens for `NSWorkspace.willUnmountNotification` and `didUnmountNotification` on both volumes, and cancels the executor's `Task`.
- Any I/O error has the same effect as a cancellation.
- Cancellation is checked between chunks, so a run stops within about one chunk.
- During Apply, a `ProcessInfo.beginActivity(.userInitiated + idleSystemSleepDisabled)` assertion stops the Mac from idle-sleeping in the middle of a copy.
- **Resume:** the next Apply replans from the ledger. Verified files are skipped. A planned file whose final name exists but has no `verified` entry, because the app crashed between the rename and the ledger write, is hashed. If the hash matches, the file is adopted. Otherwise it is treated as a collision.

**Throughput estimate:** keepers are typically about 30% of a 180 GB card, so about 55 GB at about 90 MB/s, which is roughly 10–11 minutes for the copy. The Google Photos copies are SSD to SSD, so they add about 1 minute. The progress bar shows bytes and an ETA.

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
| R22–R26 | §5.7 |
| NFR open < 2 s | §5.1 (no content reads in scan), §5.4 (T0 for visible cells first) |
| NFR next < 100 ms, holding → | §5.4 prefetch, key-repeat rule |
| NFR zoom < 300 ms | §5.4, risk noted |
| NFR disk / memory | §5.4 budget, ADR-002 |
| NFR safety | §5.7, ADR-003 |
| NFR platform / size | §6, ADR-001 |

## 12. Next step

The task breakdown is in [tasks/plan.md](../tasks/plan.md) and [tasks/todo.md](../tasks/todo.md).

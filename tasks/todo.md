# FujiCull v1 — Task List

Each task: one focused session, ≤ ~5 files, `make test` green before it counts as done.
Section references (§) are to [docs/DESIGN.md](../docs/DESIGN.md).

---

## Phase 0 — Scaffold

### - [ ] T1: Package, Makefile and an empty app that launches
**Description:** Create `Package.swift` with targets `FujiCullCore`, `FujiCullImaging` and `FujiCullApp` (Swift 6 language mode, macOS 14) and two test targets. Add a Makefile with `build`, `test` (using the CLT Testing.framework flags from ADR-001), `app`, `run`, `format`, `lint` and `clean`. Add `Resources/Info.plist`. The app opens one dark, empty window.
**Acceptance:**
- [ ] `make test` runs at least one Swift Testing test per test target, and it passes.
- [ ] `make app` produces an ad-hoc-signed `build/FujiCull.app` that launches and shows a dark window.
- [ ] `make lint` passes.
**Verify:** `make test && make lint && make run`
**Depends on:** —
**Files:** `Package.swift`, `Makefile`, `Resources/Info.plist`, `Sources/FujiCullApp/FujiCullApp.swift`, plus a placeholder source file and a test in each target
**Scope:** M

---

## Phase 1 — Browse slice

### - [ ] T2: SourceScanner — find, pair, order (R1–R5, D1)
**Description:** Implement `Frame`, `FrameID`, `SourceFile` and `SourceScanner` as in §5.1. It scans `DCIM/*` (or the chosen folder), pairs files case-insensitively by folder and base name, flags orphans, skips junk, and orders by folder then filename (numeric-aware). It also records a size and mtime snapshot for each file.
**Acceptance:**
- [ ] Tests cover: pairs, JPG-only and RAF-only orphans, mixed case, `._*` / `.Trashes` / `.Spotlight-V100` / `.fseventsd` / non-image files ignored, a counter wrap across `100_FUJI` → `101_FUJI`, a non-DCIM folder, and duplicates that differ only in case.
- [ ] A 2,000-pair synthetic tree scans in under 200 ms on this Mac (measured in a test).
**Verify:** `make test`
**Depends on:** T1
**Files:** `Sources/FujiCullCore/Scan/{Frame,SourceScanner}.swift`, `Tests/FujiCullCoreTests/SourceScannerTests.swift`, a test helper for building temp trees
**Scope:** M

### - [ ] T3: Spikes S3 + S4 — card identity and speed _(needs your SD card and reader)_
**Description:** A throwaway `swift` script, kept in `scripts/spikes/`. It checks whether the card reports a stable `volumeUUIDString` across remounts, whether the lock switch gives `volumeIsReadOnly`, the sequential read speed, and the T1 (2560 px) and T2 (full) decode times for X-T50 JPGs.
**Acceptance:**
- [ ] Results are written up in `docs/spikes/S3-S4.md` with numbers.
- [ ] DESIGN §5.3 and §5.4 are updated if anything differs from the assumptions.
**Verify:** Review the write-up together.
**Depends on:** T1
**Files:** `scripts/spikes/card_probe.swift`, `docs/spikes/S3-S4.md`
**Scope:** S

### - [ ] T4: JPEG segment parser and T0 thumbnail + EXIF basics
**Description:** In Core, a pure `JPEGSegments` parser that finds APP1 (EXIF) and the IFD1 thumbnail within the first 64 KB. In Imaging, a `ThumbnailLoader` that turns those bytes into a `CGImage` plus `ExifSummary` (shutter, aperture, ISO, focal length, DateTimeOriginal). Fixtures are synthetic JPEGs written with `CGImageDestination` and an embedded thumbnail and EXIF.
**Acceptance:**
- [ ] The parser handles a missing thumbnail, an APP1 that isn't in the first 64 KB (it returns a "need more bytes" result), and truncated or corrupt input without crashing.
- [ ] `ExifSummary` round-trips the values written into the synthetic fixtures.
**Verify:** `make test`
**Depends on:** T1
**Files:** `Sources/FujiCullCore/Metadata/JPEGSegments.swift`, `Sources/FujiCullImaging/{ThumbnailLoader,ExifReader}.swift`, `Tests/FujiCullCoreTests/JPEGSegmentsTests.swift`, `Tests/FujiCullImagingTests/ThumbnailLoaderTests.swift`
**Scope:** M

### - [ ] T5: CardReader actor, T1 display decode and memory cache (ADR-002)
**Description:** A `CardReader` actor that serves read requests one at a time from a priority queue (current > +1…+3 > −1 > thumbnails > background) and cancels stale requests when the cursor moves. A `PreviewPipeline` that decodes T1 downsampled to a given pixel size. A `PreviewCache` (an LRU sized in bytes).
**Acceptance:**
- [ ] Tests with a fake byte source show priority ordering, that cancelled requests never complete, and that the cache evicts by byte budget.
- [ ] There are no Swift 6 concurrency warnings.
**Verify:** `make test`
**Depends on:** T4
**Files:** `Sources/FujiCullImaging/{CardReader,PreviewPipeline,PreviewCache}.swift`, `Tests/FujiCullImagingTests/CardReaderTests.swift`
**Scope:** M

### - [ ] T6: Open a source and browse with ← →
**Description:** File ▸ Open (any folder) and auto-detection of a mounted volume with `DCIM/*_FUJI`. A `ViewerView` (layer-backed `NSView`, `keyDown`) shows T1, with T0 as a placeholder, and prefetches +3/−1. ← and → move between frames. The overlay is just the filename and `n / total` for now.
**Acceptance:**
- [ ] Opening a folder copy of a real card shows the first image in under 2 s.
- [ ] ← and → move between frames and the prefetch makes them feel instant at normal pace.
- [ ] Closing the source frees the preview memory (checked in Activity Monitor).
**Verify:** `make run`; manual check on a folder of JPGs
**Depends on:** T2, T5
**Files:** `Sources/FujiCullApp/{FujiCullApp,CullModel}.swift`, `Sources/FujiCullApp/Viewer/{ViewerView,ViewerController}.swift`
**Scope:** M

### Checkpoint A — browse slice
- [ ] `make test` and `make lint` are green, and `make app` builds.
- [ ] You open a folder or card and browse it with ← → (run on your Mac).
- [ ] T3 findings reviewed; DESIGN updated if needed.

---

## Phase 2 — Culling

### - [ ] T7: CullSession reducer (R7–R11, D3, D4)
**Description:** A value-type `CullSession` with the `Command` enum: keep, reject, toggleFavourite, reset, next, previous, jump(±10), undo, toggleUndecidedFilter. It maintains the favourite ⇔ Keep invariant, auto-advance (with a preference), a decisions-only undo stack that moves the cursor back, a live Undecided filter, and incremental counts.
**Acceptance:**
- [ ] Every keymap row in REQUIREMENTS §4.3 that changes session state has a test.
- [ ] The favourite invariant holds across every command sequence tested, including a property-style loop over random sequences.
- [ ] Undo restores both the decision and the favourite flag, and moves the cursor back.
**Verify:** `make test`
**Depends on:** T2
**Files:** `Sources/FujiCullCore/Session/{CullSession,Decision,Command}.swift`, `Tests/FujiCullCoreTests/CullSessionTests.swift`
**Scope:** M

### - [ ] T8: KeyMap, AppCommand, menus and overlay counts (R11, R13, R16) + spike S5
**Description:** `KeyMap` maps `(keyCode, modifiers)` to `AppCommand`. All keys and menu items go through `CullModel.perform`. Menus list every action with its shortcut. The overlay shows the filename, state, progress and the kept/rejected/undecided counts. Spike S5 decides where unmodified keys are handled so each fires exactly once.
**Acceptance:**
- [ ] Every key in §4.3 works, including holding a key down (repeat), and none fires twice.
- [ ] Every action is reachable from the menu bar.
- [ ] The S5 outcome is noted in ADR-006.
**Verify:** `make test` (KeyMap table test) + manual run through the keymap
**Depends on:** T6, T7
**Files:** `Sources/FujiCullApp/{KeyMap,AppCommand,AppMenus}.swift`, `Sources/FujiCullApp/Viewer/OverlayView.swift`, `CullModel.swift`
**Scope:** M

### - [ ] T9: SessionStore — auto-save, restore, reconcile (R19–R21, ADR-005)
**Description:** A `Codable` `SessionFile` (schemaVersion, key, decisions that aren't Undecided, cursor, filter, ledger placeholder). `SessionKey` derivation: volume UUID, then volume identifier, then canonical path. The restore rule: at least 50% FrameID overlap, missing frames dropped, new frames added as Undecided. Writes are debounced to 300 ms and atomic, and flushed on quit and unmount.
**Acceptance:**
- [ ] Tests cover: round trip, restore after rejects are deleted, new frames appearing, below-50% overlap giving a new session with the old file kept, and a corrupt file giving a new session with the corrupt file renamed `.bad`.
- [ ] No code path writes inside the source root (asserted in tests).
**Verify:** `make test`
**Depends on:** T7
**Files:** `Sources/FujiCullCore/Persist/{SessionStore,SessionKey,SessionFile}.swift`, `Tests/FujiCullCoreTests/SessionStoreTests.swift`
**Scope:** M

### - [ ] T10: Filmstrip with state badges, and the background metadata pass (R14)
**Description:** A horizontal `NSCollectionView` filmstrip, virtualised, showing T0 thumbnails and badges (green, red, ♥, grey) that stay in sync with the cursor. The background T0 pass fills thumbnails, EXIF and capture dates for every frame without blocking the UI. The cull UI is wired to `SessionStore`.
**Acceptance:**
- [ ] A 2,000-frame folder scrolls smoothly, and badges update as soon as a key is pressed.
- [ ] Quit mid-cull, relaunch and reopen: the marks and position are restored.
**Verify:** `make run`; manual check
**Depends on:** T8, T9
**Files:** `Sources/FujiCullApp/Viewer/{FilmstripView,ThumbnailCell}.swift`, `Sources/FujiCullImaging/MetadataPass.swift`, `CullModel.swift`
**Scope:** M

### Checkpoint B — culling
- [ ] `make test` is green.
- [ ] You cull a whole folder copy with one hand, quit, relaunch, and resume.
- [ ] Review with you before Phase 3.

---

## Phase 3 — Viewing polish

### - [ ] T11: Grid view toggle (G) (R15)
**Description:** A wrapping `NSCollectionView` grid with the same cells and badges. G toggles between the grid and the single view. Every key acts on the selected cell, and the selection is the cursor.
**Acceptance:**
- [ ] G toggles views without losing the cursor.
- [ ] ↑, ↓, /, . and ⌫ work in the grid, and the arrow keys move the selection.
**Verify:** Manual
**Depends on:** T10
**Files:** `Sources/FujiCullApp/Viewer/GridView.swift`, `ViewerController.swift`, `KeyMap.swift`
**Scope:** S

### - [ ] T12: 100% zoom (Return) with mouse-follow and T2 prefetch (R12, D5)
**Description:** Return toggles between fit and 100% (1 image pixel per device pixel). The pan position follows the mouse. Zoom stays on when moving between frames, and +1's T2 is prefetched while zoomed. The T2 cache (two frames at most) is cleared when zoom is turned off.
**Acceptance:**
- [ ] Zoom is under 300 ms when the frame was prefetched; the cold-zoom time is measured and noted.
- [ ] Memory stays under ~500 MB while zoomed.
**Verify:** Manual + signpost timings
**Depends on:** T10
**Files:** `ViewerView.swift`, `Sources/FujiCullImaging/PreviewPipeline.swift`, `PreviewCache.swift`
**Scope:** M

### - [ ] T13: EXIF line (I) and film simulation, + spikes S1/S2 _(needs sample files)_
**Description:** Check the X-T50 file layout with the samples: APP1 within 64 KB? IFD1 thumbnail size? MPF preview? Then a pure `FujiMakerNote` parser (tags 0x1401 and 0x1003) mapping to film simulation names, showing "—" for unknown values. I toggles the EXIF line. Trimmed real fixtures are added (≤ 2 MB total).
**Acceptance:**
- [ ] Every sample film simulation decodes to the right name.
- [ ] Unknown values show "—".
- [ ] S1/S2 results are recorded in `docs/spikes/S1-S2.md`.
**Verify:** `make test` + manual
**Depends on:** T4, T10
**Files:** `Sources/FujiCullCore/Metadata/FujiMakerNote.swift`, `Tests/FujiCullCoreTests/FujiMakerNoteTests.swift`, `Tests/Fixtures/*`, `OverlayView.swift`, `docs/spikes/S1-S2.md`
**Scope:** M

### - [ ] T14: Unpaired frames and RAF-only preview (R4)
**Description:** A pure `RAFHeader` parser (magic, embedded JPEG offset and length at bytes 84 and 88). RAF-only frames show the embedded JPEG through the T0/T1 path. All orphans get an "unpaired" badge in the overlay, filmstrip and grid.
**Acceptance:**
- [ ] Parser tests on a synthetic RAF header pass, plus a real trimmed RAF once samples arrive.
- [ ] RAF-only frames display, and the badge shows.
**Verify:** `make test` + manual
**Depends on:** T10 (and samples for the real fixture)
**Files:** `Sources/FujiCullCore/Metadata/RAFHeader.swift`, `Tests/FujiCullCoreTests/RAFHeaderTests.swift`, `PreviewPipeline.swift`, `ThumbnailCell.swift`
**Scope:** S

### - [ ] T15: Key-repeat throttling and performance instrumentation
**Description:** While → is held, show only T0 and request T1 after the key is released or the cursor has rested for 120 ms. Add `os_signpost` intervals for open, next-frame and zoom, plus a debug timing overlay behind a hidden preference.
**Acceptance:**
- [ ] Holding → through 500 frames never stalls.
- [ ] The NFR timings are measured on a real card and recorded in `docs/spikes/perf.md`.
**Verify:** Manual on a real card
**Depends on:** T10, T12
**Files:** `ViewerController.swift`, `CardReader.swift`, `Sources/FujiCullApp/Debug/TimingOverlay.swift`, `docs/spikes/perf.md`
**Scope:** S

### Checkpoint C — viewing
- [ ] All the viewer NFRs are measured and recorded; any misses are discussed with you.
- [ ] `make test` is green.

---

## Phase 4 — Apply core (test-first, no UI)

### - [ ] T16: FileSystem protocol and the safe copy primitive
**Description:** A `FileSystem` protocol with `LocalFileSystem` and a `FaultyFileSystem` test double. `safeCopy(src, dstDir, name)`:
- copy in 8 MB chunks while hashing with SHA-256
- write to `.<name>.fujicull-partial`, then `F_FULLFSYNC`
- read back with `F_NOCACHE`, compare hashes
- set the modification time
- rename with `RENAME_EXCL`, falling back to check-then-rename where it's unsupported (exFAT)
- support cancellation between chunks
**Acceptance:**
- [ ] Each injected fault (a write error at chunk N, a corrupted read-back, cancellation, the destination already existing) leaves no final file and no leftover `.partial` file, and returns a typed error.
- [ ] A successful copy has a matching hash and mtime.
**Verify:** `make test`
**Depends on:** T1
**Files:** `Sources/FujiCullCore/Apply/{FileSystem,LocalFileSystem,SafeCopy}.swift`, `Tests/FujiCullCoreTests/{FaultyFileSystem,SafeCopyTests}.swift`
**Scope:** M

### - [ ] T17: Ledger model, stored in the session
**Description:** `Ledger` holds the destination folder (fixed after the first run, D7), the per-frame name mapping, and entries for verified, tagged, archive-removed and deleted files (with size, mtime and sha256). It is stored in `SessionFile`. Ledger updates are written synchronously with `fsync`.
**Acceptance:**
- [ ] Round-trip tests pass.
- [ ] Ledger writes survive a simulated crash: the write is atomic, so after a kill the file holds either the old or the new ledger.
**Verify:** `make test`
**Depends on:** T9
**Files:** `Sources/FujiCullCore/Apply/Ledger.swift`, `SessionFile.swift`, `SessionStore.swift`, `Tests/FujiCullCoreTests/LedgerTests.swift`
**Scope:** S

### - [ ] T18: ApplyPlanner (R22, R24–R26, D6, D7)
**Description:** A pure `plan(ApplyInput) throws(ApplyError) -> ApplyPlan` implementing §5.7:
- the destination path from the earliest capture date
- collision suffixes chosen per pair
- copy operations, with Google Photos copies sourced from the archive
- tag add and remove
- card deletes
- archive removals
- the space calculation (+1 GB margin)
- pre-flight facts (counts, read-only flag, the R22 gate state)
**Acceptance:**
- [ ] Tests cover: first run; a re-run after deciding the Undecided frames; Keep→Reject after archiving (archive removal planned); Keep→Undecided after archiving (nothing planned); favourite added and removed; collisions (including one only in `Google Photos/`); insufficient space; a read-only card; and that Undecided frames are never touched.
**Verify:** `make test`
**Depends on:** T2, T7, T17
**Files:** `Sources/FujiCullCore/Apply/{ApplyPlanner,ApplyPlan,ApplyError}.swift`, `Tests/FujiCullCoreTests/ApplyPlannerTests.swift`
**Scope:** M

### - [ ] T19: ApplyExecutor, part 1 — copy, verify, tag, resume
**Description:** Execute a plan's copy operations one after another with `safeCopy`. The Google Photos copy is made from the verified archive file. Each verified file is recorded in the ledger. Finder tags are applied through `NSURL` resource values, merged with existing tags. The executor reports progress (bytes and ETA). It is cancellable. On resume, a final-named file without a ledger entry is adopted only if its hash matches.
**Acceptance:**
- [ ] Fault injection at every step gives a re-run that converges to the same final state, without duplicates or `-2` names created by resuming.
- [ ] Tags are verified on the archive files after the run.
**Verify:** `make test`
**Depends on:** T16, T18
**Files:** `Sources/FujiCullCore/Apply/{ApplyExecutor,FinderTags}.swift`, `Tests/FujiCullCoreTests/ApplyExecutorCopyTests.swift`
**Scope:** M

### - [ ] T20: ApplyExecutor, part 2 — gate, archive removal (Trash), card deletion
**Description:**
- Enforce the R22 gate: every Keep frame on the card must be verified, and the card must not be read-only.
- After a confirmation callback, move archive files of frames rejected after archiving to the Trash. Each file must match its ledger size and mtime.
- Then `unlink` card rejects after rechecking each file's size and mtime against the scan snapshot.
- Record everything in the ledger, and produce the summary model.
**Acceptance:**
- [ ] In every fault test from T16/T19, **zero files are deleted from the card or the archive**.
- [ ] A card file changed since the scan is skipped and reported.
- [ ] An archive file changed since verification is skipped and reported.
- [ ] A read-only card skips card deletion but still allows the confirmed archive removal.
- [ ] Declining the confirmation deletes nothing.
**Verify:** `make test`
**Depends on:** T19
**Files:** `ApplyExecutor.swift`, `Sources/FujiCullCore/Apply/ApplySummary.swift`, `Tests/FujiCullCoreTests/ApplyExecutorDeleteTests.swift`
**Scope:** M

### Checkpoint D — Apply core proven
- [ ] `make test` is green, with every Apply branch exercised (check with `swift test --enable-code-coverage`).
- [ ] You review the fault-injection test list before any UI connects to it.

---

## Phase 5 — Apply UI and rehearsal

### - [ ] T21: Pre-flight sheet
**Description:** Apply opens a sheet with:
- the trip name (prefilled and locked after the first run, D7)
- the archive root (chosen once and remembered as a security-scoped bookmark or a path)
- a wait for the metadata pass to finish
- the space check, with a clear abort message
- the summary (keep, ♥, reject, undecided, and archive removals)
- a warning about Undecided frames
**Acceptance:**
- [ ] All the pre-flight cases from the T18 tests are visible in the UI.
- [ ] The run can't start when there isn't enough space.
**Verify:** Manual, using a small folder source and a temp archive root
**Depends on:** T18, T10
**Files:** `Sources/FujiCullApp/Apply/{ApplySheet,PreflightView}.swift`, `CullModel.swift`, `Sources/FujiCullApp/Settings.swift`
**Scope:** M

### - [ ] T22: Progress, confirmation, summary, VolumeMonitor and sleep assertion
**Description:**
- A progress view (bytes and ETA).
- A confirmation modal with the exact counts, the archive-removal line, and Cancel as the default button.
- A summary with "Reveal in Finder" for the archive and Google Photos folders.
- `VolumeMonitor` cancels the run when either volume unmounts.
- A `ProcessInfo` activity assertion is held during the run.
**Acceptance:**
- [ ] Pulling the SSD mid-copy (tested on a USB stick) stops the run, deletes nothing, and a re-run resumes.
- [ ] Return on the confirmation modal cancels.
- [ ] The Mac doesn't sleep during a long run.
**Verify:** Manual
**Depends on:** T20, T21
**Files:** `Sources/FujiCullApp/Apply/{ProgressView,ConfirmDeleteView,SummaryView}.swift`, `Sources/FujiCullApp/VolumeMonitor.swift`
**Scope:** M

### - [ ] T23: Spike S6 — archive SSD format, Finder tags and exclusive rename _(needs your SSD)_
**Description:** Check the SSD's format. Test tags, `RENAME_EXCL` and `trashItem` on it. If it's exFAT, recommend whether to reformat it as APFS.
**Acceptance:**
- [ ] Results are written up in `docs/spikes/S6.md`; T16's fallback is confirmed or adjusted.
**Verify:** Review the write-up
**Depends on:** T16 (can run any time after)
**Files:** `scripts/spikes/ssd_probe.swift`, `docs/spikes/S6.md`
**Scope:** S

### - [ ] T24: End-to-end rehearsal and the manual test checklist
**Description:** Write `docs/TESTING.md`, a manual checklist covering the keymap, resume, both views, and every Apply path including the interruption tests. Then rehearse:
1. Copy a real card into a folder.
2. Cull it, then Apply to the real SSD.
3. Change your mind about some frames, then Apply again.
4. Check the archive and Google Photos contents, tags and the Trash.
**Acceptance:**
- [ ] Every checklist item passes.
- [ ] Any discrepancies are fixed or filed as tasks.
**Verify:** Run the checklist together
**Depends on:** T22, T23
**Files:** `docs/TESTING.md`
**Scope:** S

### Checkpoint E — v1 ready
- [ ] Every requirement (R1–R26) and NFR is traced to a passing test or checklist item.
- [ ] The first real-card Apply is done with a full card backup available, just this once.

# ADR-003: Apply as a pure planner plus a journaled copy → verify → tag → confirm → delete executor

## Status
Accepted (2026-10-09)

## Date
2026-10-09

## Context
Apply is the only destructive part of FujiCull. It permanently deletes files from the only copy of a trip's photos. The requirements say:
- Rejects are deleted only after every keeper copy has been verified (R22).
- If a volume disconnects, the run stops and deletes nothing, and a later run resumes (R23).
- Existing files are never overwritten; a suffix is added instead (§4.6).
- Re-runs process only what has changed (R25).

## Decision
- **Planner** (pure, in `FujiCullCore`). It takes the session, scan snapshot, ledger and destination listing, and returns the copy, tag and delete operations plus pre-flight facts. Collision suffixes are chosen per *pair*, so the RAF, the JPG and the Google Photos JPG share one name.
- **Executor:**
  - Copies sequentially in 8 MB chunks, computing SHA-256 while reading the source.
  - Writes to a `.fujicull-partial` temp file, then runs `F_FULLFSYNC`.
  - Reads the copy back with `F_NOCACHE` and compares hashes.
  - Renames exclusively into place (`renamex_np RENAME_EXCL`).
  - Then appends a `verified` entry to the ledger and runs `fsync` on it.
  - Copies to Google Photos/ from the verified archive copy.
- **Ledger:** stored in the card's session file. It records the chosen destination, the name mapping, and verified, tagged and deleted entries. A re-run replans from it. A final-named file without a ledger entry is adopted only if its hash matches.
- **Archive removal** (DESIGN D6, R26): when a frame that was already archived is later rejected, its archive and Google Photos copies are moved to the SSD's Trash. This is recoverable, happens in the same confirmed step, *before* the card deletion, and only for files whose size and modification date still match their `verified` ledger entry.
- **Deletion gate:** every Keep frame on the card must have verified copies, the card must not be read-only, and the user must confirm in a modal whose default button is Cancel. Before each `unlink`, the file's size and modification date are checked against the scan snapshot. Card files are never moved to the Trash.
- **Cancellation:** unmounting either volume or any I/O error cancels the run. A sleep-prevention assertion is held during Apply.

## Alternatives Considered

### `FileManager.copyItem`, then compare
- Cons: the read-back may be served from the unified buffer cache instead of the disk, so it proves less. It gives no progress per chunk, and there's no exclusive placement.
- Rejected.

### Delete each reject as soon as its keepers are done
- Cons: this breaks R22's "every keeper verified" rule and makes a partial failure much harder to reason about.
- Rejected.

### Move rejects to the Trash
- Cons: on an SD card, the Trash is `.Trashes` on the card itself, so no space is freed. This was explicitly rejected in the requirements.

## Consequences
- The executor's behaviour can be shown through fault injection in tests: a `FileSystem` protocol plus a `FaultyFileSystem` fake.
- Hashing doesn't add any card reads. It adds one SSD read per file, so the copy takes ~10–11 min for ~55 GB of keepers.
- FujiCull removes from the archive only the files it wrote and verified itself. Those files go to the Trash, never straight to `unlink`. Anything else in the archive folders is never touched.

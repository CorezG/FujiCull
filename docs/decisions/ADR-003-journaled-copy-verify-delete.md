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
  - Copies one file at a time in 8 MB chunks, hashing (SHA-256) while reading the source.
  - Writes to an `O_EXCL` partial file with `F_NOCACHE`, then runs `F_FULLFSYNC`.
  - Reads the copy back uncached and compares hashes.
  - Claims the final name with an `O_EXCL` placeholder and renames the partial over it. The rename only ever replaces FujiCull's own placeholder, which is safe on exFAT where `RENAME_EXCL` is unsupported.
  - Runs `F_FULLFSYNC` on the directory, then records `verified`.
  - All operations go through one directory descriptor whose volume UUID has been checked.
  - Copies to Google Photos/ from the archive JPG verified in the same run.
- **Ledger:** one append-only JSON-lines journal per card (`Ledger/<key>.jsonl`), with `F_FULLFSYNC` after every record and one record per file per operation (reserve, verified, tagged, trashed, deleted, released). The latest record for a file is authoritative. A torn tail is truncated, and any other corruption stops Apply and asks.
- **Archive removal** (DESIGN D6, R26): only files with a `reserve` → `verified` chain in this card's ledger are eligible. Each file is checked by size and SHA-256 re-hash before it's moved to the SSD's Trash. This happens in the same confirmed step, before the card deletion.
- **Deletion gate:** every Keep frame on the card must have verified archive copies that are still present (Google Photos copies excluded), every video must be verified, the card must not be read-only, and the user must confirm in a modal whose default button is Cancel. Before each `unlink`, the file's size and modification date are checked against the scan snapshot. Card files are never moved to the Trash.
- **Cancellation:** unmounting either volume or any I/O error cancels the run. A sleep-prevention assertion is held during Apply.

- **Hardening from two doubt-review rounds (2026-10-09):** decisions frozen during Apply; the source card re-identified before every read and delete; the archive resolved by volume UUID through one checked directory descriptor; locks; per-file journal records; all-or-nothing checks per frame; a gate that re-checks archive files on disk and never re-copies silently; `Google Photos/` treated as disposable. See DESIGN §5.7 SR6–SR24 and [the review](../reviews/2026-10-09-apply-doubt-review.md).

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

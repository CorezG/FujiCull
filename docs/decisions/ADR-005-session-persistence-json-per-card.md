# ADR-005: Session persistence as one JSON file per card, keyed by volume ID with a FrameID overlap check

## Status
Accepted (2026-10-09)

## Date
2026-10-09

## Context
Marks must auto-save after every change, survive quitting and ejecting, and come back when the same card is reinserted (R19, R20). Nothing may be written to the card before Apply (R21). The Apply ledger also needs durable storage that is tied to the card. The NFR says "no database server, no catalogue."

## Decision
- Store one session per card at `~/Library/Application Support/FujiCull/Sessions/<key>.json` (a `Codable` file with a `schemaVersion`), with its Apply journal beside it at `Ledger/<key>.jsonl`. An exclusive lock is held while the card is open.
- Key any source on a removable volume, whether the volume root or a folder inside it, by `volumeUUIDString`, falling back to the volume identifier. Key a folder source by its canonical path.
- Each decision is tied to a frame identity: a FrameID relative to the volume root, plus the exact sizes of the files still present, plus the capture time when both sides have one. If only part of a session matches the card, FujiCull shows how much matched and asks Resume or Start fresh. Start fresh moves the old session and ledger to `Archive/`, and their archive files are never removed later.
- Store only decisions that aren't Undecided, plus the cursor, the filter and the Apply ledger.
- Debounce writes to 300 ms. All writes go through one actor and are atomic (temp file, `F_FULLFSYNC`, rename). The Apply journal is a separate file (ADR-003).

## Alternatives Considered

### SQLite or Core Data
- Pros: queries and incremental writes.
- Cons: overkill for ~200 KB of state. Core Data also adds model-versioning overhead.
- Rejected.

### A sidecar file on the card
- Rejected: it violates R21, fails on write-locked cards (R6), and is lost when the card is formatted.

### `UserDefaults`
- Rejected: it isn't meant for large or growing documents or for durable ledgers.

## Consequences
- Whether exFAT SD cards report a stable UUID has to be checked (spike S3). The overlap check also covers the fallback case.
- A ledger is lost only if Application Support is wiped. Even then, re-running Apply is safe, because existing destination files are adopted by hash (ADR-003).

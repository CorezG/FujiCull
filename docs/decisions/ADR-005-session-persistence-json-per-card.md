# ADR-005: Session persistence as one JSON file per card, keyed by volume ID with a FrameID overlap check

## Status
Accepted (2026-10-09)

## Date
2026-10-09

## Context
Marks must auto-save after every change, survive quitting and ejecting, and come back when the same card is reinserted (R19, R20). Nothing may be written to the card before Apply (R21). The Apply ledger also needs durable storage that is tied to the card. The NFR says "no database server, no catalogue."

## Decision
- Store sessions at `~/Library/Application Support/FujiCull/Sessions/<id>.json`, one `Codable` file per source, with a `schemaVersion`.
- Key a volume source by `volumeUUIDString`, falling back to the volume identifier. Key a folder source by its canonical path.
- Restore a session only if at least 50% of its stored FrameIDs are still present. Otherwise the card has probably been reformatted, so start a new session and keep the old one.
- Store only decisions that aren't Undecided, plus the cursor, the filter and the Apply ledger.
- Debounce writes to 300 ms and write atomically. During Apply, write the ledger synchronously and `fsync` it.

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

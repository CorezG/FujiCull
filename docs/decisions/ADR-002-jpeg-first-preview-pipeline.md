# ADR-002: JPEG-first, three-tier preview pipeline with memory-only caches

## Status
Accepted (2026-10-09)

## Date
2026-10-09

## Context
Culling runs directly from an SD card read at ~90 MB/s. A JPG is 15–20 MB, so reading one takes about 200 ms. Decoding is much faster than that on an M2. The targets are:
- under 2 s to first image
- under 100 ms to the next frame
- holding → never blocks

The Mac usually has ≤ 10 GB free. The NFR allows a preview cache of up to 500 MB on disk. The JPG, with its film simulation, is the image being judged.

## Decision
- **T0:** read only the first 64 KB of each JPG and take the EXIF IFD1 thumbnail, the EXIF data and the MakerNote from it. This feeds the filmstrip, grid, EXIF line and capture dates. It is filled for visible cells first, then in a background pass.
- **T1:** read the whole JPG and decode it downsampled to the window's pixel size for the single view. Prefetch 3 frames ahead and 1 behind.
- **T2:** do a full decode only for 100% zoom. Hold at most 2 frames (current and next).
- All card reads go through **one priority-ordered, cancellable `CardReader` actor**. Parallel random reads on an SD card are slower than serial ones.
- When the → key is held, show T0 and request T1 only after the key is released or the cursor has rested for 120 ms.
- **All caches are in memory.** There is no disk cache. Peak is ~140 MB, or ~460 MB while zoomed.
- RAF-only orphans use the RAF's embedded JPEG, found through the RAF header offset.

## Alternatives Considered

### Disk thumbnail cache (up to 500 MB)
- Pros: faster reopening of a resumed session.
- Cons: uses scarce disk space and needs eviction and purge logic. T0 from the card is already only ~1–5 ms per frame.
- Rejected. This can be revisited if reopening is measured to be slow.

### Decode RAF previews instead of JPGs
- Cons: the RAF embedded preview may not reflect the film-simulation look as faithfully, and RAFs are 80 MB, so locating the preview means extra seeks.
- Rejected, except for orphans.

### Import everything first
- Rejected: impossible with ≤ 10 GB free.

## Consequences
- Display speed depends on the card reader. Prefetch covers normal culling pace, and a cold 100% zoom may take ~350 ms (spike S4).
- If the X-T50 embeds an MPF preview (spike S1), T1 can switch to reading just that range, an optimisation of about 10× in I/O, without changing the architecture.
- Ejecting the card or closing the source frees all preview memory immediately.

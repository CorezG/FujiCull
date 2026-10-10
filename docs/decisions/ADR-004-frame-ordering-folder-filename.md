# ADR-004: Order frames by DCIM folder, then filename (amends R3)

## Status
Accepted (2026-10-09). R3 amended in REQUIREMENTS.md.

## Date
2026-10-09

## Context
R3 says frames are "ordered by capture time (EXIF), then filename." To get EXIF times, every JPG on the card has to be read: ~2,000 header reads, roughly 10–30 s from an SD card. Either opening the card waits for that, which breaks the < 2 s target, or the list re-sorts under the user mid-cull. Doing neither is the goal.

The X-T50 numbers files sequentially (`DSCF0001`–`DSCF9999`). When the counter wraps, it starts a new folder (`100_FUJI` → `101_FUJI`). There is one camera and one card per trip.

## Decision
Order by DCIM folder name, then by filename, with a numeric-aware comparison. EXIF capture time is still read in the background, and is used for the EXIF line. (It was also used for the archive folder date, A4, until Q10 dropped dates from folder names.)

## Alternatives Considered

### EXIF time, after a scan that blocks opening
- Rejected: it breaks the "open < 2 s" target.

### EXIF time, re-sorting when the background pass finishes
- Rejected: the cursor and filmstrip would jump while the user is culling.

## Consequences
- The order is instant and stable, and matches shooting order for a single camera. It also matches shooting order if the camera's clock is changed between time zones, where EXIF time can even go backwards.
- Edge case: files numbered out of order. For example, the user resets the counter in the camera menu partway through a trip without a new folder being created. This is accepted as rare.
- If accepted, R3 changes to "ordered by DCIM folder, then filename (shooting order)."

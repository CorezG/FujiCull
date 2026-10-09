# FujiCull — Product Requirements (v1)

_Status: agreed in requirements interview, 2026-10-09. Owner: you. Next step: sign-off, then technical design._

## 1. Problem & goal

After a trip I come back with 1,500–2,000 RAW+JPEG frames from my Fujifilm X-T50
(~150–200 GB). My MacBook Air rarely has more than 10 GB free, so I can't import a
card before culling, and importing over the camera's USB is slow.

**FujiCull lets me cull straight from the SD card with one hand on the arrow keys,
then offloads only the keepers (RAF + JPG) to my archive SSD, prepares a folder of
keeper JPGs for Google Photos, and deletes the rejects from the card.**

The JPG (with my film simulation) is what I judge; the RAF always follows its JPG.

## 2. User & context

| | |
|---|---|
| User | Single user (me). Personal tool, not distributed. |
| Camera | Fujifilm X-T50, single SD slot, RAW (uncompressed) + JPEG. One card per trip. |
| Mac | 13" MacBook Air, M2, upgraded RAM, typically ≤ 10 GB free disk. |
| Source | SD card in a USB card reader (UHS-I, ~90 MB/s read). |
| Destination | External SSD (archive + Google Photos staging). |
| Downstream | Upload keeper JPGs to Google Photos in the browser. Occasional RAW edit in Fuji's app. No Lightroom/Capture One. |

## 3. Core workflow

1. Insert card → open it in FujiCull (auto-detect `DCIM/*_FUJI` or pick any folder).
2. Cull with the keyboard. Marks are saved continuously; I can quit and resume later.
3. Press **Apply** → name the trip → FujiCull copies, verifies, tags, and then
   (after confirmation) deletes rejects from the card.
4. Upload `Google Photos/` folder from the SSD to Google Photos in the browser.
5. Format the card in camera when I'm ready.

## 4. Functional requirements

### 4.1 Opening a source
- R1. Open an SD card volume or any folder. Recursively scan `DCIM/` subfolders.
- R2. Pair files by identical base name in the same folder (`DSCF1234.JPG` ↔ `DSCF1234.RAF`), case-insensitive.
- R3. Each pair is one **frame** in the cull list, ordered by capture time (EXIF), then filename.
- R4. Orphans (RAF-only or JPG-only) appear as frames with an **"unpaired"** badge. RAF-only frames show the RAF's embedded preview.
- R5. Ignore non-image files and hidden files (e.g. `._*`, `.Trashes`).
- R6. If the card is write-locked (SD lock switch), culling and copying work; deletion is disabled with a clear notice.

### 4.2 Decisions
- R7. Each frame has exactly one state: **Undecided** (default), **Keep**, **Reject**.
- R8. **♥ Favourite** is a flag on top of Keep. Favouriting a frame also sets it to Keep; rejecting a favourite clears the flag.
- R9. Every decision applies to the whole pair (RAF + JPG) — there is no way to treat them separately.
- R10. Unlimited undo of decisions within a session.

### 4.3 Keyboard (one-handed, right hand)

| Key | Action |
|---|---|
| ↑ | Keep, then advance |
| ↓ | Reject, then advance |
| ← / → | Previous / next frame (no decision) |
| Shift + ← / → | Jump 10 frames |
| `/` | Toggle ♥ Favourite (implies Keep) |
| `.` | Reset to Undecided |
| Return | Toggle 100% zoom (focus check) / fit |
| `'` | Toggle filter: show only Undecided |
| ⌫ Delete | Undo last action |
| G | Toggle grid / single-image view |
| I | Toggle EXIF info line |

- R11. Auto-advance after ↑/↓ is on by default (preference to turn it off).
- R12. At 100% zoom, the zoom centre follows the mouse; arrow keys still navigate frames (zoom level persists across frames so I can compare focus).
- R13. Every action is also available from the menu bar so shortcuts are discoverable.

### 4.4 Screen layout
- R14. **Single view (default):** large image fit-to-window, thin filmstrip of thumbnails along the bottom showing each frame's state (green keep, red reject, ♥, grey undecided).
- R15. **Grid view** (toggle with G): thumbnails with state badges; same keys work on the selected cell.
- R16. **Overlay:** filename, state, progress (`412 / 1,873`), counts (kept / rejected / undecided).
- R17. **EXIF line** (toggle with I): shutter, aperture, ISO, focal length, film simulation.
- R18. Dark UI so the photo is the brightest thing on screen.

### 4.5 Saving progress
- R19. Marks auto-save after every change to `~/Library/Application Support/FujiCull/` (a few KB per card).
- R20. Sessions are keyed to the card (volume ID + file list), so re-inserting the same card restores my marks and position.
- R21. Nothing on the card is modified until Apply.

### 4.6 Apply (offload + delete)

Apply runs as an ordered, safe sequence:

1. **Pre-flight**
   - Ask for a trip name (e.g. "Japan").
   - Choose archive SSD root (remembered after first use).
   - Check SSD free space ≥ size of keepers; abort with a clear message otherwise.
   - Show summary: N keep (♥ M), N reject, N undecided.
   - If any frames are Undecided: warn — they will be **left on the card untouched**.
2. **Copy keepers** (RAF + JPG) to
   `<SSD>/FujiCull Archive/YYYY/YYYY-MM-DD <Trip name>/`
   and copy keeper JPGs to `.../YYYY-MM-DD <Trip name>/Google Photos/`.
   - Date = capture date of the earliest frame on the card.
   - Never overwrite: if a filename already exists (e.g. DSCF counter wrapped), append a suffix (`DSCF1234-2.JPG`) and keep the pair names matched.
3. **Verify** every copied file by reading it back and comparing checksums.
4. **Tag favourites:** apply a Finder tag **"Favourite"** to the archived RAF, JPG and Google Photos JPG of every ♥ frame.
5. **Confirm deletion:** "Delete 1,412 rejected frames (2,824 files, 141 GB) from the card? This cannot be undone." Default button is Cancel.
6. **Delete rejects** from the card permanently (not to the Trash — the macOS Trash on an SD card just hides files on the card and doesn't free space).
7. **Summary screen:** copied / verified / deleted / left on card, with "Reveal in Finder" for the archive and the Google Photos folder.

- R22. Rejects are **only** deleted if every keeper copy verified successfully.
- R23. If the card or SSD disconnects mid-Apply: stop immediately, delete nothing, report what completed. Re-running Apply resumes — already-verified files are skipped.
- R24. Keepers and undecided frames remain on the card after Apply (I format in camera).
- R25. Apply can be run again later (e.g. after deciding the undecided ones) and only processes what changed.

## 5. Non-functional requirements

| Area | Target |
|---|---|
| Open a 2,000-frame card | Filmstrip + first image visible in < 2 s (uses embedded thumbnails, full scan continues in background). |
| Next/previous frame | < 100 ms when prefetched (prefetch next 3 / previous 1 frames). |
| Holding → | Scrolls smoothly; never blocks on I/O (shows thumbnail until full JPG arrives). |
| 100% zoom | < 300 ms. |
| Mac disk use | Preview cache capped at 500 MB in `~/Library/Caches/FujiCull`, purged on Apply / card eject. |
| Memory | Comfortable on an 8 GB machine with other apps open. |
| Safety | No destructive action without explicit confirmation; no deletion before verified copy. |
| Platform | macOS 14+, Apple Silicon. Native (Swift/SwiftUI + AppKit where needed). |
| Size | Lightweight: no database server, no catalogue, no background agents. |

## 6. Out of scope for v1 (candidates for later)

- Direct upload to Google Photos (v2 candidate).
- Side-by-side compare view.
- Burst / stack grouping.
- Star ratings, colour labels, XMP sidecars, Lightroom integration.
- Any editing or recipe application.
- Importing via camera USB; multiple cards per trip.
- Configurable folder naming or key remapping (fixed defaults in v1).
- App Store distribution / sandboxing.

## 7. Assumptions to confirm

- A1. macOS 14 (Sonoma) or later is acceptable as the minimum.
- A2. Personal, non-sandboxed build run locally (simplifies card/SSD access and deletion).
- A3. Duplicating keeper JPGs into `Google Photos/` on the SSD (~10 GB per trip) is acceptable in exchange for a one-step upload folder.
- A4. Folder date uses the earliest capture date on the card, not the date Apply is run.

## 8. Tip (not a requirement)

The X-T50 supports **lossless compressed RAW**, which keeps the same image data at
roughly half the file size of uncompressed RAF. It would halve SSD usage and copy time;
FujiCull handles both formats either way.

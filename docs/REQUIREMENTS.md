# FujiCull — Product Requirements (v1)

_Status: agreed in requirements interview, 2026-10-09; amended after design review the same day (R3, R26, disk-cache NFR — see [DESIGN.md](DESIGN.md) §3). Owner: you._

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
- R3. Each pair is one **frame** in the cull list, ordered by DCIM folder, then filename (shooting order). _Amended 2026-10-09; was "by capture time (EXIF), then filename". See ADR-004._
- R4. Orphans (RAF-only or JPG-only) appear as frames with an **"unpaired"** badge. RAF-only frames show the RAF's embedded preview.
- R5. Ignore hidden files (e.g. `._*`, `.Trashes`). Videos (`.MOV`, `.MP4`) are not culled but are found by the scan (R27). Any other file is ignored for culling but listed at Apply as left on the card.
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
| Esc | Leave zoom, back to the whole photo _(added 2026-10-09)_ |
| Click on the photo while zoomed | Leave zoom, back to the whole photo _(added 2026-10-10)_ |
| Scroll wheel / pinch | Zoom in or out about the point under the mouse, fit to 200% _(added 2026-10-09)_ |
| Double-click (grid) | Open the frame in the single view, like Return _(added 2026-10-09)_ |
| ⌘↩ | Apply… (also a toolbar button and in the File menu) _(added 2026-10-11)_ |

- R11. Auto-advance after ↑/↓ is on by default (preference to turn it off).
- R12. At 100% zoom, the zoom centre follows the mouse; arrow keys still navigate frames, and moving to another frame returns to the whole-photo view. _Amended 2026-10-09; zoom previously persisted across frames._
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
2. **Copy keepers** (RAF + JPG) to `<SSD>/<Trip name>/`, a flat folder at the root of the
   SSD that matches the existing archive (`Japan 2024/`, `Vancouver '26/`), and copy keeper
   JPGs to `<SSD>/<Trip name>/Google Photos/`. _Amended 2026-10-09; was
   `FujiCull Archive/YYYY/YYYY-MM-DD <Trip name>/`._
   - If `<Trip name>/` already exists and FujiCull didn't create it for this card, ask before adding to it.
   - Existing folders on the SSD are never renamed, moved or reorganised. The flat layout applies only to trips FujiCull archives from now on.
   - The trip name must be a valid folder name on the SSD (exFAT forbids `" * / : < > ? \ |`); show an inline error otherwise.
   - Never overwrite: if a filename already exists (e.g. DSCF counter wrapped), append a suffix (`DSCF1234-2.JPG`) and keep the pair names matched.
3. **Verify** every copied file by reading it back and comparing checksums.
4. **Tag favourites:** apply a Finder tag **"Favourite"** to the archived RAF and JPG of every ♥ frame. The Google Photos copy is not tagged, so a Finder tag search shows each favourite's archive pair and no Google Photos duplicates. _Amended 2026-10-09 (Q11)._
5. **Confirm deletion:** "Delete 1,412 rejected frames (2,824 files, 141 GB) from the card? This cannot be undone." Default button is Cancel.
6. **Delete rejects** from the card permanently (not to the Trash — the macOS Trash on an SD card just hides files on the card and doesn't free space).
7. **Summary screen:** copied / verified / deleted / left on card, with "Reveal in Finder" for the archive and the Google Photos folder.

- R22. Rejects are **only** deleted if every keeper copy verified successfully.
- R23. If the card or SSD disconnects mid-Apply: stop immediately, delete nothing, report what completed. Re-running Apply resumes — already-verified files are skipped.
- R24. Keepers and undecided frames remain on the card after Apply (I format in camera).
- R25. Apply can be run again later (e.g. after deciding the undecided ones) and only processes what changed.
- R26. If a frame that an earlier Apply archived is later changed to **Reject**, the next Apply also removes its archive RAF, archive JPG and Google Photos JPG. These files are moved to the SSD's Trash, are listed in the deletion confirmation, and are removed only if unchanged since FujiCull verified them. A frame changed back to Undecided keeps its archive copy. _Added 2026-10-09._
- R27. Apply copies every video on the card (`.MOV`, `.MP4`, any case) to `<SSD>/<Trip name>/Videos/` with the same copy-and-verify and never-overwrite rules as photos. Videos are never deleted from the card by FujiCull, never tagged, and not copied to `Google Photos/`. Any other non-photo file is listed in pre-flight and the summary as left on the card and not archived, with a warning that formatting the card loses it. _Added 2026-10-09 (Q12)._

## 5. Non-functional requirements

| Area | Target |
|---|---|
| Open a 2,000-frame card | Filmstrip + first image visible in < 2 s (uses embedded thumbnails, full scan continues in background). |
| Next/previous frame | < 100 ms when prefetched (prefetch next 3 / previous 1 frames). |
| Holding → | Scrolls smoothly; never blocks on I/O (shows thumbnail until full JPG arrives). |
| 100% zoom | < 300 ms. |
| Mac disk use | No disk preview cache: previews are held in memory only and freed on card eject (ceiling remains 500 MB if one is ever added). Session files only. |
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
- Showing the Fuji recipe name (C1–C7 custom setting). Checked 2026-10-09: the X-T50 doesn't write the recipe name to the JPG (no MakerNote or XMP field holds it), only the individual settings. Inferring it from settings was offered and declined. Revisit if Fuji firmware starts recording the name.

## 7. Assumptions to confirm

- A1. macOS 14 (Sonoma) or later is acceptable as the minimum.
- A2. Personal, non-sandboxed build run locally (simplifies card/SSD access and deletion).
- A3. Duplicating keeper JPGs into `Google Photos/` on the SSD (~10 GB per trip) is acceptable in exchange for a one-step upload folder.
- A4. ~~Folder date uses the earliest capture date on the card.~~ Superseded 2026-10-09: folders are named by trip only, with no date.

## 8. Tip (not a requirement)

The X-T50 supports **lossless compressed RAW**, which keeps the same image data at
roughly half the file size of uncompressed RAF. It would halve SSD usage and copy time;
FujiCull handles both formats either way.

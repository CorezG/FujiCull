# Hardware probe — card, samples and archive SSD (spikes S1, S2, S3 partial, S4, S6 partial)

_2026-10-09. All checks were read-only; nothing was written to either drive. The probe
scripts were throwaway code in the session scratchpad. They will be rebuilt as real code
and tests in T4, T13 and T14._

## Setup
- **Card:** volume "Untitled", exFAT, 512 GB (237 GB used), USB reader. `DCIM/123_FUJI` is empty. `DCIM/124_FUJI` holds **2,091 JPG + RAF pairs plus 4 `.MOV` files**.
- **Camera settings:** X-T50, JPEG **Fine, size M (5472 × 3648, 20 MP)**, about 11–13 MB per file. Uncompressed RAF, about 86 MB per file. You may switch to size L (7728 × 5152, 40 MP) later.
- **Samples:** `Sample Images/DSCF3404–3408` (JPG + RAF), copied from this card.

## S1 — JPEG layout ✅
- APP1 (EXIF) is the first segment and is **exactly 65,468 bytes**, so it ends at byte 65,472. **A 64 KB T0 read is enough.**
- The IFD1 thumbnail is **160 × 120**, about 2.6–9 KB, at about byte 4,000–4,600.
- Then come a second APP1 (XMP), three APP2 `FPXR` segments, and the image. **There is no MPF preview**, so the MPF optimisation is ruled out. T1 reads the whole JPG, as designed.
- **Important:** ImageIO **won't parse metadata from a truncated 64 KB buffer.** Both `CreateWithData` and incremental mode returned no properties and no thumbnail. So T0 must use **our own pure EXIF/IFD parser** in Core, which extracts the thumbnail bytes and the EXIF values. The thumbnail bytes are then decoded with ImageIO. That parser was already planned (`JPEGSegments`); it now also covers the exposure fields.

## S2 — Film simulation ✅
- ImageIO **has no `{MakerFuji}` dictionary** for these files. It does expose `{PictureStyle}.FilmSimulation` (1536 = 0x600), but only when parsing the whole file.
- Our own MakerNote parse works on the 64 KB header. The MakerNote is at about byte 2,318 and is about 1.3–1.9 KB. It is a little-endian IFD after `FUJIFILM`.
  - Tag `0x1401` FilmMode gives colour simulations.
  - For monochrome, FilmMode is absent and tag `0x1003` Saturation gives the B&W or Acros variant.
- Survey of every 100th frame on the card (21 frames):

| Count | Values | Simulation |
|---|---|---|
| 12 | FilmMode 0x120 | Astia/Soft |
| 8 | FilmMode 0x600 | Classic Chrome |
| 1 | FilmMode absent, Saturation 0x502 | Acros + Ye filter |

- The value table to implement, following ExifTool's Fuji tag tables:
  - **FilmMode `0x1401`:** 0x000 Provia, 0x120 Astia, 0x200/0x400 Velvia, 0x500 Pro Neg Std, 0x501 Pro Neg Hi, 0x600 Classic Chrome, 0x700 Eterna, 0x800 Classic Neg, 0x900 Eterna Bleach Bypass, 0xA00 Nostalgic Neg, 0xB00 Reala Ace.
  - **Saturation `0x1003`:** 0x300 Mono, 0x301–0x303 Mono + R/Ye/G, 0x310 Sepia, 0x500 Acros, 0x501–0x503 Acros + R/Ye/G.
  - Unknown values show "—".

## S3 — Card identity (partial)
- exFAT does report a volume UUID: card `DB8E88CF-…`, SSD `7CA26A15-…`.
- ✅ **The UUID is stable across a rename and a different reader.** The card was renamed "Untitled" → "Fuji SD" and moved to the reader you'll use from now on, and the UUID was unchanged. A camera reformat is expected to change it (still to confirm, see below), but the ≥ 50% FrameID-overlap rule covers it either way.
- ✅ **The lock switch is passed through by this reader** (tested 2026-10-10, read-only checks, nothing written):

  | | Unlocked | Locked |
  |---|---|---|
  | `diskutil info`: Media Read-Only / Volume Read-Only | No / No | Yes / Yes (read-only mount flag set) |
  | `mount` flags | no `read-only` | `read-only` |
  | `URLResourceValues.volumeIsReadOnly` | false | true |
  | `access(2)` write check on the volume root | writable | not writable |
  | Volume UUID | `DB8E88CF-…` | `DB8E88CF-…` (unchanged) |

  The photos stay readable while locked, and the card mounts writable again after unlocking. So R6 can rely on `volumeIsReadOnly`, as DESIGN assumed. This is specific to this reader: some USB readers ignore the switch, so the Apply gate should still treat a failed delete as the fallback signal.
- **Still to test:** whether an in-camera format changes the UUID. It erases the card, so it waits until the card's photos are archived (or a spare card is used).

## S4 — Speed on this Mac and card ✅

| Measure | Result |
|---|---|
| Card sequential read, F_NOCACHE, whole JPG (first reader) | 66–92 MB/s, 126–196 ms per 11–13 MB JPG |
| **Card read in your chosen reader** ("Fuji SD") | **93–94 MB/s steady**, 122–141 ms per JPG; an 87 MB RAF in 0.93 s |
| T0, a 64 KB read | 6–13 ms |
| T1, decode downsampled to 2560 px | 86–113 ms |
| T2, full decode of 5472 × 3648 (80 MB RGBA) | **41–47 ms** |

- Next frame from the card, not prefetched: about 300 ms. **With prefetch it's instant.** The target of < 100 ms holds only when the frame was prefetched, as designed.
- **100% zoom easily meets < 300 ms** at size M. The full decode is faster than the downsampled one: hardware decode, measured on 2026-10-09. At size L, expect about a 25 MB read (≈ 300 ms) plus ≈ 100 ms decode when cold. This needs re-measuring if you switch.
- Memory at size M: T2 is 80 MB per frame, not 160 MB, so the zoom budget halves.

## S6 — Archive SSD (partial)
- "C&J Archive" is **exFAT**, 2 TB (550 GB used). It also contains `$RECYCLE.BIN` and `System Volume Information`, so it's shared with Windows.
- The existing layout is **flat trip folders at the root**, for example `Japan 2024/`, `Vancouver '26/`, `2023.07.15 Wedding/`.
- The SSD has a root-level `DCIM/` containing `P121xxxx.JPG` files directly, with no `*_FUJI` subfolder. The card auto-detect rule (`DCIM/*_FUJI`) correctly ignores it.
- What exFAT means for the design:
  - **Finder tags** are stored as extended attributes, which exFAT keeps in AppleDouble **`._DSCF1234.JPG` files** next to each tagged file. They're harmless on a Mac, but appear on Windows and could be picked up by a Google Photos folder upload.
  - **`RENAME_EXCL`** is probably unsupported on exFAT. The executor uses the check-then-rename fallback. This still needs a write test.
  - **Trash** (`trashItem`) on exFAT uses `.Trashes/<uid>` on the SSD, so archive removal (D6) is still recoverable.
- **Write probe ✅** (run 2026-10-09 with your OK; done in hidden temporary folders that were deleted afterwards, along with the one test file sent to the Trash):

| Check | Result |
|---|---|
| `F_FULLFSYNC`, `F_NOCACHE` | Both work. |
| `renamex_np(RENAME_EXCL)` onto an existing name | Refused with `EEXIST`, and the existing file was left intact. |
| `renamex_np(RENAME_EXCL)` onto a free name | **`ENOTSUP`, so it isn't supported on exFAT.** The executor needs the fallback: `FileManager.moveItem`, which refuses an existing destination. |
| Setting the modification date | Works, with exact readback. |
| Finder tag "Favourite" | Works, and reads back correctly. |
| `trashItem` | Works, moving the file to `/Volumes/C&J Archive/.Trashes/501/`. |

- **Every file this Mac writes to the exFAT SSD gets a 4 KB `._` file**, tagged or not. macOS adds a `com.apple.provenance` attribute to new files, and exFAT stores attributes in AppleDouble files. That attribute **can't be removed**: `xattr -d` returns 0 but the attribute stays. Your existing archive already has these files, for example 997 of them in `Japan 2024/`. Finder tags therefore add no extra files. `FileManager.contentsOfDirectory` hides `._` files, but `ls -a` and Windows show them.
- Consequence for Q11: tagging the Google Photos copies costs nothing extra. A clean upload folder without `._` files isn't possible on this exFAT SSD whatever FujiCull does, so in the browser upload you'd select the photos rather than the whole folder.

## T0 pass over the whole card (measured during T4)
- `ThumbnailLoader` (optimised build) over all **2,091 JPGs** on Fuji SD in the chosen reader: every file gave a thumbnail and full EXIF, with no failures. It took **4.5 s in total**, about 2 ms per header, against the 10–30 s estimated in DESIGN §5.4.
- Orientation mix on this card: 507 × 1 (landscape), 833 × 6, 745 × 8, 6 × 3. Every portrait thumbnail came out portrait after rotation.

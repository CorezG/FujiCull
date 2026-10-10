# Viewer performance on the real card (T15, checkpoint C)

_Measured 2026-10-10 on "Fuji SD" (2,091 frames, 20 MP JPG + RAF pairs) in the owner's card reader, release
build, from the app's own timing log, over three runs. Status: all four targets met; the longest single hold
was 141 frames, not the 500 that T15 asked for (see below)._

## How it was measured

The app logs one line per event to the unified log (subsystem `com.github.corezg.FujiCull`, category
`timing`). Times run from the key press's own timestamp to the moment the viewer puts the image on screen.

```bash
/usr/bin/log show --last 30m --predicate 'subsystem == "com.github.corezg.FujiCull" AND category == "timing"' --style compact
```

View → Show Timings (⌥⌘T) shows the last move's numbers in the status bar.

## Results against the targets (REQUIREMENTS §5)

| Target | Measured | Verdict |
|---|---|---|
| Open a 2,000-frame card: first image in < 2 s | 549 ms cold (scan 509 ms); 128 ms on a second open | Met |
| Next/previous frame: < 100 ms when prefetched | 111 moves: median 19 ms, p90 38 ms, max 72 ms; 105 of 111 were already preloaded | Met |
| 100% zoom: < 300 ms | After the fix below, 5 zooms: 99 ms (landscape), 177, 212, 221, 244 ms (portrait) | Met |
| Holding →: smooth, never blocks on I/O | 13 holds, 379 frames: 83–87 ms per frame (the key-repeat rate), longest gap 123 ms, every thumbnail shown, slowest 62 ms | Met; longest hold 141 frames (11.7 s) |

Other numbers from the same runs:

- Main-thread work per move: median 5.5 ms, max 10.6 ms. Filmstrip refresh: median 1.3 ms, max 2.6 ms.
- After a hold ends, the thumbnail is on screen in about 45 ms and the sharp photo about 0.4 s after the last
  key press (5 holds: 391–421 ms). That is the card read (about 130 ms for a 12 MB JPG) plus decode, started
  when the key is released.
- Zoom is almost all decode: the JPG was read moments earlier for the display image, so the second read
  comes from the system's file cache (1–35 ms). Decode is about 90 ms for a landscape frame and 175–205 ms
  for a portrait one, which is also rotated.

## The 500-frame hold

T15's acceptance asks for a hold through 500 frames (about 40 s). The longest single hold measured was 141
frames in 11.7 s; the holds of 74 and 39 frames either side of it bring one stretch to 254 frames in 21 s.
Per-frame time, longest gap and slowest thumbnail were the same for holds of 10 frames and of 141, and while
a key is held the app keeps only the current thumbnail, so nothing builds up with length. T15 is closed on
that evidence rather than on a literal 500-frame hold.

## Two bugs this run found

**1. Full-resolution decode ran on the main thread for upright photos.** `PreviewPipeline.decodeFull` asked
ImageIO for the plain image, which comes back not yet decoded when there is no subsample factor; rotation
forced the decode for portrait frames only. For landscape frames the first draw decoded on the main thread.
On the five sample JPGs (20 MP):

| | Returned after | First draw |
|---|---|---|
| Before, landscape | 0–9 ms | 57–131 ms |
| Before, portrait | 190–226 ms | 2 ms |
| After, landscape | 74–113 ms | 3 ms |
| After, portrait | 180 ms | 2 ms |

The first zoom timing (363 ms, before the fix) is not comparable with the later ones for that reason. Fixed in
599d789, with a test that wipes the JPEG's bytes after decoding and checks the image still draws.

**2. The filmstrip's scroll bar took 17 pt of the strip.** NSCollectionView turns the horizontal scroller on
for a horizontal layout. With a mouse attached macOS uses the always-visible kind, which shrank the strip's
content from 92 pt to 75 pt; a 64 pt cell with 20 pt of insets no longer fitted, and AppKit logged "the
behavior of the UICollectionViewFlowLayout is not defined" on every move (161 lines in the first run).

- A layout subclass that reported a taller content size (e2fe1b9) did not help.
- Refusing the scroller (d6cf328) removed the warning but stopped the strip scrolling to the current frame.
- Forcing the overlay scroller style (05014f0) gives no warning, the full 92 pt, and a strip that scrolls.
  Checked in a scratch harness with the same scroll-view setup, then in the app: the third run logged no
  warnings and the owner confirmed the strip follows the current frame.
